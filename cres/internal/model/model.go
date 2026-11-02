package model

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	IndexVersion         = 2
	PackageSchemaVersion = 2
	ConfigVersion        = 1
)

var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9+._-]*$`)

type Hook struct {
	Event string `json:"event"`
	Run   string `json:"run"`
}

type Package struct {
	Name          string   `json:"name"`
	Version       string   `json:"version"`
	Release       int      `json:"release,omitempty"`
	SchemaVersion int      `json:"schema_version,omitempty"`
	Description   string   `json:"description,omitempty"`
	Architecture  string   `json:"architecture,omitempty"`
	OS            string   `json:"os,omitempty"`
	Filename      string   `json:"filename,omitempty"`
	URL           string   `json:"url"`
	Checksum      string   `json:"checksum"`
	Size          int64    `json:"size,omitempty"`
	License       string   `json:"license,omitempty"`
	Maintainer    string   `json:"maintainer,omitempty"`
	Packager      string   `json:"packager,omitempty"`
	BuildDate     string   `json:"build_date,omitempty"`
	Signature     string   `json:"signature,omitempty"`
	Deps          []string `json:"deps,omitempty"`
	OptDeps       []string `json:"optdepends,omitempty"`
	Makedepends   []string `json:"makedepends,omitempty"`
	Checkdepends  []string `json:"checkdepends,omitempty"`
	Provides      []string `json:"provides,omitempty"`
	Conflicts     []string `json:"conflicts,omitempty"`
	Replaces      []string `json:"replaces,omitempty"`
	Groups        []string `json:"groups,omitempty"`
	Backup        []string `json:"backup,omitempty"`
	Hooks         []Hook   `json:"hooks,omitempty"`
	Files         []string `json:"files,omitempty"`
	Parts         int      `json:"parts,omitempty"`
	System        bool     `json:"system,omitempty"`
	Category      string   `json:"category,omitempty"`
}

var hookEvents = map[string]bool{"post-install": true, "post-remove": true}
var packageOS = map[string]bool{"": true, "any": true, "silen": true}

type Index struct {
	Version   int       `json:"version"`
	Generated string    `json:"generated,omitempty"`
	Packages  []Package `json:"packages"`
}

type Installed struct {
	Name        string    `json:"name"`
	Version     string    `json:"version"`
	Release     int       `json:"release,omitempty"`
	Explicit    bool      `json:"explicit"`
	System      bool      `json:"system,omitempty"`
	Deps        []string  `json:"deps,omitempty"`
	Backup      []string  `json:"backup,omitempty"`
	Hooks       []Hook    `json:"hooks,omitempty"`
	Files       []File    `json:"files,omitempty"`
	InstalledAt time.Time `json:"installed_at"`
	Checksum    string    `json:"checksum,omitempty"`
}

type File struct {
	Path   string `json:"path"`
	Type   string `json:"type"`
	Mode   uint32 `json:"mode"`
	SHA256 string `json:"sha256,omitempty"`
}

type Plan struct {
	Install []Package
	Remove  []string
	Reasons map[string]string
	Upgrade map[string]string
}

func (p *Package) UnmarshalJSON(data []byte) error {
	type rawPackage Package
	var raw rawPackage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*p = Package(raw)
	var keys struct {
		Deps       *[]string `json:"deps"`
		Depends    *[]string `json:"depends"`
		Optdeps    *[]string `json:"optdeps"`
		Optdepends *[]string `json:"optdepends"`
	}
	if err := json.Unmarshal(data, &keys); err != nil {
		return err
	}
	if keys.Deps != nil {
		p.Deps = *keys.Deps
	} else if keys.Depends != nil {
		p.Deps = *keys.Depends
	}
	if keys.Optdepends != nil {
		p.OptDeps = *keys.Optdepends
	} else if keys.Optdeps != nil {
		p.OptDeps = *keys.Optdeps
	}
	return nil
}

func (p Package) Validate() error {
	return p.validate(true)
}

func (p Package) validate(strict bool) error {
	if !nameRE.MatchString(p.Name) {
		return fmt.Errorf("invalid package name %q", p.Name)
	}
	if strings.TrimSpace(p.Version) == "" {
		return fmt.Errorf("%s: empty version", p.Name)
	}
	if strict && strings.TrimSpace(p.URL) == "" {
		return fmt.Errorf("%s: empty url", p.Name)
	}
	if strict || p.Checksum != "" {
		if !ValidChecksum(p.Checksum) {
			return fmt.Errorf("%s: invalid sha256 checksum %q", p.Name, p.Checksum)
		}
		if placeholderChecksum(p.Checksum) {
			return fmt.Errorf("%s: placeholder sha256 checksum %q", p.Name, p.Checksum)
		}
	}
	if p.Size < 0 {
		return fmt.Errorf("%s: negative size %d", p.Name, p.Size)
	}
	if p.Parts < 0 || p.Parts > 999 {
		return fmt.Errorf("%s: invalid parts %d", p.Name, p.Parts)
	}
	if p.Release < 0 {
		return fmt.Errorf("%s: invalid release %d", p.Name, p.Release)
	}
	if p.SchemaVersion != 0 && p.SchemaVersion != PackageSchemaVersion {
		return fmt.Errorf("%s: unsupported schema_version %d", p.Name, p.SchemaVersion)
	}
	if !packageOS[p.OS] {
		return fmt.Errorf("%s: unsupported os %q (want silen, any or empty)", p.Name, p.OS)
	}
	if p.Filename != "" && strings.ContainsAny(p.Filename, "/\\") {
		return fmt.Errorf("%s: filename %q must be a base name", p.Name, p.Filename)
	}
	if p.BuildDate != "" {
		if _, err := time.Parse(time.RFC3339, p.BuildDate); err != nil {
			return fmt.Errorf("%s: build_date %q is not RFC3339", p.Name, p.BuildDate)
		}
	}
	for _, d := range p.Deps {
		if _, _, _, err := ParseConstraint(d); err != nil {
			return fmt.Errorf("%s: %w", p.Name, err)
		}
	}
	for _, d := range p.OptDeps {
		if _, _, _, _, err := ParseOptDep(d); err != nil {
			return fmt.Errorf("%s: %w", p.Name, err)
		}
	}
	for _, d := range append(append([]string{}, p.Makedepends...), p.Checkdepends...) {
		if _, _, _, err := ParseConstraint(d); err != nil {
			return fmt.Errorf("%s: %w", p.Name, err)
		}
	}
	for _, d := range append(append(append([]string{}, p.Provides...), p.Conflicts...), p.Replaces...) {
		if _, _, _, err := ParseConstraint(d); err != nil {
			return fmt.Errorf("%s: invalid dependency name %q", p.Name, d)
		}
	}
	for _, g := range append([]string{}, p.Groups...) {
		if !nameRE.MatchString(g) {
			return fmt.Errorf("%s: invalid group %q", p.Name, g)
		}
	}
	for _, b := range p.Backup {
		if !validRelPath(b) {
			return fmt.Errorf("%s: invalid backup path %q", p.Name, b)
		}
	}
	for _, f := range p.Files {
		if !validRelPath(f) {
			return fmt.Errorf("%s: invalid file list path %q", p.Name, f)
		}
	}
	for _, h := range p.Hooks {
		if err := validateHook(h); err != nil {
			return fmt.Errorf("%s: %w", p.Name, err)
		}
	}
	return nil
}

func validateHook(h Hook) error {
	if !hookEvents[h.Event] {
		return fmt.Errorf("hook event %q must be post-install or post-remove", h.Event)
	}
	if !validRelPath(h.Run) {
		return fmt.Errorf("hook run path %q must be relative to the payload", h.Run)
	}
	if !strings.HasSuffix(h.Run, ".hook") {
		return fmt.Errorf("hook run path %q must end in .hook", h.Run)
	}
	if !strings.HasPrefix(h.Run, "usr/lib/cres/hooks/") {
		return fmt.Errorf("hook run path %q must live under usr/lib/cres/hooks", h.Run)
	}
	return nil
}

func validRelPath(p string) bool {
	if p == "" || strings.Contains(p, "\x00") || strings.HasPrefix(p, "/") {
		return false
	}
	for _, part := range strings.Split(filepath.ToSlash(filepath.Clean("/"+p)), "/") {
		if part == ".." {
			return false
		}
	}
	return true
}

func placeholderChecksum(s string) bool {
	for i := 1; i < len(s); i++ {
		if s[i] != s[0] {
			return false
		}
	}
	return true
}

func ParseOptDep(dep string) (name, op, version, reason string, err error) {
	dep = strings.TrimSpace(dep)
	if i := strings.Index(dep, ":"); i > 0 {
		reason = strings.TrimSpace(dep[i+1:])
		dep = strings.TrimSpace(dep[:i])
	}
	if strings.Contains(reason, "\n") || strings.Contains(reason, "\x00") {
		return "", "", "", "", fmt.Errorf("invalid optional dependency %q", dep+":"+reason)
	}
	name, op, version, err = ParseConstraint(dep)
	return name, op, version, reason, err
}

func ParseConstraint(dep string) (name, op, version string, err error) {
	dep = strings.TrimSpace(dep)
	for _, candidate := range []string{">=", "<=", "=", ">", "<"} {
		if idx := strings.Index(dep, candidate); idx > 0 {
			name = strings.TrimSpace(dep[:idx])
			version = strings.TrimSpace(dep[idx+len(candidate):])
			op = candidate
			break
		}
	}
	if op == "" {
		name = dep
	}
	if !nameRE.MatchString(name) {
		return "", "", "", fmt.Errorf("invalid dependency name %q", dep)
	}
	if op != "" && version == "" {
		return "", "", "", fmt.Errorf("dependency %q has no version", dep)
	}
	return name, op, version, nil
}

func ValidChecksum(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range strings.ToLower(s) {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func (i Index) Validate() error {
	if i.Version != 0 && i.Version > IndexVersion {
		return fmt.Errorf("unsupported index version %d", i.Version)
	}
	strict := i.Version >= IndexVersion
	seen := map[string]bool{}
	for _, p := range i.Packages {
		if err := p.validate(strict); err != nil {
			return err
		}
		if seen[p.Name] {
			return fmt.Errorf("duplicate package %s in index", p.Name)
		}
		seen[p.Name] = true
	}
	return nil
}

func ParseIndex(data []byte) (Index, error) {
	var idx Index
	trimmed := strings.TrimSpace(string(data))
	if strings.HasPrefix(trimmed, "[") {
		if err := json.Unmarshal(data, &idx.Packages); err != nil {
			return idx, err
		}
		idx.Version = 1
	} else {
		if err := json.Unmarshal(data, &idx); err != nil {
			return idx, err
		}
	}
	if err := idx.Validate(); err != nil {
		return idx, err
	}
	return idx, nil
}

func (i Index) Find(name string) *Package {
	for n := range i.Packages {
		if i.Packages[n].Name == name {
			return &i.Packages[n]
		}
	}
	return nil
}

func (i Index) Provider(name string) *Package {
	if p := i.Find(name); p != nil {
		return p
	}
	for n := range i.Packages {
		for _, provided := range i.Packages[n].Provides {
			if provided == name {
				return &i.Packages[n]
			}
		}
	}
	return nil
}

func (i Index) Search(pattern string) []Package {
	pattern = strings.ToLower(pattern)
	var out []Package
	for _, p := range i.Packages {
		if strings.Contains(strings.ToLower(p.Name), pattern) || strings.Contains(strings.ToLower(p.Description), pattern) {
			out = append(out, p)
		}
	}
	return out
}

func CompareVersions(a, b string) int {
	as := versionParts(a)
	bs := versionParts(b)
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		var x, y string
		if i < len(as) {
			x = as[i]
		}
		if i < len(bs) {
			y = bs[i]
		}
		if x == y {
			continue
		}
		xn, xerr := strconv.ParseUint(x, 10, 64)
		yn, yerr := strconv.ParseUint(y, 10, 64)
		if xerr == nil && yerr == nil {
			if xn < yn {
				return -1
			}
			return 1
		}
		if x == "" {
			return -1
		}
		if y == "" {
			return 1
		}
		if x < y {
			return -1
		}
		return 1
	}
	return 0
}

func versionParts(v string) []string {
	v = strings.TrimSpace(v)
	v = strings.TrimPrefix(v, "v")
	var out []string
	var cur strings.Builder
	lastDigit := false
	for i, r := range v {
		digit := r >= '0' && r <= '9'
		if i > 0 && digit != lastDigit && cur.Len() > 0 {
			out = append(out, cur.String())
			cur.Reset()
		}
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') {
			cur.WriteRune(r)
			lastDigit = digit
		} else {
			if cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
			}
			lastDigit = false
		}
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

func Satisfies(version, op, required string) bool {
	if op == "" {
		return true
	}
	cmp := CompareVersions(version, required)
	switch op {
	case "=":
		return cmp == 0
	case ">":
		return cmp > 0
	case "<":
		return cmp < 0
	case ">=":
		return cmp >= 0
	case "<=":
		return cmp <= 0
	}
	return false
}

func NewerOrEqual(installed Installed, pkg Package) bool {
	cmp := CompareVersions(installed.Version, pkg.Version)
	if cmp != 0 {
		return cmp > 0
	}
	return installed.Release >= pkg.Release
}
