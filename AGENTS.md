# AGENTS.md — Silen Linux contributor guide for AI agents

This file is for AI coding agents working in this repo. `README.md` is for users; this file is for you. Follow it so you don't break the ISO build, live boot, or installer.

## 1. What this distro is

- **Silen Linux**: independent, lightweight x86_64 distro. Minimal live ISO → clean installed system.
- **Kernel target: Linux 6.18.** Kernel image lives at `boot/vmlinuz` (6.18.54-silen, vanilla kernel.org longterm + `-silen` localversion). Module tree lives at `rootfs/lib/modules/<ver>/` (currently `6.18.54-silen`, ~6800 modules built from a full Ubuntu-config base so every driver family is `=m`).
  - Do NOT hardcode the version. Use `KERNEL_VERSION` env / auto-detect logic in `scripts/build.sh:7`.
  - If you bump the kernel, update `boot/vmlinuz`, `rootfs/lib/modules/`, `branding/info.txt`, and the `DEFAULT_KVER` fallback in `scripts/build.sh:13`.
- **Init**: OpenRC on the installed system (`rc-update`, `elogind`). Live ISO uses a custom BusyBox `/init` (`rootfs/init`), NOT systemd.
- **Bootloader**: GRUB2, UEFI-only. ISO assembled with `grub-mkrescue`. EFI payload shipped in `grub-bundle/`.
- **Base system**: `tarball-silen.xz` or `stage3-*.tar.*` in repo root, extracted by the installer. ISO boots without it but the installer will refuse to install.
- **Package manager**: `spk`, Rust binary in `spk/` (`spk/src/get.rs` = `spk get`, `find.rs` = `spk find`, `remove.rs` = `spk rm`).
- **License**: AGPLv3 (`LICENSE`).

## 2. Repo map — read this before editing

```text
Makefile                      make iso | make qemu | make clean
scripts/build.sh              THE iso builder. 7 stages. Edit carefully.
scripts/add-wifi.sh           Syncs wifi modules+firmware from host into rootfs/. Run before make iso when adding drivers.
scripts/make-grub-bundle.sh  Packages compiled GRUB (GRUB_SRC=~/grub) into grub-bundle/. Needed for EFI install.
scripts/wifi-check.sh         Live diagnostics → installed as /usr/bin/silen-wifi-check.
scripts/mkspk-*.sh            Build spk package payloads from Gentoo gpkg / Arch binaries (xorg, wayland, sddm).
boot/vmlinuz                  Kernel image shipped on ISO.
rootfs/init                   Live init (sh). Mounts medium, starts NM/dbus, launches installer, falls back to shell.
rootfs/bin/busybox            Static busybox + applet symlinks created at build time.
rootfs/lib/modules/<ver>/     Kernel modules source for initramfs + kernel bundle.
rootfs/lib/firmware/          Firmware source (mostly wifi; GPU merged from host at build time).
installer/main.sh             Loader: sources installer/lib/ in order, runs the offline flow.
installer/lib/                Modular installer, sourced in order:
  00-common.sh  cleanup + traps
  10-medium.sh  find/scan install medium, Ventoy ISO loop-mount support
  20-ui.sh      offline menu (Install/Shell/Reboot)
  30-partition.sh  GPT: ESP 1MiB-1GiB fat32 + root (ext4/btrfs/fat32). Handles nvme/mmcblk pN naming.
  40-base.sh    mount target, extract tarball
  50-settings.sh hostname/root/user/fstype/locale/keymap/timezone/swapfile
  60-system.sh  permissions, elogind, quiet OpenRC, motd, silenfetch alias
  70-payloads.sh kernel+firmware+network bundles, spk binary, OpenRC services (dbus/iwd)
  90-grub.sh    copy kernel/initramfs, EFI grub-install. Refuses legacy boot.
spk/                          Cargo project. [[bin]] spk path = src/get.rs. Deps: flate2, sha2, tar, ureq.
spk/src/get.rs                SYSTEM_EXACT list + looks_like_system_package() decides / vs /spk_pkgs/<name>.
grub-bundle/usr/local/        Prebuilt GRUB EFI. Copy of `make install DESTDIR` output.
branding/                     fastfetch_logo.txt + info.txt (name/version/kernel).
```

## 3. Build / test commands

```sh
make iso    # sudo nice -n 10 ionice -c 3 ./scripts/build.sh — full ISO to build/silen-linux.iso
make nvidia-iso  # NVIDIA=1 variant to build/silen-linux-nvidia.iso (needs headers-*.tar.zst, auto-installs driver)
make qemu   # boot ISO in UEFI QEMU (4G, q35, 8G build/disk.img). Needs qemu-system-x86_64 + OVMF.
make clean  # rm -rf build /tmp/OVMF_VARS.fd

# Direct script knobs (see scripts/build.sh:21):
COMPRESS=zstd make iso          # zstd (default) | gzip | xz
FULL=1 make iso                 # pack full module tree instead of ALLOW allow-list
AUTO_HOST=1 make iso            # + currently loaded host modules
FORCE=1 make iso                # bypass 2G RAM / disk checks
KERNEL_VERSION=6.18.0-silen KERNEL_SOURCE=/path/vmlinuz MODULES_SOURCE=/path/modules make iso

./scripts/add-wifi.sh           # optional KVER=... override
./scripts/make-grub-bundle.sh   # optional GRUB_SRC=... override
cargo check --manifest-path spk/Cargo.toml
cargo clippy --manifest-path spk/Cargo.toml
bash -n <edited .sh>            # always syntax-check shell edits
```

- `build/` is often root-owned (script uses sudo). If `rm -rf build` fails, use `sudo rm -rf build` — the script itself tells you this (`scripts/build.sh:168`).
- Missing host deps produce explicit errors: `grub-mkrescue`, `cpio`, `zstd`, `depmod`, `ldconfig`, `strip`, `ldd`, `cargo`. Install them, don't stub around them.

## 4. Boot + install flow (don't break this chain)

1. GRUB (`build/iso/boot/grub/grub.cfg` generated at `scripts/build.sh:1011`): two entries — `Silen Linux` (`loglevel=4 console=tty0`) and fallback (`nomodeset`). Keep both.
2. Kernel 6.18 + `initramfs.zst` → `rootfs/init`:
   - mounts proc/sys/dev, loads `/etc/modules` via modprobe,
   - honors `root=` cmdline for switch_root, else live mode,
   - starts `dbus-daemon --system`, `iwd`, unblocks rfkill,
   - scans block devices for tarball, loop-mounts `*silen*.iso` for Ventoy,
   - execs `/installer/main.sh`, else drops to `sh` loop.
3. Installer writes GPT (ESP + root: ext4/btrfs/vfat) → extracts tarball → unpacks `kernel-*.tar.zst` + `/mnt/firmware` + `network.tar.zst` + `spk` → GRUB EFI.

## 5. Hardware / firmware policy (common breakage area)

- Initramfs module allow-lists: `ALLOW` (storage/net/fs, `scripts/build.sh:32`) + `ALLOW_WIFI` (`scripts/build.sh:44`). Deps resolved via `modinfo -F depends`. `FULL=1` bypasses the list.
- `BLACKLIST` (`scripts/build.sh:87`): `nvidia*`, `zfs*`, `splat`, `icp` — never pack these into the initramfs.
- Firmware: per-module `modinfo -F firmware` + explicit per-driver globs (`scripts/build.sh:652`), then full `rootfs/lib/firmware` copy, then GPU merge (`amdgpu amd-ucode intel-ucode i915 xe nouveau radeon`, `scripts/build.sh:739`).
- **Do NOT add `nvidia` firmware blobs.** ~200M, proprietary-driver-only, pushes ISO over 1.5GB. Fetch `nvidia-drivers` via `spk` after reboot instead.
- **Black-screen fix (2026-09-21)**: live + ISO must carry GPU firmware or amdgpu/i915 won't modeset after GRUB. If you touch firmware logic, keep the GPU merge in both the initramfs AND the ISO `firmware/` dir.
- GRUB console fallback is intentional: `terminal_output gfxterm console`, verbose default, and NO `set gfxpayload` line (`text` is invalid on UEFI, LP#1711452). Don't "simplify" this.

## 6. `spk` rules

- `is_system_package()` in `spk/src/get.rs:80`: `manifest_flag=true` OR name-heuristic match → install to `/`. Everything else → isolated `/spk_pkgs/<name>` (or `~/.local/share/spk/apps/<name>` with `--user`) + shims in `/usr/local/bin`.
- DMs/DEs/kernels/firmware/drivers/network/audio/login MUST be system. If you add a package name in that class, add it to `SYSTEM_EXACT` or its prefix will miss and the DM/DE will install isolated and never start (see `SYSTEM-SORT` comments in `get.rs`).
- `remove.rs`: never delete protected configs (`/etc/passwd shadow gshadow group fstab machine-id hostname hosts resolv.conf`). Basename check is scoped to `/etc/` only — don't widen it or `/usr/bin/passwd` will survive `spk rm`.
- `cxx-libs` ships GCC 16 libstdc++ as `/usr/lib/silen/cxx/gcc16-libstdc++.*`; its postinstall copies it into `/usr/lib64` and the GCC 15 directory. `spk` skips payload files named `libstdc++*` as protected core libs, so direct payload paths would be ignored.
- Default repo URL is hardcoded (`DEFAULT_BASE`, `spk/src/get.rs:15`). GitHub `Cgtlpa/spk_pkgs` remains a backup mirror.

## 7. Shell style in this repo

- `scripts/build.sh` + `installer/lib/*`: `bash`, `set -e` (builder also `set -E -o pipefail` + ERR trap). `rootfs/init`: `sh` (POSIX — no bashisms, no arrays).
- Error handling pattern: `|| { echo "  ERROR <what> (how to fix)"; exit 1; }`. Keep messages actionable; installer uses `whiptail --msgbox` for user-visible failures.
- Heredocs for `grub.cfg`: quoted vs unquoted `EOF` matters (backticks broke unquoted expansion before — see git log `2c25fed`). If you touch grub.cfg generation, test the output file.
- `copy_libs()` / `copy_app()` in `build.sh:342` resolve `ldd` deps into the ramroot + `ldconfig -r`. NSS (`libnss_dns/files`) is dlopen'd, never in `ldd` — it's copied manually. Don't remove that or live DNS dies.
- No static `/etc/machine-id` in ramroot — live init runs `dbus-uuidgen --ensure` each boot so clones get unique IDs.

## 8. Before you finish

1. `bash -n` every edited shell file; `cargo check` (and `clippy` if touched) for `spk/`.
2. If you changed `scripts/build.sh`, `rootfs/init`, `installer/lib/*`, or `spk/`: state in your summary whether you ran `make iso` / `make qemu` or not, and why.
3. Don't commit `build/`, `spk/target/`, `tarball-silen.xz`, or `*.iso` (see `.gitignore`).
4. Keep `README.md` (users) and this file (agents) in sync on: kernel version, init system, build commands, installer modes.

## 9. Agent working rules (binding)

- Match the surrounding code style exactly: `bash` + `set -e` + `[[ ]]` + tabs in `scripts/` and `installer/`; POSIX `sh` (no bashisms) in `rootfs/init`. Never reformat unrelated lines.
- No new code comments. When auditing or debugging, mark verified sections with the existing `DEBUG-MARK:` tag style (see `spk/src/get.rs`) so proven-correct code is not re-debugged — markers only, no explanations.
- This file is binding: follow every section on every task.
- No major changes without the user's explicit consent: new dependencies, layout/format changes, kernel bumps, installer flow changes, repo-hosting moves. Small fixes go ahead; anything structural gets asked first.
