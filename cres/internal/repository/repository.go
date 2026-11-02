package repository

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"silen/cres/internal/model"
)

const DefaultBase = "https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main"

type Client struct {
	BaseURL  string
	CacheDir string
	HTTP     *http.Client
	Progress func(name string, done, total int64)
}

func New(base, cache string) *Client {
	if strings.TrimSpace(base) == "" {
		base = DefaultBase
	}
	return &Client{
		BaseURL:  strings.TrimRight(base, "/"),
		CacheDir: cache,
		HTTP: &http.Client{
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				ForceAttemptHTTP2:     true,
				MaxIdleConns:          8,
				IdleConnTimeout:       60 * time.Second,
				TLSHandshakeTimeout:   20 * time.Second,
				ResponseHeaderTimeout: 60 * time.Second,
			},
		},
	}
}

func (c *Client) indexURLs() []string {
	return []string{
		c.BaseURL + "/cres/index.json",
		c.BaseURL + "/index.json",
	}
}

func (c *Client) IndexPath() string {
	return filepath.Join(c.CacheDir, "index.json")
}

func (c *Client) LoadIndex(ctx context.Context, refresh bool) (model.Index, error) {
	if !refresh {
		if data, err := os.ReadFile(c.IndexPath()); err == nil {
			if idx, err := model.ParseIndex(data); err == nil {
				return idx, nil
			}
		}
	}
	var lastErr error
	for _, url := range c.indexURLs() {
		data, err := c.get(ctx, url, 60*time.Second)
		if err != nil {
			lastErr = err
			continue
		}
		idx, err := model.ParseIndex(data)
		if err != nil {
			lastErr = fmt.Errorf("%s: %w", url, err)
			continue
		}
		if err := os.MkdirAll(c.CacheDir, 0o755); err != nil {
			return idx, nil
		}
		_ = atomicWrite(c.IndexPath(), data)
		return idx, nil
	}
	if data, err := os.ReadFile(c.IndexPath()); err == nil {
		idx, err := model.ParseIndex(data)
		if err == nil {
			return idx, nil
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no package index available")
	}
	return model.Index{}, lastErr
}

func (c *Client) get(ctx context.Context, url string, timeout time.Duration) ([]byte, error) {
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		reqCtx, cancel := context.WithTimeout(ctx, timeout)
		req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
		if err != nil {
			cancel()
			return nil, err
		}
		req.Header.Set("User-Agent", "cres/1.0 (Silen Linux)")
		resp, err := c.HTTP.Do(req)
		if err != nil {
			cancel()
			lastErr = err
		} else {
			body, readErr := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024))
			resp.Body.Close()
			cancel()
			if resp.StatusCode == http.StatusOK && readErr == nil {
				return body, nil
			}
			if resp.StatusCode == http.StatusNotFound {
				return nil, fmt.Errorf("not found: %s", url)
			}
			lastErr = fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
			if readErr != nil {
				lastErr = readErr
			}
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(attempt) * time.Second):
		}
	}
	return nil, lastErr
}

func (c *Client) FetchPackage(ctx context.Context, pkg model.Package) (string, error) {
	if err := pkg.Validate(); err != nil {
		return "", err
	}
	if err := os.MkdirAll(c.CacheDir, 0o755); err != nil {
		return "", err
	}
	safe := strings.NewReplacer("/", "_", " ", "_").Replace(pkg.Name)
	cachePath := filepath.Join(c.CacheDir, fmt.Sprintf("%s-%s-%s.archive", safe, sanitizeVersion(pkg.Version), pkg.Checksum[:12]))
	if ok, _ := verifyFile(cachePath, pkg.Checksum); ok {
		return cachePath, nil
	}

	tmp, err := os.CreateTemp(c.CacheDir, safe+"-*.part")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	tmp.Close()
	_ = os.Remove(tmpPath)
	defer os.Remove(tmpPath)

	url := pkg.URL
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		url = c.BaseURL + "/" + strings.TrimLeft(url, "/")
	}

	err = c.download(ctx, pkg.Name, url, tmpPath)
	if err != nil && pkg.Parts > 1 {
		_ = os.Remove(tmpPath)
		err = c.downloadParts(ctx, pkg.Name, url, pkg.Parts, tmpPath)
	}
	if err != nil {
		return "", err
	}

	sum, err := fileSHA256(tmpPath)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(sum, pkg.Checksum) {
		return "", fmt.Errorf("sha256 mismatch for %s: expected %s, got %s", pkg.Name, pkg.Checksum, sum)
	}
	if err := os.Rename(tmpPath, cachePath); err != nil {
		return "", err
	}
	return cachePath, nil
}

func (c *Client) download(ctx context.Context, name, url, dest string) error {
	var lastErr error
	for attempt := 1; attempt <= 3; attempt++ {
		start := int64(0)
		if st, err := os.Stat(dest); err == nil {
			start = st.Size()
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "cres/1.0 (Silen Linux)")
		if start > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", start))
		}
		resp, err := c.HTTP.Do(req)
		if err != nil {
			lastErr = err
		} else if resp.StatusCode == http.StatusNotFound {
			resp.Body.Close()
			return errNotFound
		} else if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
			resp.Body.Close()
			lastErr = fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
		} else {
			if resp.StatusCode == http.StatusOK {
				start = 0
			}
			flags := os.O_CREATE | os.O_WRONLY
			if start > 0 {
				flags |= os.O_APPEND
			} else {
				flags |= os.O_TRUNC
			}
			out, err := os.OpenFile(dest, flags, 0o644)
			if err != nil {
				resp.Body.Close()
				return err
			}
			total := resp.ContentLength
			if total > 0 {
				total += start
			}
			written := start
			buf := make([]byte, 256*1024)
			for {
				n, readErr := resp.Body.Read(buf)
				if n > 0 {
					if _, werr := out.Write(buf[:n]); werr != nil {
						out.Close()
						resp.Body.Close()
						return werr
					}
					written += int64(n)
					if c.Progress != nil {
						c.Progress(name, written, total)
					}
				}
				if readErr == io.EOF {
					break
				}
				if readErr != nil {
					lastErr = readErr
					break
				}
			}
			out.Close()
			resp.Body.Close()
			if lastErr == nil {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Duration(attempt) * 2 * time.Second):
		}
	}
	return lastErr
}

func (c *Client) downloadParts(ctx context.Context, name, url string, parts int, dest string) error {
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()
	for i := 0; i < parts; i++ {
		partURL := fmt.Sprintf("%s.%03d", url, i)
		partTmp := dest + fmt.Sprintf(".p%03d", i)
		_ = os.Remove(partTmp)
		if err := c.download(ctx, name, partURL, partTmp); err != nil {
			_ = os.Remove(partTmp)
			return fmt.Errorf("part %d/%d: %w", i+1, parts, err)
		}
		in, err := os.Open(partTmp)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, in)
		in.Close()
		_ = os.Remove(partTmp)
		if err != nil {
			return err
		}
	}
	return nil
}

var errNotFound = fmt.Errorf("not found")

func IsNotFound(err error) bool {
	return err == errNotFound || strings.Contains(err.Error(), "not found")
}

func sanitizeVersion(v string) string {
	var b strings.Builder
	for _, r := range v {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '-' || r == '_' || r == '+' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "0"
	}
	return b.String()
}

func verifyFile(path, checksum string) (bool, error) {
	sum, err := fileSHA256(path)
	if err != nil {
		return false, err
	}
	return strings.EqualFold(sum, checksum), nil
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

func atomicWrite(path string, data []byte) error {
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
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	tmp.Close()
	return os.Rename(name, path)
}

func EncodeIndex(idx model.Index) ([]byte, error) {
	idx.Version = model.IndexVersion
	idx.Generated = time.Now().UTC().Format(time.RFC3339)
	return json.MarshalIndent(idx, "", "  ")
}
