package repository

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"silen/cres/internal/model"
)

func TestFetchPackagePrefersLocalAndFallsBackOnline(t *testing.T) {
	localPayload := []byte("local archive")
	remotePayload := []byte("remote archive")
	var remoteRequests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		remoteRequests.Add(1)
		if r.URL.Path != "/packages/remote/remote.spk" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(remotePayload)
	}))
	defer server.Close()

	localRoot := t.TempDir()
	localPackageDir := filepath.Join(localRoot, "packages", "local")
	if err := os.MkdirAll(localPackageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(localPackageDir, "local.spk"), localPayload, 0o644); err != nil {
		t.Fatal(err)
	}
	localSum := sha256.Sum256(localPayload)
	remoteSum := sha256.Sum256(remotePayload)
	idx := model.Index{Version: model.IndexVersion, Packages: []model.Package{
		{Name: "local", Version: "1.0", Filename: "local.spk", URL: server.URL + "/packages/local/local.spk", Checksum: hex.EncodeToString(localSum[:]), OS: "any", SchemaVersion: model.PackageSchemaVersion},
		{Name: "remote", Version: "1.0", Filename: "remote.spk", URL: server.URL + "/packages/remote/remote.spk", Checksum: hex.EncodeToString(remoteSum[:]), OS: "any", SchemaVersion: model.PackageSchemaVersion},
	}}
	index, err := json.Marshal(idx)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(localRoot, "cres"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(localRoot, "cres", "index.json"), index, 0o644); err != nil {
		t.Fatal(err)
	}

	client := New(localRoot, t.TempDir())
	loaded, err := client.LoadIndex(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	localPath, err := client.FetchPackage(context.Background(), *loaded.Find("local"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(localPath)
	if err != nil || string(data) != string(localPayload) {
		t.Fatalf("local payload = %q, err = %v", data, err)
	}
	if remoteRequests.Load() != 0 {
		t.Fatalf("local package made %d remote requests", remoteRequests.Load())
	}

	remotePath, err := client.FetchPackage(context.Background(), *loaded.Find("remote"))
	if err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(remotePath)
	if err != nil || string(data) != string(remotePayload) {
		t.Fatalf("remote payload = %q, err = %v", data, err)
	}
	if remoteRequests.Load() != 1 {
		t.Fatalf("remote fallback made %d requests, want 1", remoteRequests.Load())
	}
}
