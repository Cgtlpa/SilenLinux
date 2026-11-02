package installer

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"silen/cres/internal/archive"
	"silen/cres/internal/database"
	"silen/cres/internal/dependency"
	creslog "silen/cres/internal/log"
	"silen/cres/internal/model"
	"silen/cres/internal/repository"
	"silen/cres/internal/system"
)

type Options struct {
	Root      string
	Repo      string
	Cache     string
	Yes       bool
	NoDeps    bool
	Reinstall bool
	Force     bool
	Refresh   bool
	Logger    *creslog.Logger
	Progress  func(name string, done, total int64)
}

type Installer struct {
	Opt    Options
	DB     *database.DB
	Client *repository.Client
	Index  model.Index
}

func New(opt Options) (*Installer, error) {
	if opt.Root == "" {
		opt.Root = "/"
	}
	if opt.Logger == nil {
		opt.Logger, _ = creslog.New("", os.Stderr)
	}
	db, err := database.Open(opt.Root)
	if err != nil {
		return nil, err
	}
	cache := opt.Cache
	if cache == "" {
		cache = db.CacheDir()
	}
	client := repository.New(opt.Repo, cache)
	client.Progress = opt.Progress
	return &Installer{Opt: opt, DB: db, Client: client}, nil
}

func (i *Installer) Close() {
	if i.DB != nil {
		_ = i.DB.Close()
	}
}

func (i *Installer) LoadIndex(ctx context.Context) error {
	idx, err := i.Client.LoadIndex(ctx, i.Opt.Refresh)
	if err != nil {
		return err
	}
	i.Index = idx
	return nil
}

func (i *Installer) Resolve(ctx context.Context, names []string) (model.Plan, error) {
	if err := i.LoadIndex(ctx); err != nil {
		return model.Plan{}, err
	}
	installed, err := i.DB.Installed()
	if err != nil {
		return model.Plan{}, err
	}
	resolver := dependency.New(i.Index, installed)
	return resolver.Resolve(names, dependency.Options{
		NoDeps:    i.Opt.NoDeps,
		Reinstall: i.Opt.Reinstall,
		Force:     i.Opt.Force,
	})
}

func (i *Installer) Install(ctx context.Context, names []string, explicit bool) error {
	plan, err := i.Resolve(ctx, names)
	if err != nil {
		return err
	}
	if len(plan.Install) == 0 && len(plan.Remove) == 0 {
		i.Opt.Logger.Printf("nothing to do: all requested packages are installed")
		return nil
	}
	i.printPlan(plan)
	if !i.Opt.Yes && !confirm("Proceed with the installation?") {
		return fmt.Errorf("installation cancelled")
	}
	if err := i.applyPlan(ctx, plan, names, explicit); err != nil {
		return err
	}
	return nil
}

func (i *Installer) applyPlan(ctx context.Context, plan model.Plan, requested []string, explicit bool) error {
	requestedSet := map[string]bool{}
	for _, name := range requested {
		if pkg := i.Index.Provider(name); pkg != nil {
			requestedSet[pkg.Name] = true
		} else {
			requestedSet[name] = true
		}
	}
	for _, name := range plan.Remove {
		if err := i.removeOne(name, false); err != nil {
			return err
		}
	}
	for _, pkg := range plan.Install {
		if err := i.installOne(ctx, pkg, requestedSet[pkg.Name] && explicit); err != nil {
			return err
		}
	}
	if explicit {
		for name := range requestedSet {
			if _, err := i.DB.Get(name); err == nil {
				if err := i.DB.AddWorld(name); err != nil {
					return err
				}
			}
		}
	}
	if i.touchedBoot(plan.Install) {
		if err := i.regenerateInitramfs(); err != nil {
			i.Opt.Logger.Printf("warning: could not regenerate initramfs: %v", err)
		}
	}
	return nil
}

func (i *Installer) installOne(ctx context.Context, pkg model.Package, explicit bool) error {
	logger := i.Opt.Logger
	logger.Printf("installing %s %s", pkg.Name, pkg.Version)
	if err := i.recoverJournal(pkg.Name); err != nil {
		return err
	}
	if err := ensureSpace(i.Opt.Root, pkg.Size); err != nil {
		return err
	}
	archivePath, err := i.Client.FetchPackage(ctx, pkg)
	if err != nil {
		return fmt.Errorf("%s: %w", pkg.Name, err)
	}
	logger.Printf("archive verified: %s", archivePath)

	journal, err := newJournal(i.DB.JournalPath(pkg.Name), pkg.Name, pkg.Version)
	if err != nil {
		return err
	}
	defer journal.Close()
	backupDir := i.DB.BackupDir(pkg.Name)
	_ = os.MkdirAll(backupDir, 0o755)
	backup := func(rel string) error {
		return backupFile(i.Opt.Root, backupDir, rel)
	}
	extractor := archive.New(archive.Options{
		Root:           i.Opt.Root,
		AllowProtected: false,
		Backup:         backup,
		Log:            func(s string) { logger.Printf("%s", s) },
		OnInstall: func(f model.File) {
			_ = journal.Append(f)
		},
	})
	files, err := extractor.Extract(archivePath)
	if err != nil {
		_ = i.rollback(pkg.Name, files, backupDir)
		return fmt.Errorf("%s: %w", pkg.Name, err)
	}

	installed := model.Installed{
		Name:        pkg.Name,
		Version:     pkg.Version,
		Explicit:    explicit,
		Deps:        append([]string{}, pkg.Deps...),
		Files:       files,
		InstalledAt: time.Now().UTC(),
		Checksum:    pkg.Checksum,
	}
	if err := i.DB.Save(installed); err != nil {
		_ = i.rollback(pkg.Name, files, backupDir)
		return err
	}
	if err := i.runPostInstall(pkg); err != nil {
		_ = i.DB.Delete(pkg.Name)
		_ = i.rollback(pkg.Name, files, backupDir)
		return fmt.Errorf("%s postinstall: %w", pkg.Name, err)
	}
	_ = journal.Close()
	_ = os.Remove(i.DB.JournalPath(pkg.Name))
	_ = os.RemoveAll(backupDir)
	logger.Printf("installed %s %s (%d files)", pkg.Name, pkg.Version, len(files))
	return nil
}

func (i *Installer) runPostInstall(pkg model.Package) error {
	var script string
	for _, candidate := range []string{"usr/lib/cres/postinstall", "usr/lib/spk/postinstall"} {
		if st, err := os.Stat(filepath.Join(i.Opt.Root, candidate)); err == nil && st.Mode().IsRegular() {
			script = "/" + candidate
			break
		}
	}
	if script == "" {
		return nil
	}
	env := map[string]string{
		"CRES_PACKAGE":  pkg.Name,
		"CRES_VERSION":  pkg.Version,
		"CRES_ROOT":     "/",
		"SPK_ROOT":      "/",
		"SPK_USER_MODE": "0",
	}
	if i.Opt.Root != "/" {
		cleanup, err := system.MountTarget(i.Opt.Root)
		if err != nil {
			return err
		}
		defer cleanup()
	}
	return system.Chroot(i.Opt.Root, fmt.Sprintf("cd / && /bin/sh %s", shellQuote(script)), env, i.Opt.Logger)
}

func (i *Installer) Remove(ctx context.Context, names []string, autoremove bool) error {
	installed, err := i.DB.Installed()
	if err != nil {
		return err
	}
	resolver := dependency.New(model.Index{}, installed)
	removeSet := map[string]bool{}
	for _, name := range names {
		if _, ok := installed[name]; !ok {
			return fmt.Errorf("%s is not installed", name)
		}
		removeSet[name] = true
	}
	for name := range removeSet {
		for _, dep := range resolver.Dependents(name) {
			if !removeSet[dep] {
				if !i.Opt.Force {
					return fmt.Errorf("%s is required by %s (use --force to remove anyway)", name, dep)
				}
				i.Opt.Logger.Printf("warning: removing %s, required by %s", name, dep)
			}
		}
	}
	order := removeOrder(removeSet, installed)
	for _, name := range order {
		if err := i.removeOne(name, false); err != nil {
			return err
		}
	}
	if autoremove {
		installed, err = i.DB.Installed()
		if err != nil {
			return err
		}
		resolver = dependency.New(model.Index{}, installed)
		for _, name := range resolver.Orphans() {
			if removeSet[name] {
				continue
			}
			if err := i.removeOne(name, false); err != nil {
				return err
			}
		}
	}
	return nil
}

func removeOrder(set map[string]bool, installed map[string]model.Installed) []string {
	state := map[string]int{}
	var order []string
	var visit func(name string)
	visit = func(name string) {
		if state[name] == 2 {
			return
		}
		if state[name] == 1 {
			return
		}
		state[name] = 1
		for _, dep := range installed[name].Deps {
			depName, _, _, err := model.ParseConstraint(dep)
			if err != nil || !set[depName] {
				continue
			}
			visit(depName)
		}
		state[name] = 2
		order = append(order, name)
	}
	for name := range set {
		visit(name)
	}
	for i, j := 0, len(order)-1; i < j; i, j = i+1, j-1 {
		order[i], order[j] = order[j], order[i]
	}
	return order
}

func (i *Installer) removeOne(name string, force bool) error {
	pkg, err := i.DB.Get(name)
	if err != nil {
		return err
	}
	if pkg == nil {
		return nil
	}
	logger := i.Opt.Logger
	logger.Printf("removing %s %s", pkg.Name, pkg.Version)
	for idx := len(pkg.Files) - 1; idx >= 0; idx-- {
		f := pkg.Files[idx]
		if f.Type == "dir" {
			continue
		}
		path := filepath.Join(i.Opt.Root, f.Path)
		if isProtected(f.Path) {
			logger.Printf("kept protected file /%s", f.Path)
			continue
		}
		if st, err := os.Lstat(path); err != nil {
			continue
		} else if st.Mode()&os.ModeSymlink == 0 && st.Mode().IsRegular() && f.SHA256 != "" {
			if sum, err := fileSum(path); err == nil && sum != f.SHA256 && strings.HasPrefix(f.Path, "etc/") && !force {
				logger.Printf("kept modified config /%s (use --force to remove)", f.Path)
				continue
			}
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			logger.Printf("warning: cannot remove /%s: %v", f.Path, err)
		}
	}
	var dirs []string
	for _, f := range pkg.Files {
		if f.Type == "dir" {
			dirs = append(dirs, f.Path)
		}
	}
	system.RemoveEmptyDirs(i.Opt.Root, dirs)
	if err := i.DB.Delete(name); err != nil {
		return err
	}
	_ = i.DB.RemoveWorld(name)
	logger.Printf("removed %s", name)
	return nil
}

func (i *Installer) Update(ctx context.Context) error {
	if err := i.LoadIndex(ctx); err != nil {
		return err
	}
	installed, err := i.DB.Installed()
	if err != nil {
		return err
	}
	var names []string
	for name := range installed {
		if i.Index.Find(name) != nil {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	if len(names) == 0 {
		i.Opt.Logger.Printf("no installed packages found in the repository")
		return nil
	}
	plan, err := dependency.New(i.Index, installed).Resolve(names, dependency.Options{Force: i.Opt.Force})
	if err != nil {
		return err
	}
	if len(plan.Install) == 0 {
		i.Opt.Logger.Printf("system is up to date")
		return nil
	}
	i.printPlan(plan)
	if !i.Opt.Yes && !confirm("Proceed with the update?") {
		return fmt.Errorf("update cancelled")
	}
	for _, pkg := range plan.Install {
		if err := i.installOne(ctx, pkg, false); err != nil {
			return err
		}
	}
	return nil
}

func (i *Installer) printPlan(plan model.Plan) {
	logger := i.Opt.Logger
	if len(plan.Remove) > 0 {
		logger.Printf("will replace/remove: %s", strings.Join(plan.Remove, ", "))
	}
	if len(plan.Install) == 0 {
		logger.Printf("no packages to install")
		return
	}
	logger.Printf("install plan (%d packages):", len(plan.Install))
	for _, pkg := range plan.Install {
		reason := plan.Reasons[pkg.Name]
		if old, ok := plan.Upgrade[pkg.Name]; ok {
			logger.Printf("  %s %s -> %s (%s)", pkg.Name, old, pkg.Version, reason)
		} else {
			logger.Printf("  %s %s (%s)", pkg.Name, pkg.Version, reason)
		}
	}
}

func (i *Installer) touchedBoot(pkgs []model.Package) bool {
	for _, pkg := range pkgs {
		if strings.HasPrefix(pkg.Name, "linux") || strings.Contains(pkg.Name, "kernel") {
			return true
		}
	}
	return false
}

func (i *Installer) regenerateInitramfs() error {
	if i.Opt.Root != "/" {
		if _, err := os.Stat(filepath.Join(i.Opt.Root, "usr/local/bin/silen-mkinitramfs")); err != nil {
			return nil
		}
		if _, err := os.Stat(filepath.Join(i.Opt.Root, "boot/vmlinuz")); err != nil {
			return nil
		}
		cleanup, err := system.MountTarget(i.Opt.Root)
		if err != nil {
			return err
		}
		defer cleanup()
		return system.Chroot(i.Opt.Root, "/usr/local/bin/silen-mkinitramfs", nil, i.Opt.Logger)
	}
	if !system.CommandExists("/usr/local/bin/silen-mkinitramfs") {
		return nil
	}
	return system.Run("/usr/local/bin/silen-mkinitramfs", nil, nil, "/", i.Opt.Logger)
}

func (i *Installer) recoverJournal(name string) error {
	path := i.DB.JournalPath(name)
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()
	var entries []model.File
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		var entry model.File
		if err := json.Unmarshal(scanner.Bytes(), &entry); err == nil && entry.Path != "" {
			entries = append(entries, entry)
		}
	}
	i.Opt.Logger.Printf("recovering interrupted install of %s (%d files)", name, len(entries))
	if err := i.rollback(name, entries, i.DB.BackupDir(name)); err != nil {
		return err
	}
	_ = os.Remove(path)
	_ = os.RemoveAll(i.DB.BackupDir(name))
	return nil
}

func (i *Installer) rollback(name string, files []model.File, backupDir string) error {
	for idx := len(files) - 1; idx >= 0; idx-- {
		f := files[idx]
		if f.Type == "dir" {
			continue
		}
		path := filepath.Join(i.Opt.Root, f.Path)
		_ = os.Remove(path)
	}
	_ = restoreBackup(i.Opt.Root, backupDir)
	_ = i.DB.Delete(name)
	return nil
}

type journal struct {
	file *os.File
}

func newJournal(path, name, version string) (*journal, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	header, _ := json.Marshal(map[string]string{"package": name, "version": version})
	_, _ = f.Write(append(header, '\n'))
	return &journal{file: f}, nil
}

func (j *journal) Append(f model.File) error {
	if j == nil || j.file == nil {
		return nil
	}
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	_, err = j.file.Write(append(data, '\n'))
	return err
}

func (j *journal) Close() error {
	if j == nil || j.file == nil {
		return nil
	}
	err := j.file.Close()
	j.file = nil
	return err
}

func backupFile(root, backupDir, rel string) error {
	src := filepath.Join(root, rel)
	dst := filepath.Join(backupDir, rel)
	in, err := os.Open(src)
	if err != nil {
		return nil
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	st, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, st.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func restoreBackup(root, backupDir string) error {
	return filepath.Walk(backupDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(backupDir, path)
		if err != nil || rel == "." {
			return nil
		}
		dst := filepath.Join(root, rel)
		if info.IsDir() {
			return os.MkdirAll(dst, info.Mode().Perm())
		}
		in, err := os.Open(path)
		if err != nil {
			return nil
		}
		defer in.Close()
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
		if err != nil {
			return nil
		}
		_, _ = io.Copy(out, in)
		_ = out.Close()
		return nil
	})
}

func ensureSpace(root string, archiveSize int64) error {
	if archiveSize <= 0 {
		return nil
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(root, &st); err != nil {
		return nil
	}
	free := int64(st.Bavail) * int64(st.Bsize)
	need := archiveSize*3 + 64*1024*1024
	if free < need {
		return fmt.Errorf("not enough free space on %s: need about %d MiB, have %d MiB", root, need/1048576, free/1048576)
	}
	return nil
}

func confirm(question string) bool {
	if st, err := os.Stdin.Stat(); err != nil || st.Mode()&os.ModeCharDevice == 0 {
		fmt.Fprintln(os.Stderr, "cres: refusing to prompt without a terminal (use --yes)")
		return false
	}
	fmt.Fprintf(os.Stderr, "%s [y/N] ", question)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return false
	}
	line = strings.ToLower(strings.TrimSpace(line))
	return line == "y" || line == "yes"
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func isProtected(rel string) bool {
	switch rel {
	case "etc/passwd", "etc/shadow", "etc/group", "etc/gshadow", "etc/fstab", "etc/machine-id",
		"etc/hostname", "etc/hosts", "etc/resolv.conf", "etc/localtime", "etc/sudoers",
		"etc/default/grub", "boot/grub/grub.cfg", "boot/grub/grubenv":
		return true
	}
	return false
}
