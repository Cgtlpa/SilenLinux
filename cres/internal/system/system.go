package system

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	creslog "silen/cres/internal/log"
)

func IsRoot() bool {
	return os.Geteuid() == 0
}

func CommandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

type logWriter struct {
	log *creslog.Logger
}

func (w logWriter) Write(p []byte) (int, error) {
	scanner := bufio.NewScanner(strings.NewReader(string(p)))
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		if line != "" {
			w.log.Line("  " + line)
		}
	}
	return len(p), nil
}

func Run(name string, args []string, env map[string]string, dir string, logger *creslog.Logger) error {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if logger != nil {
		logger.Printf("$ %s %s", name, strings.Join(args, " "))
		cmd.Stdout = logWriter{log: logger}
		cmd.Stderr = logWriter{log: logger}
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

func RunShell(script string, env map[string]string, dir string, logger *creslog.Logger) error {
	cmd := exec.Command("/bin/sh", "-c", script)
	if dir != "" {
		cmd.Dir = dir
	}
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if logger != nil {
		logger.Printf("$ sh -c %q", script)
		cmd.Stdout = logWriter{log: logger}
		cmd.Stderr = logWriter{log: logger}
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("shell command failed: %w", err)
	}
	return nil
}

func Chroot(root, script string, env map[string]string, logger *creslog.Logger) error {
	if root == "" || root == "/" {
		return RunShell(script, env, "/", logger)
	}
	fullEnv := map[string]string{
		"PATH":          "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME":          "/root",
		"SPK_ROOT":      "/",
		"CRES_ROOT":     "/",
		"SPK_USER_MODE": "0",
	}
	for k, v := range env {
		fullEnv[k] = v
	}
	args := []string{"chroot", root, "/bin/sh", "-c", script}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = os.Environ()
	for k, v := range fullEnv {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if logger != nil {
		logger.Printf("$ chroot %s /bin/sh -c %q", root, script)
		cmd.Stdout = logWriter{log: logger}
		cmd.Stderr = logWriter{log: logger}
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("chroot command failed: %w", err)
	}
	return nil
}

func ChrootOutput(root, script string) (string, error) {
	cmd := exec.Command("chroot", root, "/bin/sh", "-c", script)
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func MountTarget(root string) (func(), error) {
	if root == "" || root == "/" {
		return func() {}, nil
	}
	var mounted []string
	cleanup := func() {
		for i := len(mounted) - 1; i >= 0; i-- {
			_ = exec.Command("umount", "-R", mounted[i]).Run()
		}
	}
	for _, entry := range []struct{ src, dst string }{
		{"/proc", filepath.Join(root, "proc")},
		{"/sys", filepath.Join(root, "sys")},
		{"/dev", filepath.Join(root, "dev")},
		{"/run", filepath.Join(root, "run")},
	} {
		if err := os.MkdirAll(entry.dst, 0o755); err != nil {
			cleanup()
			return nil, err
		}
		if isMounted(entry.dst) {
			continue
		}
		if out, err := exec.Command("mount", "--rbind", entry.src, entry.dst).CombinedOutput(); err != nil {
			cleanup()
			return nil, fmt.Errorf("mount %s: %s: %w", entry.src, strings.TrimSpace(string(out)), err)
		}
		mounted = append(mounted, entry.dst)
	}
	return cleanup, nil
}

func isMounted(path string) bool {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		for _, f := range fields {
			if f == path {
				return true
			}
		}
	}
	return false
}

func CopyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func WriteFile(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".cres-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	tmp.Close()
	return os.Rename(name, path)
}

func RemoveEmptyDirs(root string, dirs []string) {
	for i := len(dirs) - 1; i >= 0; i-- {
		dir := dirs[i]
		if root != "/" {
			dir = filepath.Join(root, dir)
		}
		_ = os.Remove(dir)
	}
}
