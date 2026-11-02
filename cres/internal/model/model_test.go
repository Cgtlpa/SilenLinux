package model

import (
	"encoding/json"
	"os"
	"testing"
)

const testChecksum = "a5ad76e3a4a3fdf46e0cb4b4b047e18b2cf5eefaeaae6eebcbef05ccbeea4fe2"

func TestParseIndexLegacyArrayWithOptdepsAlias(t *testing.T) {
	raw := `[{"name":"iwtui","version":"0.2.1","url":"https://example/iwtui.spk","checksum":"` + testChecksum + `","optdeps":["iwd: for wireless"]}]`
	idx, err := ParseIndex([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(idx.Packages) != 1 {
		t.Fatalf("len=%d", len(idx.Packages))
	}
	if idx.Packages[0].OptDeps[0] != "iwd: for wireless" {
		t.Fatalf("optdeps alias lost: %v", idx.Packages[0].OptDeps)
	}
}

func TestPackageUnmarshalAliases(t *testing.T) {
	var p Package
	raw := `{"name":"x","version":"1","url":"https://x/x.spk","checksum":"` + testChecksum + `","depends":["a"],"optdeps":["b: reason"],"optdepends":["c: why"]}`
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	if len(p.Deps) != 1 || p.Deps[0] != "a" {
		t.Fatalf("depends alias: %v", p.Deps)
	}
	if len(p.OptDeps) != 1 || p.OptDeps[0] != "c: why" {
		t.Fatalf("optdeps precedence: %v", p.OptDeps)
	}
}

func TestPackageUnmarshalHooks(t *testing.T) {
	var p Package
	raw := `{"name":"x","version":"1","url":"https://x/x.spk","checksum":"` + testChecksum + `","hooks":[{"event":"post-install","run":"usr/lib/cres/hooks/x.hook"}]}`
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	if len(p.Hooks) != 1 || p.Hooks[0].Run != "usr/lib/cres/hooks/x.hook" {
		t.Fatalf("hooks: %v", p.Hooks)
	}
}

func TestPackageValidateRejects(t *testing.T) {
	cases := []Package{
		{Name: "x", Version: "1", URL: "https://x", Checksum: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
		{Name: "x", Version: "1", URL: "https://x", Checksum: testChecksum, Hooks: []Hook{{Event: "boot", Run: "usr/lib/cres/hooks/x.hook"}}},
		{Name: "x", Version: "1", URL: "https://x", Checksum: testChecksum, Backup: []string{"/etc/passwd"}},
		{Name: "x", Version: "1", URL: "https://x", Checksum: testChecksum, OS: "arch"},
		{Name: "x", Version: "1", URL: "https://x", Checksum: testChecksum, SchemaVersion: 3},
	}
	for i, c := range cases {
		if err := c.Validate(); err == nil {
			t.Fatalf("case %d accepted (%+v)", i, c)
		}
	}
}

func TestPackageValidateAcceptsV2(t *testing.T) {
	p := Package{
		Name: "x", Version: "1.0", Release: 2, SchemaVersion: 2, URL: "https://x/x.spk",
		Checksum:     testChecksum,
		Deps:         []string{"y>=1.2"},
		OptDeps:      []string{"z: optional thing"},
		Groups:       []string{"base"},
		Backup:       []string{"etc/x.conf"},
		Hooks:        []Hook{{Event: "post-install", Run: "usr/lib/cres/hooks/x.hook"}},
		Makedepends:  []string{"gcc"},
		Checkdepends: []string{"jq"},
	}
	if err := p.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestNewerOrEqualRelease(t *testing.T) {
	old := Installed{Version: "1.0", Release: 1}
	if !NewerOrEqual(old, Package{Version: "1.0", Release: 0}) {
		t.Fatal("same version higher release should count as newer or equal")
	}
	if NewerOrEqual(old, Package{Version: "1.0", Release: 2}) {
		t.Fatal("lower installed release should be upgradeable")
	}
	newer := Installed{Version: "1.0", Release: 5}
	if !NewerOrEqual(newer, Package{Version: "0.9", Release: 9}) {
		t.Fatal("newer installed version should skip regardless of release")
	}
}

func TestPublishedIndexParses(t *testing.T) {
	path := os.Getenv("TEST_PUBLISHED_INDEX")
	if path == "" {
		t.Skip("TEST_PUBLISHED_INDEX not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	idx, err := ParseIndex(data)
	if err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	t.Logf("published index parsed: version=%d packages=%d", idx.Version, len(idx.Packages))
}
