package archive

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"

	"silen/cres/internal/model"
)

type Options struct {
	Root           string
	AllowProtected bool
	Backup         func(rel string) error
	OnInstall      func(model.File)
	Log            func(string)
}

type Extractor struct {
	opt Options
}

func New(opt Options) *Extractor {
	if opt.Root == "" {
		opt.Root = "/"
	}
	return &Extractor{opt: opt}
}

var protectedPaths = map[string]bool{
	"etc/passwd":         true,
	"etc/shadow":         true,
	"etc/group":          true,
	"etc/gshadow":        true,
	"etc/fstab":          true,
	"etc/machine-id":     true,
	"etc/hostname":       true,
	"etc/hosts":          true,
	"etc/resolv.conf":    true,
	"etc/localtime":      true,
	"etc/sudoers":        true,
	"etc/default/grub":   true,
	"boot/grub/grub.cfg": true,
	"boot/grub/grubenv":  true,
}

func (e *Extractor) Extract(archivePath string) ([]model.File, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var head [4]byte
	n, _ := io.ReadFull(f, head[:])
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	var reader io.Reader = f
	switch {
	case n >= 2 && head[0] == 0x1f && head[1] == 0x8b:
		gz, err := gzip.NewReader(f)
		if err != nil {
			return nil, fmt.Errorf("gzip: %w", err)
		}
		defer gz.Close()
		reader = gz
	case n >= 4 && head[0] == 0x28 && head[1] == 0xb5 && head[2] == 0x2f && head[3] == 0xfd:
		zr, err := zstd.NewReader(f)
		if err != nil {
			return nil, fmt.Errorf("zstd: %w", err)
		}
		defer zr.Close()
		reader = zr
	}

	tr := tar.NewReader(reader)
	var files []model.File
	type hardlink struct {
		rel    string
		target string
		mode   uint32
	}
	var links []hardlink

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read archive: %w", err)
		}
		switch hdr.Typeflag {
		case tar.TypeXGlobalHeader, tar.TypeXHeader, tar.TypeGNULongName, tar.TypeGNULongLink:
			continue
		}
		rel, err := normalize(hdr.Name)
		if err != nil {
			return nil, err
		}
		if rel == "" {
			continue
		}
		mode := uint32(hdr.Mode) & 0o7777
		dest, err := e.securePath(rel)
		if err != nil {
			return nil, err
		}

		switch hdr.Typeflag {
		case tar.TypeDir:
			if st, err := os.Lstat(dest); err == nil {
				if st.Mode()&os.ModeSymlink != 0 {
					return nil, fmt.Errorf("refusing to replace symlink %s with a directory", rel)
				}
				if !st.IsDir() {
					return nil, fmt.Errorf("%s exists and is not a directory", rel)
				}
			} else if !os.IsNotExist(err) {
				return nil, err
			} else if err := os.MkdirAll(dest, os.FileMode(mode)|0o700); err != nil {
				return nil, err
			}
			_ = os.Chmod(dest, os.FileMode(mode))
			files = append(files, model.File{Path: rel, Type: "dir", Mode: mode})

		case tar.TypeReg, tar.TypeRegA:
			if e.skipProtected(rel) {
				e.logf("kept existing protected file %s", rel)
				continue
			}
			if err := e.prepareFile(dest, rel); err != nil {
				return nil, err
			}
			out, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(mode)|0o600)
			if err != nil {
				return nil, err
			}
			h := sha256.New()
			written, copyErr := io.Copy(io.MultiWriter(out, h), tr)
			closeErr := out.Close()
			if copyErr != nil {
				return nil, fmt.Errorf("write %s: %w", rel, copyErr)
			}
			if closeErr != nil {
				return nil, closeErr
			}
			if written != hdr.Size {
				return nil, fmt.Errorf("%s: short read (expected %d, got %d)", rel, hdr.Size, written)
			}
			if err := os.Chmod(dest, os.FileMode(mode)); err != nil {
				return nil, err
			}
			entry := model.File{Path: rel, Type: "file", Mode: mode, SHA256: hex.EncodeToString(h.Sum(nil))}
			files = append(files, entry)
			if e.opt.OnInstall != nil {
				e.opt.OnInstall(entry)
			}

		case tar.TypeSymlink:
			if e.skipProtected(rel) {
				e.logf("kept existing protected symlink %s", rel)
				continue
			}
			if err := e.validateLink(rel, hdr.Linkname); err != nil {
				return nil, err
			}
			if err := e.prepareFile(dest, rel); err != nil {
				return nil, err
			}
			if err := os.Symlink(hdr.Linkname, dest); err != nil {
				return nil, err
			}
			entry := model.File{Path: rel, Type: "symlink", Mode: mode}
			files = append(files, entry)
			if e.opt.OnInstall != nil {
				e.opt.OnInstall(entry)
			}

		case tar.TypeLink:
			target, err := normalize(hdr.Linkname)
			if err != nil {
				return nil, err
			}
			if target == "" {
				return nil, fmt.Errorf("hardlink %s has an empty target", rel)
			}
			if e.skipProtected(rel) {
				e.logf("kept existing protected hardlink %s", rel)
				continue
			}
			links = append(links, hardlink{rel: rel, target: target, mode: mode})

		case tar.TypeChar, tar.TypeBlock, tar.TypeFifo:
			e.logf("skipped special file %s", rel)
		default:
			e.logf("skipped unsupported archive entry %s (type %c)", rel, hdr.Typeflag)
		}
	}

	for _, link := range links {
		dest, err := e.securePath(link.rel)
		if err != nil {
			return nil, err
		}
		src, err := e.securePath(link.target)
		if err != nil {
			return nil, err
		}
		if err := e.prepareFile(dest, link.rel); err != nil {
			return nil, err
		}
		if err := os.Link(src, dest); err != nil {
			if _, statErr := os.Stat(src); statErr == nil {
				in, err := os.Open(src)
				if err != nil {
					return nil, err
				}
				out, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(link.mode)|0o600)
				if err != nil {
					in.Close()
					return nil, err
				}
				_, copyErr := io.Copy(out, in)
				in.Close()
				closeErr := out.Close()
				if copyErr != nil {
					return nil, copyErr
				}
				if closeErr != nil {
					return nil, closeErr
				}
				_ = os.Chmod(dest, os.FileMode(link.mode))
			} else {
				return nil, fmt.Errorf("hardlink %s -> %s: %w", link.rel, link.target, err)
			}
		}
		entry := model.File{Path: link.rel, Type: "hardlink", Mode: link.mode}
		files = append(files, entry)
		if e.opt.OnInstall != nil {
			e.opt.OnInstall(entry)
		}
	}

	return files, nil
}

func (e *Extractor) prepareFile(dest, rel string) error {
	if st, err := os.Lstat(dest); err == nil {
		if st.IsDir() {
			return fmt.Errorf("%s is a directory", rel)
		}
		if e.opt.Backup != nil && st.Mode().IsRegular() {
			if err := e.opt.Backup(rel); err != nil {
				return fmt.Errorf("backup %s: %w", rel, err)
			}
		}
		if err := os.Remove(dest); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	return os.MkdirAll(filepath.Dir(dest), 0o755)
}

func (e *Extractor) skipProtected(rel string) bool {
	if e.opt.AllowProtected {
		return false
	}
	if !protectedPaths[rel] {
		return false
	}
	_, err := os.Lstat(filepath.Join(e.opt.Root, rel))
	return err == nil
}

func (e *Extractor) securePath(rel string) (string, error) {
	root := filepath.Clean(e.opt.Root)
	if root == "" {
		root = "/"
	}
	cur := root
	parts := strings.Split(rel, "/")
	for i, part := range parts {
		cur = filepath.Join(cur, part)
		if i == len(parts)-1 {
			break
		}
		st, err := os.Lstat(cur)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return "", err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("path %s traverses symlink %s", rel, cur)
		}
		if !st.IsDir() {
			return "", fmt.Errorf("path %s traverses non-directory %s", rel, cur)
		}
	}
	if root != "/" {
		if !strings.HasPrefix(cur, root+string(os.PathSeparator)) && cur != root {
			return "", fmt.Errorf("path %s escapes install root", rel)
		}
	}
	return cur, nil
}

func (e *Extractor) validateLink(rel, target string) error {
	if strings.Contains(target, "\x00") {
		return fmt.Errorf("symlink %s has an invalid target", rel)
	}
	if strings.HasPrefix(target, "/") {
		return nil
	}
	joined := filepath.Clean(filepath.Join(filepath.Dir(rel), target))
	if joined == ".." || strings.HasPrefix(joined, "../") {
		return fmt.Errorf("symlink %s -> %s escapes the install root", rel, target)
	}
	return nil
}

func normalize(name string) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	parts := strings.Split(name, "/")
	var out []string
	for _, part := range parts {
		switch part {
		case "", ".":
			continue
		case "..":
			return "", fmt.Errorf("archive entry %q escapes the install root", name)
		default:
			if strings.Contains(part, "\x00") {
				return "", errors.New("archive entry contains a NUL byte")
			}
			out = append(out, part)
		}
	}
	return strings.Join(out, "/"), nil
}

func (e *Extractor) logf(format string, args ...any) {
	if e.opt.Log != nil {
		e.opt.Log(fmt.Sprintf(format, args...))
	}
}
