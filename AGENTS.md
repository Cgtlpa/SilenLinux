# AGENTS.md — Silen Linux

## 1. What this distro is

Silen Linux is an independent x86_64 UEFI-only distro. Goal: very user
friendly, just works for everyone.

- Live ISO boots straight into a graphical Wayland session (instantwm,
  no login) with the Rust+egui installer auto-launched.
- No terminal needed for install. Fallback bash/whiptail installer only
  shows if graphics fail.
- Verbose boot by default so failures are visible, not a black screen.

## 2. The 2 ISOs

There are exactly 2 ISOs. Both boot the same instantwm live desktop.
Only difference is the driver payload.

- `make iso` -> `build/silen-linux.iso` — AMD / Intel (open drivers +
  GPU firmware: amdgpu, amd-ucode, intel-ucode, i915, xe, nouveau,
  radeon). NVIDIA blobs excluded on purpose (~200M).
- `make nvidia-iso` -> `build/silen-linux-nvidia.iso` — same + proprietary
  NVIDIA `.run` on ISO, `nvidia-auto` flag, prebuilt kmods
  (`scripts/build-nvidia-kmods.sh`). No on-target compile if prebuilt
  exists.

Builder: `scripts/build.sh` (7 stages). Never split ISO targets.
If you touch live boot, test both variants.

## 3. Repo layout

```text
Makefile                  make iso / nvidia-iso / qemu / clean
scripts/build.sh          ISO builder (modules, ramdisk, live desktop, ISO)
rootfs/init               live init (BusyBox, auto-starts Wayland, no login)
rootfs/bin/busybox        live shell tools
rootfs/lib/modules/       kernel modules source
rootfs/lib/firmware/      firmware source
installer/                bash fallback (main.sh + lib/00-common..90-grub)
silen-installer/          real installer (Rust+egui, port of installer/*.sh)
spk/                      package manager source (Rust, binary name spk)
scripts/mkspk*.sh         package builders (fetch gpkgs, pack .spk)
branding/                 fastfetch logo + info
grub-bundle/              prebuilt GRUB EFI payload
boot/vmlinuz              kernel image for ISO
tarball-silen.xz          base rootfs (gitignored, required for install)
headers-*.tar.zst         kernel headers (gitignored, required for nvidia)
build/                    output (gitignored)
spk-pkgs/                 local package output (gitignored, see section 5)
```

Key files: `rootfs/init`, `installer/main.sh`, `installer/lib/*.sh`,
`silen-installer/src/main.rs`, `silen-installer/src/backend.rs`,
`spk/src/get.rs`, `spk/src/find.rs`, `spk/src/remove.rs`, `spk/src/upd.rs`.

## 4. Build and test

```sh
make iso         # default AMD/Intel ISO
make nvidia-iso  # NVIDIA variant (needs headers-*.tar.zst)
make qemu        # UEFI QEMU smoke test, needs OVMF + qemu-system-x86_64
make clean       # rm -rf build
```

Before building you need in repo root: `boot/vmlinuz`,
`rootfs/lib/modules/<ver>/`, firmware in `rootfs/lib/firmware/`,
`tarball-silen.xz` (or `stage3-*.tar.*`). Without them the ISO boots
but the installer refuses to install.

Useful env overrides (`scripts/build.sh`):

```sh
KERNEL_VERSION=... MODULES_SOURCE=... FIRMWARE_SOURCE=... make iso
COMPRESS=zstd NO_WIFI=1 FULL=0 AUTO_HOST=0 FORCE=1 make iso
```

- `NO_WIFI=1` is default (live ISO has no WiFi, installed system gets it).
- `FULL=1` packs whole module tree instead of allow-list.
- `FORCE=1` skips RAM/disk safety checks.

Live diagnostics on ISO: `silen-wifi-check`, `silen-nvidia-check`.

## 5. Package manager: spk (spark)

`spk` = short for spark. Source in `spk/`, binary `spk` ships on the ISO.

```sh
spk get <pkg...>     # install
spk find <pattern>   # search
spk rm <pkg...>      # remove (never deletes passwd, shadow, fstab, hostname)
spk update [...]     # update all or named pkgs
spk list
spk self-update
```

Rules:

- System packages (kernels, drivers, DEs, DMs, dbus, sddm, plasma,
  gnome, iwd, grub, ...) install to `/`. See `SYSTEM_EXACT` in
  `spk/src/get.rs`.
- Leaf apps install isolated to `/spk_pkgs/<name>` (or
  `~/.local/share/spk` with `--user`) with shims in `/usr/local/bin`.
- Default source is HuggingFace, override per-call with
  `SPK_BASE_URL=...`.

## 6. Packages: binaries only + HuggingFace

- This repo contains only binary packages (`.spk` = tar.gz payload +
  `package.json` with filename, parts, sha256, version, category).
  No source builds in the package repo.
- Local staging dir `spk-pkgs/` is gitignored. Real package repo lives on
  HuggingFace: dataset `vgzz/spk-pkgs`, folder `packages/`.
  `spk` fetches from
  `https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages`.
- The owner is already logged in via `hf` CLI (`hf --version` works).
  If a fix needs a new/updated package, build it with
  `scripts/mkspk*.sh` and upload it with `hf`. Example shape:

```sh
hf upload vgzz/spk-pkgs spk-pkgs/packages/<name> packages/<name> --repo-type dataset
```

  Always verify checksum + `package.json` fields match the uploaded file.
  Never guess HF URLs, read `spk/src/get.rs` or fetch the live
  `index.json` / `package.json` first.

## 7. Code style: keep it simple

Write like the existing code. Short, plain, no clever tricks.

- Bash: `set -e`, `set -o pipefail`, small funcs, plain `echo` messages.
- Rust: plain `match`/`if`, no heavy abstractions, same layout as
  `spk/src/get.rs` and `silen-installer/src/backend.rs`.
- Follow the file you edit. Match indentation and naming.

## 8. Comments: few and short

Do not overuse comments. Only important parts.

- One short line max, plain words.
- Good: `# live desktop, no login`, `# libs load in order, dont reshuffle`.
- Bad: long paragraphs, obvious code restated, TODO essays.

## 9. Debug marks

When debugging code, add a short debug mark so it is clear what was
fixed.

- Bash: `# DEBUG: fixed <what>`
- Rust: `// DEBUG: fixed <what>`

Example:

```sh
# DEBUG: fixed nvme p1/p2 naming on GPT layout
```

Keep the mark next to the fix. Remove noisy `echo`/`println` debug
prints before finishing unless the user wants them.

## 10. Permissions

- Major changes (new deps, new ISO layout, installer flow change,
  partition scheme, init system, spk install locations, HF repo layout):
  ask the user first and wait for yes.
- If the user just asks to fix a bug: fix it, do not redesign. Keep the
  diff small, keep style simple, add the DEBUG mark from section 9.

## 11. Agent workflow

- Read the file before editing it. Check all candidate areas named in
  the issue (installer lib, backend.rs, build.sh, spk src).
- Prefer editing existing files over creating new ones.
- Verify by running what you can: `cargo test` / `cargo build` in
  `spk/` or `silen-installer/`, `bash -n` for shell, `make qemu`
  for ISO smoke test.
- If findings contradict earlier claims, say so and trust the file
  contents.
