package cli

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"silen/cres/internal/build"
	"silen/cres/internal/config"
	"silen/cres/internal/database"
	"silen/cres/internal/installer"
	creslog "silen/cres/internal/log"
	"silen/cres/internal/model"
	"silen/cres/internal/repository"
	"silen/cres/internal/syncconfig"
)

const Version = "1.0.0"

type globals struct {
	root    string
	repo    string
	cache   string
	yes     bool
	verbose bool
}

func Run(args []string) int {
	g := globals{root: "/", repo: repository.DefaultBase}
	var rest []string
	for len(args) > 0 {
		arg := args[0]
		switch {
		case arg == "--root" || arg == "--repo" || arg == "--cache":
			if len(args) < 2 {
				fmt.Fprintf(os.Stderr, "cres: %s needs a value\n", arg)
				return 2
			}
			switch arg {
			case "--root":
				g.root = args[1]
			case "--repo":
				g.repo = args[1]
			case "--cache":
				g.cache = args[1]
			}
			args = args[2:]
		case strings.HasPrefix(arg, "--root="):
			g.root = strings.TrimPrefix(arg, "--root=")
			args = args[1:]
		case strings.HasPrefix(arg, "--repo="):
			g.repo = strings.TrimPrefix(arg, "--repo=")
			args = args[1:]
		case strings.HasPrefix(arg, "--cache="):
			g.cache = strings.TrimPrefix(arg, "--cache=")
			args = args[1:]
		case arg == "--yes" || arg == "-y":
			g.yes = true
			args = args[1:]
		case arg == "--verbose" || arg == "-v":
			g.verbose = true
			args = args[1:]
		case arg == "--version" || arg == "-V":
			fmt.Printf("cres %s\n", Version)
			return 0
		case arg == "--help" || arg == "-h":
			usage()
			return 0
		default:
			rest = args
			args = nil
		}
	}
	if len(rest) == 0 {
		usage()
		return 2
	}
	command := rest[0]
	cmdArgs := rest[1:]
	switch command {
	case "install", "get", "add":
		return cmdInstall(g, cmdArgs)
	case "remove", "rm", "uninstall":
		return cmdRemove(g, cmdArgs)
	case "update", "upgrade":
		return cmdUpdate(g, cmdArgs)
	case "search":
		return cmdSearch(g, cmdArgs)
	case "info", "show":
		return cmdInfo(g, cmdArgs)
	case "list", "ls":
		return cmdList(g, cmdArgs)
	case "sync":
		return cmdSync(g, cmdArgs)
	case "build":
		return cmdBuild(g, cmdArgs)
	case "publish":
		return cmdPublish(g, cmdArgs)
	case "mkindex":
		return cmdMkIndex(g, cmdArgs)
	case "doctor":
		return cmdDoctor(g, cmdArgs)
	case "version":
		fmt.Printf("cres %s\n", Version)
		return 0
	case "help":
		usage()
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cres: unknown command %q\n", command)
		usage()
		return 2
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `cres - Silen Linux package manager

usage: cres [global options] <command> [options] [args]

commands:
  install <pkg...>     download, verify and install packages and dependencies
  remove <pkg...>      remove packages (--autoremove removes orphaned deps)
  update               refresh the index and upgrade installed packages
  search <pattern>     search available packages
  info <pkg>           show package metadata
  list                 list installed packages (--available lists the repo)
  sync                 apply /etc/silen/config.lua or ~/.config/silen/config.lua
  build <name>         build an approved source definition
  publish <dir>        publish a built package (asks before overwriting)
  mkindex              build a cres index from a packages directory
  doctor               check the installation and network

global options:
  --root <dir>         operate on an alternate root (default /)
  --repo <url>         package repository base URL
  --cache <dir>        download cache (default <root>/var/cache/cres)
  --yes, -y            do not ask for confirmation
  --verbose, -v        verbose logging
  --version, -V        print version
  --help, -h           this help

sync options:
  --check              report changes, exit 2 if anything would change
  --system             apply the system config (default when root)
  --user               apply the user config (default when not root)
  --config <path>      use an alternate config file
`)
}

func addCommon(fs *flag.FlagSet, g *globals) {
	fs.StringVar(&g.root, "root", g.root, "alternate root")
	fs.StringVar(&g.repo, "repo", g.repo, "repository base URL")
	fs.StringVar(&g.cache, "cache", g.cache, "download cache")
	fs.BoolVar(&g.yes, "yes", g.yes, "assume yes")
	fs.BoolVar(&g.yes, "y", g.yes, "assume yes")
	fs.BoolVar(&g.verbose, "verbose", g.verbose, "verbose output")
}

func newLogger(g globals) *creslog.Logger {
	path := ""
	if g.root != "/" && g.root != "" {
		path = filepath.Join(g.root, "var/log/cres/cres.log")
	} else if os.Geteuid() == 0 {
		path = "/var/log/cres/cres.log"
	} else {
		home, _ := os.UserHomeDir()
		if home != "" {
			path = filepath.Join(home, ".local/state/cres/cres.log")
		}
	}
	logger, err := creslog.New(path, os.Stderr)
	if err != nil {
		logger, _ = creslog.New("", os.Stderr)
	}
	return logger
}

func cmdInstall(g globals, args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	addCommon(fs, &g)
	noDeps := fs.Bool("no-deps", false, "do not install dependencies")
	reinstall := fs.Bool("reinstall", false, "reinstall even if up to date")
	force := fs.Bool("force", false, "ignore conflicts")
	refresh := fs.Bool("refresh", true, "refresh the package index")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	names := fs.Args()
	if len(names) == 0 {
		fmt.Fprintln(os.Stderr, "cres: install needs at least one package")
		return 2
	}
	if g.root == "/" && os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "cres: installing system packages requires root")
		return 1
	}
	logger := newLogger(g)
	defer logger.Close()
	opt := installer.Options{
		Root: g.root, Repo: g.repo, Cache: g.cache, Yes: g.yes,
		NoDeps: *noDeps, Reinstall: *reinstall, Force: *force, Refresh: *refresh,
		Logger: logger,
	}
	inst, err := installer.New(opt)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	defer inst.Close()
	if g.root != "/" {
		prepareTarget(g.root)
	}
	if err := inst.Install(context.Background(), names, true); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	return 0
}

func cmdRemove(g globals, args []string) int {
	fs := flag.NewFlagSet("remove", flag.ContinueOnError)
	addCommon(fs, &g)
	autoremove := fs.Bool("autoremove", false, "also remove orphaned dependencies")
	force := fs.Bool("force", false, "remove even if other packages depend on it")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	names := fs.Args()
	if len(names) == 0 {
		fmt.Fprintln(os.Stderr, "cres: remove needs at least one package")
		return 2
	}
	if g.root == "/" && os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "cres: removing system packages requires root")
		return 1
	}
	logger := newLogger(g)
	defer logger.Close()
	inst, err := installer.New(installer.Options{Root: g.root, Repo: g.repo, Cache: g.cache, Yes: g.yes, Force: *force, Logger: logger})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	defer inst.Close()
	if err := inst.Remove(context.Background(), names, *autoremove); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	return 0
}

func cmdUpdate(g globals, args []string) int {
	fs := flag.NewFlagSet("update", flag.ContinueOnError)
	addCommon(fs, &g)
	check := fs.Bool("check", false, "only report available updates")
	force := fs.Bool("force", false, "ignore conflicts")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if g.root == "/" && os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "cres: updating system packages requires root")
		return 1
	}
	logger := newLogger(g)
	defer logger.Close()
	if *check {
		return updateCheck(g, logger)
	}
	inst, err := installer.New(installer.Options{Root: g.root, Repo: g.repo, Cache: g.cache, Yes: g.yes, Force: *force, Refresh: true, Logger: logger})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	defer inst.Close()
	if err := inst.Update(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	return 0
}

func updateCheck(g globals, logger *creslog.Logger) int {
	client := repository.New(g.repo, cacheDir(g))
	idx, err := client.LoadIndex(context.Background(), true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	db := database.OpenRead(g.root)
	installed, err := db.Installed()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	var updates []string
	for name, inst := range installed {
		pkg := idx.Find(name)
		if pkg == nil {
			continue
		}
		if model.CompareVersions(inst.Version, pkg.Version) < 0 {
			updates = append(updates, fmt.Sprintf("%s %s -> %s", name, inst.Version, pkg.Version))
		}
	}
	sort.Strings(updates)
	for _, line := range updates {
		fmt.Println(line)
	}
	if len(updates) == 0 {
		fmt.Println("system is up to date")
		return 0
	}
	return 2
}

func cmdSearch(g globals, args []string) int {
	fs := flag.NewFlagSet("search", flag.ContinueOnError)
	addCommon(fs, &g)
	refresh := fs.Bool("refresh", false, "refresh the package index")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	pattern := strings.Join(fs.Args(), " ")
	client := repository.New(g.repo, cacheDir(g))
	idx, err := client.LoadIndex(context.Background(), *refresh)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	results := idx.Search(pattern)
	sort.Slice(results, func(i, j int) bool { return results[i].Name < results[j].Name })
	for _, pkg := range results {
		kind := "app"
		if pkg.System {
			kind = "system"
		}
		fmt.Printf("%-24s %-18s %-8s %s\n", pkg.Name, pkg.Version, kind, pkg.Description)
	}
	fmt.Printf("%d package(s)\n", len(results))
	return 0
}

func cmdInfo(g globals, args []string) int {
	fs := flag.NewFlagSet("info", flag.ContinueOnError)
	addCommon(fs, &g)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "cres: info needs exactly one package")
		return 2
	}
	client := repository.New(g.repo, cacheDir(g))
	idx, err := client.LoadIndex(context.Background(), false)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	pkg := idx.Provider(fs.Arg(0))
	if pkg == nil {
		fmt.Fprintf(os.Stderr, "cres: no package named %s\n", fs.Arg(0))
		return 1
	}
	fmt.Printf("name:        %s\n", pkg.Name)
	fmt.Printf("version:     %s\n", pkg.Version)
	fmt.Printf("description: %s\n", pkg.Description)
	fmt.Printf("category:    %s\n", pkg.Category)
	fmt.Printf("system:      %v\n", pkg.System)
	fmt.Printf("deps:        %s\n", strings.Join(pkg.Deps, " "))
	fmt.Printf("provides:    %s\n", strings.Join(pkg.Provides, " "))
	fmt.Printf("conflicts:   %s\n", strings.Join(pkg.Conflicts, " "))
	fmt.Printf("checksum:    %s\n", pkg.Checksum)
	fmt.Printf("url:         %s\n", pkg.URL)
	if db := database.OpenRead(g.root); db != nil {
		if inst, err := db.Get(pkg.Name); err == nil && inst != nil {
			fmt.Printf("installed:   %s (%s)\n", inst.Version, inst.InstalledAt.Format("2006-01-02 15:04"))
		}
	}
	return 0
}

func cmdList(g globals, args []string) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	addCommon(fs, &g)
	available := fs.Bool("available", false, "list available packages instead of installed")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *available {
		client := repository.New(g.repo, cacheDir(g))
		idx, err := client.LoadIndex(context.Background(), false)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cres: %v\n", err)
			return 1
		}
		pkgs := append([]model.Package{}, idx.Packages...)
		sort.Slice(pkgs, func(i, j int) bool { return pkgs[i].Name < pkgs[j].Name })
		for _, pkg := range pkgs {
			fmt.Printf("%-24s %s\n", pkg.Name, pkg.Version)
		}
		return 0
	}
	db := database.OpenRead(g.root)
	installed, err := db.Installed()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	world, _ := db.World()
	explicit := map[string]bool{}
	for _, name := range world {
		explicit[name] = true
	}
	names := make([]string, 0, len(installed))
	for name := range installed {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		pkg := installed[name]
		mark := " "
		if explicit[name] {
			mark = "*"
		}
		fmt.Printf("%s %-24s %s\n", mark, pkg.Name, pkg.Version)
	}
	return 0
}

func cmdSync(g globals, args []string) int {
	fs := flag.NewFlagSet("sync", flag.ContinueOnError)
	addCommon(fs, &g)
	check := fs.Bool("check", false, "report changes without applying")
	systemMode := fs.Bool("system", false, "apply the system config")
	userMode := fs.Bool("user", false, "apply the user config")
	configPath := fs.String("config", "", "alternate config file")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *systemMode && *userMode {
		fmt.Fprintln(os.Stderr, "cres: --system and --user are mutually exclusive")
		return 2
	}
	logger := newLogger(g)
	defer logger.Close()
	if *userMode || (!*systemMode && g.root == "/" && os.Geteuid() != 0) {
		home, _ := os.UserHomeDir()
		if home == "" {
			fmt.Fprintln(os.Stderr, "cres: HOME is not set")
			return 1
		}
		var cfg *config.Config
		var err error
		if *configPath != "" {
			data, rerr := os.ReadFile(*configPath)
			if rerr != nil {
				fmt.Fprintf(os.Stderr, "cres: %v\n", rerr)
				return 1
			}
			cfg, err = config.Parse(data, config.UserScope)
		} else {
			cfg, err = config.LoadUser(home)
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "cres: %v\n", err)
			return 1
		}
		res, err := syncconfig.ApplyUser(home, cfg, *check, logger)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cres: %v\n", err)
			return 1
		}
		printSync(res)
		if *check && res.Changed {
			return 2
		}
		return 0
	}
	if g.root == "/" && os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "cres: syncing the system config requires root")
		return 1
	}
	var cfg *config.Config
	var err error
	if *configPath != "" {
		data, rerr := os.ReadFile(*configPath)
		if rerr != nil {
			fmt.Fprintf(os.Stderr, "cres: %v\n", rerr)
			return 1
		}
		cfg, err = config.Parse(data, config.SystemScope)
	} else {
		cfg, err = config.LoadSystem(g.root)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	inst, err := installer.New(installer.Options{Root: g.root, Repo: g.repo, Cache: g.cache, Yes: g.yes, Refresh: true, Logger: logger})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	defer inst.Close()
	if err := inst.LoadIndex(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	pm := &packageAdapter{inst: inst}
	res, err := syncconfig.ApplySystem(g.root, cfg, *check, pm, logger)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	printSync(res)
	if *check && res.Changed {
		return 2
	}
	return 0
}

type packageAdapter struct{ inst *installer.Installer }

func (p *packageAdapter) InstalledVersion(name string) (string, bool) {
	pkg, err := p.inst.DB.Get(name)
	if err != nil || pkg == nil {
		return "", false
	}
	return pkg.Version, true
}

func (p *packageAdapter) InstallPackages(names []string) error {
	return p.inst.Install(context.Background(), names, true)
}

func printSync(res syncconfig.Result) {
	for _, msg := range res.Messages {
		fmt.Println(msg)
	}
	if !res.Changed {
		fmt.Println("config is up to date")
	}
}

func cmdBuild(g globals, args []string) int {
	fs := flag.NewFlagSet("build", flag.ContinueOnError)
	addCommon(fs, &g)
	defs := fs.String("defs", build.DefinitionsDir(), "build definitions directory")
	out := fs.String("out", build.DefaultOutDir(), "output packages directory")
	force := fs.Bool("force", false, "replace an existing package directory")
	logDir := fs.String("log-dir", filepath.Join("build", "logs"), "build logs directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "cres: build needs exactly one definition name")
		return 2
	}
	def, err := build.LoadDefinition(*defs, fs.Arg(0))
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	logger := newLogger(g)
	defer logger.Close()
	if _, err := build.Build(context.Background(), def, build.Options{
		DefsDir: *defs, Name: fs.Arg(0), OutDir: *out, Cache: g.cache, LogDir: *logDir, Force: *force, Logger: logger,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	return 0
}

func cmdPublish(g globals, args []string) int {
	fs := flag.NewFlagSet("publish", flag.ContinueOnError)
	addCommon(fs, &g)
	replace := fs.Bool("replace", false, "allow replacing an existing package")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "cres: publish needs a package directory")
		return 2
	}
	logger := newLogger(g)
	defer logger.Close()
	if err := build.Publish(context.Background(), fs.Arg(0), g.yes, *replace, logger); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	return 0
}

func cmdMkIndex(g globals, args []string) int {
	fs := flag.NewFlagSet("mkindex", flag.ContinueOnError)
	addCommon(fs, &g)
	dir := fs.String("dir", "packages", "packages directory")
	out := fs.String("out", "cres/index.json", "index output path")
	base := fs.String("base", repository.DefaultBase, "repository base URL")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	idx, err := MakeIndex(*dir, *base)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	data, err := repository.EncodeIndex(idx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "cres: %v\n", err)
		return 1
	}
	fmt.Printf("wrote %s with %d packages\n", *out, len(idx.Packages))
	return 0
}

type legacyMeta struct {
	Name         string   `json:"name"`
	Filename     string   `json:"filename"`
	Parts        int      `json:"parts"`
	SHA256       string   `json:"sha256"`
	System       bool     `json:"system"`
	Version      string   `json:"version"`
	Depends      []string `json:"depends"`
	Deps         []string `json:"deps"`
	Provides     []string `json:"provides"`
	Conflicts    []string `json:"conflicts"`
	Replaces     []string `json:"replaces"`
	Category     string   `json:"category"`
	Description  string   `json:"description"`
	License      string   `json:"license"`
	URL          string   `json:"url"`
	Checksum     string   `json:"checksum"`
	Architecture string   `json:"architecture"`
}

func MakeIndex(dir, base string) (model.Index, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return model.Index{}, err
	}
	var idx model.Index
	idx.Version = model.IndexVersion
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		pkgDir := filepath.Join(dir, name)
		metaPath := filepath.Join(pkgDir, "package.json")
		data, err := os.ReadFile(metaPath)
		if err != nil {
			continue
		}
		var legacy legacyMeta
		if err := json.Unmarshal(data, &legacy); err != nil {
			return model.Index{}, fmt.Errorf("%s: %w", metaPath, err)
		}
		pkg := model.Package{
			Name:         name,
			Version:      legacy.Version,
			Description:  legacy.Description,
			Architecture: legacy.Architecture,
			License:      legacy.License,
			Category:     legacy.Category,
			System:       legacy.System,
			Parts:        legacy.Parts,
			Deps:         legacy.Deps,
			Provides:     legacy.Provides,
			Conflicts:    legacy.Conflicts,
			Replaces:     legacy.Replaces,
		}
		if len(pkg.Deps) == 0 {
			pkg.Deps = legacy.Depends
		}
		if pkg.Parts == 0 {
			pkg.Parts = 1
		}
		filename := legacy.Filename
		if filename == "" {
			for _, candidate := range []string{name + ".spk", name + ".tar.zst"} {
				if _, err := os.Stat(filepath.Join(pkgDir, candidate)); err == nil {
					filename = candidate
					break
				}
			}
		}
		if filename == "" {
			return model.Index{}, fmt.Errorf("%s: no archive filename", metaPath)
		}
		pkg.URL = legacy.URL
		if pkg.URL == "" {
			pkg.URL = strings.TrimRight(base, "/") + "/packages/" + name + "/" + filename
		}
		pkg.Checksum = legacy.Checksum
		if pkg.Checksum == "" {
			pkg.Checksum = legacy.SHA256
		}
		if pkg.Checksum == "" {
			archivePath := filepath.Join(pkgDir, filename)
			sum, err := fileSHA256(archivePath)
			if err != nil {
				return model.Index{}, fmt.Errorf("%s: %w", archivePath, err)
			}
			pkg.Checksum = sum
		}
		if pkg.Version == "" {
			return model.Index{}, fmt.Errorf("%s: missing version", metaPath)
		}
		if err := pkg.Validate(); err != nil {
			return model.Index{}, fmt.Errorf("%s: %w", metaPath, err)
		}
		idx.Packages = append(idx.Packages, pkg)
	}
	sort.Slice(idx.Packages, func(i, j int) bool { return idx.Packages[i].Name < idx.Packages[j].Name })
	return idx, nil
}

func cmdDoctor(g globals, args []string) int {
	fs := flag.NewFlagSet("doctor", flag.ContinueOnError)
	addCommon(fs, &g)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fmt.Printf("cres:        %s\n", Version)
	fmt.Printf("root:        %s\n", g.root)
	fmt.Printf("repo:        %s\n", g.repo)
	fmt.Printf("cache:       %s\n", cacheDir(g))
	fmt.Printf("root user:   %v\n", os.Geteuid() == 0)
	cfg, err := config.LoadSystem(g.root)
	if err != nil {
		fmt.Printf("system config: ERROR %v\n", err)
	} else {
		fmt.Printf("system config: %s\n", cfg.Source)
	}
	client := repository.New(g.repo, cacheDir(g))
	idx, err := client.LoadIndex(context.Background(), false)
	if err != nil {
		fmt.Printf("index:       ERROR %v\n", err)
	} else {
		fmt.Printf("index:       %d packages\n", len(idx.Packages))
	}
	if db := database.OpenRead(g.root); db != nil {
		installed, err := db.Installed()
		if err != nil {
			fmt.Printf("database:    ERROR %v\n", err)
		} else {
			fmt.Printf("database:    %d installed\n", len(installed))
		}
	}
	return 0
}

func cacheDir(g globals) string {
	if g.cache != "" {
		return g.cache
	}
	if g.root == "/" {
		return "/var/cache/cres"
	}
	return filepath.Join(g.root, "var/cache/cres")
}

func prepareTarget(root string) {
	for _, dir := range []string{"proc", "sys", "dev", "run", "etc", "var/lib/cres", "var/cache/cres"} {
		_ = os.MkdirAll(filepath.Join(root, dir), 0o755)
	}
	src := "/etc/resolv.conf"
	dst := filepath.Join(root, "etc/resolv.conf")
	if _, err := os.Stat(dst); err != nil {
		if data, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(dst, data, 0o644)
		}
	}
}

func fileSHA256(path string) (string, error) {
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
