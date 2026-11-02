package database

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"

	"silen/cres/internal/model"
)

type DB struct {
	Root string
	Dir  string
	mu   sync.Mutex
	lock *os.File
}

func Open(root string) (*DB, error) {
	root = normalizeRoot(root)
	dir := filepath.Join(root, "var/lib/cres")
	for _, sub := range []string{"", "installed", "journal", "backup"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o755); err != nil {
			return nil, err
		}
	}
	lock, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		lock.Close()
		return nil, fmt.Errorf("another cres process is using %s: %w", dir, err)
	}
	return &DB{Root: root, Dir: dir, lock: lock}, nil
}

func OpenRead(root string) *DB {
	root = normalizeRoot(root)
	return &DB{Root: root, Dir: filepath.Join(root, "var/lib/cres")}
}

func normalizeRoot(root string) string {
	root = strings.TrimSpace(root)
	if root == "" {
		return "/"
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return filepath.Clean(root)
	}
	return abs
}

func (db *DB) Close() error {
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.lock == nil {
		return nil
	}
	err := syscall.Flock(int(db.lock.Fd()), syscall.LOCK_UN)
	cerr := db.lock.Close()
	db.lock = nil
	if err != nil {
		return err
	}
	return cerr
}

func (db *DB) installedDir() string { return filepath.Join(db.Dir, "installed") }
func (db *DB) worldPath() string    { return filepath.Join(db.Dir, "world") }
func (db *DB) statePath() string    { return filepath.Join(db.Dir, "state.json") }
func (db *DB) journalDir() string   { return filepath.Join(db.Dir, "journal") }
func (db *DB) backupDir() string    { return filepath.Join(db.Dir, "backup") }

func (db *DB) Get(name string) (*model.Installed, error) {
	data, err := os.ReadFile(filepath.Join(db.installedDir(), name+".json"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var pkg model.Installed
	if err := json.Unmarshal(data, &pkg); err != nil {
		return nil, fmt.Errorf("corrupt database entry for %s: %w", name, err)
	}
	return &pkg, nil
}

func (db *DB) Installed() (map[string]model.Installed, error) {
	out := map[string]model.Installed{}
	entries, err := os.ReadDir(db.installedDir())
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(db.installedDir(), entry.Name()))
		if err != nil {
			return nil, err
		}
		var pkg model.Installed
		if err := json.Unmarshal(data, &pkg); err != nil {
			return nil, fmt.Errorf("corrupt database entry %s: %w", entry.Name(), err)
		}
		out[pkg.Name] = pkg
	}
	return out, nil
}

func (db *DB) Save(pkg model.Installed) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	data, err := json.MarshalIndent(pkg, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(db.installedDir(), pkg.Name+".json"), data, 0o644)
}

func (db *DB) Delete(name string) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	err := os.Remove(filepath.Join(db.installedDir(), name+".json"))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (db *DB) World() ([]string, error) {
	data, err := os.ReadFile(db.worldPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out = append(out, line)
		}
	}
	sort.Strings(out)
	return out, nil
}

func (db *DB) SetWorld(list []string) error {
	seen := map[string]bool{}
	var clean []string
	for _, name := range list {
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		clean = append(clean, name)
	}
	sort.Strings(clean)
	return atomicWrite(db.worldPath(), []byte(strings.Join(clean, "\n")+"\n"), 0o644)
}

func (db *DB) AddWorld(name string) error {
	world, err := db.World()
	if err != nil {
		return err
	}
	for _, existing := range world {
		if existing == name {
			return nil
		}
	}
	world = append(world, name)
	return db.SetWorld(world)
}

func (db *DB) RemoveWorld(name string) error {
	world, err := db.World()
	if err != nil {
		return err
	}
	var out []string
	for _, existing := range world {
		if existing != name {
			out = append(out, existing)
		}
	}
	return db.SetWorld(out)
}

func (db *DB) ReadState() (map[string]any, error) {
	data, err := os.ReadFile(db.statePath())
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]any{}, nil
		}
		return nil, err
	}
	var state map[string]any
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	return state, nil
}

func (db *DB) WriteState(state map[string]any) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(db.statePath(), data, 0o644)
}

func (db *DB) JournalPath(name string) string {
	return filepath.Join(db.journalDir(), name+".json")
}

func (db *DB) BackupDir(name string) string {
	return filepath.Join(db.backupDir(), name)
}

func (db *DB) CleanJournal(name string) {
	_ = os.Remove(db.JournalPath(name))
	_ = os.RemoveAll(db.BackupDir(name))
}

func (db *DB) LogPath() string {
	return filepath.Join(db.Root, "var/log/cres")
}

func (db *DB) CacheDir() string {
	return filepath.Join(db.Root, "var/cache/cres")
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".cres-*")
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
