package model

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	IndexVersion  = 1
	ConfigVersion = 1
)

var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9+._-]*$`)

type Package struct {
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	Description  string   `json:"description,omitempty"`
	Architecture string   `json:"architecture,omitempty"`
	URL          string   `json:"url"`
	Checksum     string   `json:"checksum"`
	Size         int64    `json:"size,omitempty"`
	License      string   `json:"license,omitempty"`
	Deps         []string `json:"deps,omitempty"`
	Provides     []string `json:"provides,omitempty"`
	Conflicts    []string `json:"conflicts,omitempty"`
	Replaces     []string `json:"replaces,omitempty"`
	OptDeps      []string `json:"optdeps,omitempty"`
	Parts        int      `json:"parts,omitempty"`
	System       bool     `json:"system,omitempty"`
	Category     string   `json:"category,omitempty"`
}

type Index struct {
	Version   int       `json:"version"`
	Generated string    `json:"generated,omitempty"`
	Packages  []Package `json:"packages"`
}

type Installed struct {
	Name        string    `json:"name"`
	Version     string    `json:"version"`
	Explicit    bool      `json:"explicit"`
	Deps        []string  `json:"deps,omitempty"`
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

func (p Package) Validate() error {
	if !nameRE.MatchString(p.Name) {
		return fmt.Errorf("invalid package name %q", p.Name)
	}
	if strings.TrimSpace(p.Version) == "" {
		return fmt.Errorf("%s: empty version", p.Name)
	}
	if strings.TrimSpace(p.URL) == "" {
		return fmt.Errorf("%s: empty url", p.Name)
	}
	if !ValidChecksum(p.Checksum) {
		return fmt.Errorf("%s: invalid sha256 checksum %q", p.Name, p.Checksum)
	}
	if p.Parts < 0 || p.Parts > 999 {
		return fmt.Errorf("%s: invalid parts %d", p.Name, p.Parts)
	}
	for _, d := range p.Deps {
		if _, _, _, err := ParseConstraint(d); err != nil {
			return fmt.Errorf("%s: %w", p.Name, err)
		}
	}
	for _, d := range append(append(append([]string{}, p.Provides...), p.Conflicts...), p.Replaces...) {
		if !nameRE.MatchString(d) {
			return fmt.Errorf("%s: invalid dependency name %q", p.Name, d)
		}
	}
	return nil
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
	if i.Version != 0 && i.Version != IndexVersion {
		return fmt.Errorf("unsupported index version %d", i.Version)
	}
	seen := map[string]bool{}
	for _, p := range i.Packages {
		if err := p.Validate(); err != nil {
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
		idx.Version = IndexVersion
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
