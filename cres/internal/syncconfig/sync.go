package syncconfig

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"silen/cres/internal/config"
	creslog "silen/cres/internal/log"
	"silen/cres/internal/system"
)

type PackageManager interface {
	InstalledVersion(name string) (string, bool)
	InstallPackages(names []string) error
}

type Result struct {
	Changed  bool
	Messages []string
}

type stateFile struct {
	Applied map[string]string `json:"applied"`
}

func ApplySystem(root string, cfg *config.Config, check bool, pm PackageManager, logger *creslog.Logger) (Result, error) {
	var res Result
	if root == "" {
		root = "/"
	}
	statePath := filepath.Join(root, "var/lib/cres/sync-state.json")
	state := loadState(statePath)
	changed := false
	add := func(key, value, message string) {
		if state.Applied[key] == value {
			return
		}
		res.Changed = true
		changed = true
		res.Messages = append(res.Messages, message)
		if !check {
			state.Applied[key] = value
		}
	}

	if cfg.Hostname != "" {
		path := filepath.Join(root, "etc/hostname")
		current, _ := os.ReadFile(path)
		value := strings.TrimSpace(string(current))
		if value != cfg.Hostname {
			add("hostname", cfg.Hostname, fmt.Sprintf("hostname: %s -> %s", value, cfg.Hostname))
			if !check {
				if err := system.WriteFile(path, []byte(cfg.Hostname+"\n"), 0o644); err != nil {
					return res, err
				}
				if root == "/" {
					_ = system.Run("hostname", []string{cfg.Hostname}, nil, "/", logger)
				}
			}
		}
	}

	if cfg.Timezone != "" {
		zonePath := filepath.Join(root, "usr/share/zoneinfo", cfg.Timezone)
		if _, err := os.Stat(zonePath); err != nil {
			return res, fmt.Errorf("timezone %s: no such zone", cfg.Timezone)
		}
		link := filepath.Join(root, "etc/localtime")
		current, _ := os.Readlink(link)
		desired := "/usr/share/zoneinfo/" + cfg.Timezone
		if current != desired {
			add("timezone", cfg.Timezone, fmt.Sprintf("timezone: %s -> %s", current, cfg.Timezone))
			if !check {
				_ = os.Remove(link)
				if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
					return res, err
				}
				if err := os.Symlink(desired, link); err != nil {
					return res, err
				}
				_ = system.WriteFile(filepath.Join(root, "etc/timezone"), []byte(cfg.Timezone+"\n"), 0o644)
			}
		}
	}

	if cfg.Keymap != "" {
		path := filepath.Join(root, "etc/conf.d/keymaps")
		data := fmt.Sprintf("keymap=\"%s\"\n", cfg.Keymap)
		current, _ := os.ReadFile(path)
		if string(current) != data {
			add("keymap", cfg.Keymap, fmt.Sprintf("keymap: %s", cfg.Keymap))
			if !check {
				if err := system.WriteFile(path, []byte(data), 0o644); err != nil {
					return res, err
				}
			}
		}
	}

	if cfg.Locale != "" {
		path := filepath.Join(root, "etc/env.d/02locale")
		data := fmt.Sprintf("LANG=\"%s\"\nLC_ALL=\"%s\"\n", cfg.Locale, cfg.Locale)
		current, _ := os.ReadFile(path)
		if string(current) != data {
			add("locale", cfg.Locale, fmt.Sprintf("locale: %s", cfg.Locale))
			if !check {
				if err := system.WriteFile(path, []byte(data), 0o644); err != nil {
					return res, err
				}
				gen := filepath.Join(root, "etc/locale.gen")
				line := fmt.Sprintf("%s UTF-8\n", cfg.Locale)
				existing, _ := os.ReadFile(gen)
				if !strings.Contains(string(existing), cfg.Locale) {
					if err := system.WriteFile(gen, append(existing, []byte(line)...), 0o644); err != nil {
						return res, err
					}
				}
				if root == "/" && system.CommandExists("locale-gen") {
					_ = system.Run("locale-gen", nil, nil, "/", logger)
				}
			}
		}
	}

	if len(cfg.Sysctl) > 0 {
		var b strings.Builder
		keys := make([]string, 0, len(cfg.Sysctl))
		for k := range cfg.Sysctl {
			keys = append(keys, k)
		}
		sortStrings(keys)
		for _, k := range keys {
			fmt.Fprintf(&b, "%s = %s\n", k, cfg.Sysctl[k])
		}
		path := filepath.Join(root, "etc/sysctl.d/90-silen.conf")
		current, _ := os.ReadFile(path)
		if string(current) != b.String() {
			add("sysctl", hash(b.String()), "sysctl: update /etc/sysctl.d/90-silen.conf")
			if !check {
				if err := system.WriteFile(path, []byte(b.String()), 0o644); err != nil {
					return res, err
				}
				if root == "/" && system.CommandExists("sysctl") {
					_ = system.Run("sysctl", []string{"-p", path}, nil, "/", logger)
				}
			}
		}
	}

	for _, service := range cfg.Services {
		initPath := filepath.Join(root, "etc/init.d", service.Name)
		if _, err := os.Stat(initPath); err != nil {
			return res, fmt.Errorf("service %s: no init script at /etc/init.d/%s", service.Name, service.Name)
		}
		link := filepath.Join(root, "etc/runlevels", service.Runlevel, service.Name)
		if _, err := os.Lstat(link); err == nil {
			continue
		}
		add("service:"+service.Name, service.Runlevel, fmt.Sprintf("service: enable %s in %s", service.Name, service.Runlevel))
		if !check {
			if root == "/" {
				if err := system.Run("rc-update", []string{"add", service.Name, service.Runlevel}, nil, "/", logger); err != nil {
					return res, err
				}
			} else {
				if err := system.Chroot(root, fmt.Sprintf("rc-update add %s %s", shellQuote(service.Name), shellQuote(service.Runlevel)), nil, logger); err != nil {
					return res, err
				}
			}
		}
	}

	if len(cfg.Packages) > 0 && pm != nil {
		var missing []string
		for _, name := range cfg.Packages {
			if _, ok := pm.InstalledVersion(name); !ok {
				missing = append(missing, name)
			}
		}
		if len(missing) > 0 {
			res.Changed = true
			changed = true
			res.Messages = append(res.Messages, "packages: "+strings.Join(missing, " "))
			if !check {
				if err := pm.InstallPackages(missing); err != nil {
					return res, err
				}
			}
		}
	}

	if changed && !check {
		if err := saveState(statePath, state); err != nil {
			return res, err
		}
	}
	return res, nil
}

func ApplyUser(home string, cfg *config.Config, check bool, logger *creslog.Logger) (Result, error) {
	var res Result
	statePath := filepath.Join(home, ".local/state/cres/state.json")
	state := loadState(statePath)
	changed := false
	add := func(key, value, message string) {
		if state.Applied[key] == value {
			return
		}
		res.Changed = true
		changed = true
		res.Messages = append(res.Messages, message)
		if !check {
			state.Applied[key] = value
		}
	}

	for _, rel := range cfg.Directories {
		path, err := secureUserPath(home, rel)
		if err != nil {
			return res, err
		}
		if st, err := os.Stat(path); err == nil && st.IsDir() {
			continue
		}
		add("dir:"+rel, "dir", "directory: ~/"+rel)
		if !check {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return res, err
			}
		}
	}

	for rel, content := range cfg.Files {
		path, err := secureUserPath(home, rel)
		if err != nil {
			return res, err
		}
		current, err := os.ReadFile(path)
		if err == nil && string(current) == content {
			continue
		}
		sum := hash(content)
		add("file:"+rel, sum, "file: ~/"+rel)
		if !check {
			if err := system.WriteFile(path, []byte(content), 0o644); err != nil {
				return res, err
			}
		}
	}

	if changed && !check {
		if err := saveState(statePath, state); err != nil {
			return res, err
		}
	}
	return res, nil
}

func secureUserPath(home, rel string) (string, error) {
	cur := home
	for _, part := range strings.Split(rel, "/") {
		if part == "" || part == "." || part == ".." {
			return "", fmt.Errorf("invalid path %q", rel)
		}
		cur = filepath.Join(cur, part)
		if st, err := os.Lstat(cur); err == nil && st.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("refusing to write through symlink %s", cur)
		}
	}
	return cur, nil
}

func loadState(path string) stateFile {
	state := stateFile{Applied: map[string]string{}}
	data, err := os.ReadFile(path)
	if err == nil {
		_ = json.Unmarshal(data, &state)
	}
	if state.Applied == nil {
		state.Applied = map[string]string{}
	}
	return state
}

func saveState(path string, state stateFile) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return system.WriteFile(path, data, 0o644)
}

func hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func sortStrings(list []string) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j] < list[j-1]; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}
