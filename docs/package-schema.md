# cres package schema (v2)

This document defines the cres package metadata schema. Index version 2 is what
`cres mkindex` writes and what cres treats as the current format.

```
Index file (index.json): {"version": 2, "generated": "...", "packages": [...]}
Local package.json (packages/<name>/package.json): one manifest per package.
Installed DB record: /var/lib/cres/installed/<name>.json
```

## Compatibility rules

| Input | Behavior |
|---|---|
| `index.json` with `"version": 2` (or version ≥ 2) | schema v2, full validation |
| `index.json` with `"version": 1` or `<base>/index.json` flat array (published legacy form) | lenient validation: entries may omit `url` and `checksum`; URLs are re-derived from `<base>/packages/<name>/<filename>` when missing |
| Local `package.json` keys `depends` and `deps` | both accepted; `deps` wins when both present |
| Local `package.json` keys `optdeps` and `optdepends` | both accepted; `optdepends` wins when both present |

Lenient mode exists for browsing the currently published index. It does not
weaken installs: `cres install` fails closed ("index entry carries no valid
sha256 checksum") when the resolved package has no checksum. The published
`https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/cres/index.json`
already carries checksums for all 261 packages.

## Full v2 field table

Required:

| Field | Type | Notes |
|---|---|---|
| `name` | string | `^[a-z0-9][a-z0-9+._-]*$` |
| `version` | string | upstream pkgver, compared component-wise |
| `checksum` | string | 64 hex chars sha256 of the archive file |
| `url` | string | absolute, or resolved against the repo base |

Optional (all may be omitted):

| Field | Type | Notes |
|---|---|---|
| `schema_version` | int | per-manifest marker; must be `2` when present |
| `release` | int | Arch/pkgrel-style build counter; forces upgrade when versions tie |
| `filename` | string | archive file name inside the package directory; base name only |
| `description` | string | |
| `architecture` | string | |
| `os` | string | `silen`, `any`, or empty |
| `size` | int | declared archive size in bytes; cres discards a mismatching download |
| `license`, `category` | string | |
| `maintainer`, `packager` | string | |
| `build_date` | string | RFC3339 |
| `signature` | string | recorded and displayed by `cres info`; advisory until a keyring is published |
| `groups` | []string | e.g. `"base"`, `"desktop"` |
| `system` | bool | system packages install under `/`; everything else is isolated under `/spk_pkgs/<name>` with shims |
| `parts` | int | >1: the URL gains `.000`, `.001` … suffix parts |
| `deps` | []string | runtime dependencies with constraints: `"name"`, `"name>=1.2"`, `"=1.0"`, `>`, `<`, `<=` |
| `optdepends` | []string | `"name"` or `"name>=1.0: reason"` — never resolved, shown by `cres info` |
| `makedepends`, `checkdepends` | []string | build-time deps, constraints allowed, not resolved |
| `provides` | []string | virtual name resolution (`resolve()` follows provides) |
| `conflicts` | []string | blocks installation while listed packages are installed (`--force` to override) |
| `replaces` | []string | removed automatically when their provider installs |
| `backup` | []string | relative paths of dist configs; `cres rm` keeps user-modified copies of these instead of deleting them |
| `hooks` | []hook | see hook trust model |
| `files` | []string | optional index-level file list (informational) |

Placeholder checksums (e.g. 64 identical hex characters) are rejected during
validation, not just format-checked.

## Hooks and the trust model

A v2 manifest may declare up to two kinds of hooks:

```json
"hooks": [
  {"event": "post-install", "run": "usr/lib/cres/hooks/sddm.hook"}
]
```

Rules enforced by cres at install/remove time:

1. `event` must be `post-install` or `post-remove`.
2. `run` must be a relative path under `usr/lib/cres/hooks/` ending in `.hook`.
3. The hook file must be part of the same package's payload (verified against
   the installed file list) and must still exist on disk before it runs.
4. Hooks only run for packages flagged `system: true` (payloads installed under
   `/`). Isolated user packages never execute hooks.
5. `cres install --no-hooks` skips all hook execution (both declared hooks and
   the legacy `usr/lib/cres/postinstall` / `usr/lib/spk/postinstall` scripts).
6. A failed post-install hook rolls back the whole install (journal + file
   removal + backup restore). A failed post-remove hook is reported as a
   warning and removal proceeds.
7. Every hook run happens inside a chroot when `--root` is used.
8. Legacy packages without declared hooks keep the implicit post-install
   script path `usr/lib/cres/postinstall` (then `usr/lib/spk/postinstall`),
   gated by the same payload-membership check.

## Backup tracking

- At install time, every file that cres overwrites is copied into
  `/var/lib/cres/backup/<name>/<path>…` first; a failed install restores it.
- At remove time, files listed in `backup` (plus everything under `etc/` and
  the hard-protected core paths) are kept on disk when the on-dist content
  differs from the package copy: `cres rm` prints `kept modified config`.
  `--force` deletes them anyway.

## Checksum enforcement end to end

- `cres mkindex`: missing checksum/size are computed from the archive on disk.
- `cres install/get`: the download is stored under a cache name keyed by the
  first 12 checksum chars, verified with sha256 before use, and re-verified
  from cache before every install. A failed sha256 or a `size` mismatch aborts.
- The .spk archives themselves are plain tar (zstd/gzip compressed) payloads;
  cres extracts them with path normalization, refuses `..` entries, refuses to
  overwrite protected paths and refuses to traverse symlinks.
