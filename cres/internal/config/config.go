package config

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	SystemConfigPath = "/etc/silen/config.lua"
	UserConfigPath   = ".config/silen/config.lua"
)

var (
	serviceRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
	runlevelRE = regexp.MustCompile(`^(sysinit|boot|default|shutdown|nonetwork)$`)
	sysctlRE   = regexp.MustCompile(`^[a-zA-Z0-9_.-]+(\.[a-zA-Z0-9_.-]+)*$`)
	timezoneRE = regexp.MustCompile(`^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$`)
	localeRE   = regexp.MustCompile(`^[A-Za-z]{2,3}(_[A-Za-z]{2})?(\.[A-Za-z0-9-]+)?$`)
	keymapRE   = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	hostnameRE = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
)

type Service struct {
	Name     string
	Runlevel string
}

type Config struct {
	Version     int
	Hostname    string
	Timezone    string
	Keymap      string
	Locale      string
	Packages    []string
	Services    []Service
	Sysctl      map[string]string
	Files       map[string]string
	Directories []string
	Source      string
}

type Scope int

const (
	SystemScope Scope = iota
	UserScope
)

func SystemPath(root string) string {
	root = strings.TrimRight(root, "/")
	if root == "" {
		root = "/"
	}
	if root == "/" {
		return SystemConfigPath
	}
	return filepath.Join(root, SystemConfigPath)
}

func UserPath(home string) string {
	return filepath.Join(home, UserConfigPath)
}

func LoadSystem(root string) (*Config, error) {
	path := SystemPath(root)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{Version: 1, Source: path}, nil
		}
		return nil, err
	}
	cfg, err := Parse(data, SystemScope)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	cfg.Source = path
	return cfg, nil
}

func LoadUser(home string) (*Config, error) {
	path := UserPath(home)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{Version: 1, Source: path}, nil
		}
		return nil, err
	}
	cfg, err := Parse(data, UserScope)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	cfg.Source = path
	return cfg, nil
}

func Parse(data []byte, scope Scope) (*Config, error) {
	table, err := parseLua(data)
	if err != nil {
		return nil, err
	}
	cfg := &Config{Version: 1, Sysctl: map[string]string{}, Files: map[string]string{}}
	for key, value := range table {
		switch key {
		case "version":
			n, ok := value.(int64)
			if !ok || n != 1 {
				return nil, fmt.Errorf("version must be 1")
			}
			cfg.Version = int(n)
		case "hostname":
			s, ok := value.(string)
			if !ok || !hostnameRE.MatchString(s) || len(s) > 63 {
				return nil, fmt.Errorf("invalid hostname")
			}
			if scope == UserScope {
				return nil, fmt.Errorf("hostname is only valid in the system config")
			}
			cfg.Hostname = s
		case "timezone":
			s, ok := value.(string)
			if !ok || !timezoneRE.MatchString(s) || strings.Contains(s, "..") {
				return nil, fmt.Errorf("invalid timezone")
			}
			if scope == UserScope {
				return nil, fmt.Errorf("timezone is only valid in the system config")
			}
			cfg.Timezone = s
		case "keymap":
			s, ok := value.(string)
			if !ok || !keymapRE.MatchString(s) {
				return nil, fmt.Errorf("invalid keymap")
			}
			if scope == UserScope {
				return nil, fmt.Errorf("keymap is only valid in the system config")
			}
			cfg.Keymap = s
		case "locale":
			s, ok := value.(string)
			if !ok || !localeRE.MatchString(s) {
				return nil, fmt.Errorf("invalid locale")
			}
			if scope == UserScope {
				return nil, fmt.Errorf("locale is only valid in the system config")
			}
			cfg.Locale = s
		case "packages":
			list, err := stringList(value)
			if err != nil {
				return nil, fmt.Errorf("packages: %w", err)
			}
			for _, name := range list {
				if !packageNameRE.MatchString(name) {
					return nil, fmt.Errorf("packages: invalid package name %q", name)
				}
			}
			if scope == UserScope {
				return nil, fmt.Errorf("packages is only valid in the system config; use 'cres install' for user packages")
			}
			cfg.Packages = list
		case "services":
			services, err := serviceList(value)
			if err != nil {
				return nil, fmt.Errorf("services: %w", err)
			}
			if scope == UserScope {
				return nil, fmt.Errorf("services is only valid in the system config")
			}
			cfg.Services = services
		case "sysctl":
			m, ok := value.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("sysctl must be a table")
			}
			if scope == UserScope {
				return nil, fmt.Errorf("sysctl is only valid in the system config")
			}
			for k, v := range m {
				if !sysctlRE.MatchString(k) || strings.Contains(k, "..") {
					return nil, fmt.Errorf("sysctl: invalid key %q", k)
				}
				s, ok := v.(string)
				if !ok || len(s) > 256 || strings.ContainsAny(s, "\n\r\x00") {
					return nil, fmt.Errorf("sysctl: invalid value for %q", k)
				}
				cfg.Sysctl[k] = s
			}
		case "files":
			m, ok := value.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("files must be a table")
			}
			if scope == SystemScope {
				return nil, fmt.Errorf("files is only valid in the user config")
			}
			for k, v := range m {
				rel, err := safeUserPath(k)
				if err != nil {
					return nil, fmt.Errorf("files: %w", err)
				}
				s, ok := v.(string)
				if !ok || len(s) > 1024*1024 {
					return nil, fmt.Errorf("files[%q]: value must be a string under 1 MiB", k)
				}
				cfg.Files[rel] = s
			}
		case "directories":
			list, err := stringList(value)
			if err != nil {
				return nil, fmt.Errorf("directories: %w", err)
			}
			if scope == SystemScope {
				return nil, fmt.Errorf("directories is only valid in the user config")
			}
			for _, p := range list {
				rel, err := safeUserPath(p)
				if err != nil {
					return nil, fmt.Errorf("directories: %w", err)
				}
				cfg.Directories = append(cfg.Directories, rel)
			}
		default:
			return nil, fmt.Errorf("unknown config key %q", key)
		}
	}
	return cfg, nil
}

var packageNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9+._-]*$`)

func stringList(v any) ([]string, error) {
	switch list := v.(type) {
	case []any:
		out := make([]string, 0, len(list))
		for _, item := range list {
			s, ok := item.(string)
			if !ok {
				return nil, fmt.Errorf("entries must be strings")
			}
			out = append(out, s)
		}
		return out, nil
	case nil:
		return nil, nil
	default:
		return nil, fmt.Errorf("must be a list")
	}
}

func serviceList(v any) ([]Service, error) {
	switch list := v.(type) {
	case []any:
		out := make([]Service, 0, len(list))
		for _, item := range list {
			switch entry := item.(type) {
			case string:
				if !serviceRE.MatchString(entry) {
					return nil, fmt.Errorf("invalid service name %q", entry)
				}
				out = append(out, Service{Name: entry, Runlevel: "default"})
			case map[string]any:
				name, _ := entry["name"].(string)
				runlevel, _ := entry["runlevel"].(string)
				if runlevel == "" {
					runlevel = "default"
				}
				if !serviceRE.MatchString(name) || !runlevelRE.MatchString(runlevel) {
					return nil, fmt.Errorf("invalid service entry")
				}
				out = append(out, Service{Name: name, Runlevel: runlevel})
			default:
				return nil, fmt.Errorf("services must contain strings or {name=..., runlevel=...} tables")
			}
		}
		return out, nil
	case map[string]any:
		out := make([]Service, 0, len(list))
		for name, value := range list {
			runlevel, _ := value.(string)
			if runlevel == "" {
				runlevel = "default"
			}
			if !serviceRE.MatchString(name) || !runlevelRE.MatchString(runlevel) {
				return nil, fmt.Errorf("invalid service entry %q", name)
			}
			out = append(out, Service{Name: name, Runlevel: runlevel})
		}
		return out, nil
	default:
		return nil, fmt.Errorf("must be a list or table")
	}
}

func safeUserPath(p string) (string, error) {
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\x00") {
		return "", fmt.Errorf("path %q must be relative", p)
	}
	clean := filepath.Clean(p)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("path %q escapes the home directory", p)
	}
	return clean, nil
}
