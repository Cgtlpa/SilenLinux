# AGENTS.md — Silen Linux contributor guide for AI agents

This file is for AI coding agents working in this repo. `README.md` is for users; this file is for you. Follow it so you don't break the ISO build, live boot, or installer.

## 1. What this distro is

- **Silen Linux**: independent, lightweight x86_64 distro. Minimal live ISO → clean installed system.
- **Kernel target: Linux 6.18.** Kernel image lives at `boot/vmlinuz` (6.18.54-silen, vanilla kernel.org longterm + `-silen` localversion). Module tree lives at `rootfs/lib/modules/<ver>/` (currently `6.18.54-silen`, ~6800 modules built from a full Ubuntu-config base so every driver family is `=m`).
  - Do NOT hardcode the version. Use `KERNEL_VERSION` env / auto-detect logic in `scripts/build.sh:7`.
  - If you bump the kernel, update `boot/vmlinuz`, `rootfs/lib/modules/`, `branding/info.txt`, and the `DEFAULT_KVER` fallback in `scripts/build.sh:13`.
- **Init**: OpenRC on the installed system (`rc-update`, `elogind`). Live ISO uses a custom BusyBox `/init` (`rootfs/init`), NOT systemd.
- **Bootloader**: GRUB2, UEFI-only. ISO assembled with `grub-mkrescue`. EFI payload shipped in `grub-bundle/`.
- **Base system**: `tarball-silen.xz` or `stage3-*.tar.*` in repo root, extracted by the installer. ISO boots without it but the installer will refuse to install. The shipped tarball is a stripped Gentoo base: no portage tree, no portage/gnupg keys, no gcc or build toolchain.
- **Package manager**: `cres`, Go binary in `cres/` (`cres/main.go`, `cres/internal/cli/cli.go`). `cres install/remove/update/search/list/info`. `cres` is built into the ISO.
- **Desktop**: InstantWM is the default Wayland compositor on the live ISO and installed system. Rofi (`mod4+Space`) is the application launcher; Kitty (`mod4+Return`) is the default terminal. InstantMenu (`mod4+E`) remains available.
- **Wi-Fi**: iwd is the only Wi-Fi backend (no NetworkManager). `iwctl`/`iwmon` on D-Bus.
- **TTY**: `agetty` runs on tty2-tty6 in both live and installed systems. Ctrl+Alt+F2..F6 switch to text consoles.
- **License**: AGPLv3 (`LICENSE`).

## 2. Repo map — read this before editing

```text
Makefile                      make iso | make qemu | make clean
scripts/build.sh              THE iso builder. 7 stages. Edit carefully.
scripts/add-wifi.sh           Syncs wifi modules+firmware from host into rootfs/. Run before make iso when adding drivers.
scripts/make-grub-bundle.sh  Packages compiled GRUB (GRUB_SRC=~/grub) into grub-bundle/. Needed for EFI install.
scripts/wifi-check.sh         Live diagnostics → installed as /usr/bin/silen-wifi-check.
scripts/mkspk-*.sh            Build spk package payloads from Gentoo gpkg / Arch binaries (xorg, wayland, sddm).
scripts/mkspk-audio.sh        Builds full pipewire/wireplumber/lua-libs/libasyncns/libpulse + silen-audio packages and patches mango/niri session launchers.
scripts/build-nvidia-kmods.sh Build NVIDIA driver kernel modules for nvidia-iso variant.
boot/vmlinuz                  Kernel image shipped on ISO.
rootfs/init                   Live init (sh). Mounts medium, starts dbus/iwd/seatd, launches InstantWM desktop, falls back to shell. Starts agetty on tty2-tty6.
rootfs/bin/busybox            Static busybox + applet symlinks created at build time.
rootfs/lib/modules/<ver>/     Kernel modules source for initramfs + kernel bundle.
rootfs/lib/firmware/          Firmware source (mostly wifi; GPU merged from host into the ISO firmware/ dir at build time).
installer/main.sh             Loader: sources installer/lib/ in order, runs the offline flow.
installer/lib/                Modular installer, sourced in order:
  00-common.sh  cleanup + traps
  10-medium.sh  find/scan install medium, Ventoy ISO loop-mount support
  20-ui.sh      offline menu (Install/Shell/Reboot)
  30-partition.sh  GPT: ESP 1MiB-1GiB fat32 + root (ext4/btrfs), min 8 GiB disk. Handles nvme/mmcblk pN naming.
  40-base.sh    mount target, extract tarball
  50-settings.sh hostname/root/user/fstype/locale/keymap/timezone/swapfile
  60-system.sh  permissions, elogind, quiet OpenRC, motd, silenfetch alias
  70-payloads.sh kernel+firmware+network bundles, spk binary, OpenRC services (dbus/iwd/agetty on tty2-tty6)
  75-extras.sh  busybox logs/ntpd/bootlogd/fstrim/microcode/resume, builds initramfs-silen.img
  90-grub.sh    copy kernel, use initramfs-silen.img (fallback live), EFI grub-install. Refuses legacy boot.
target-scripts/               Copied to installed /usr/local/bin (silen-mkinitramfs, silen-setup). silen-mkinitramfs decompresses .ko.zst modules on purpose: busybox modprobe cannot read compressed modules.
spk/                          Rust package manager source (kept in repo, not built or shipped - use cres instead)
cres/                         Go package manager (cres/main.go, cres/internal/cli/cli.go). Built into ISO.
grub-bundle/usr/local/        Prebuilt GRUB EFI. Copy of `make install DESTDIR` output.
branding/                     fastfetch_logo.txt + info.txt (name/version/kernel).
```

## 3. Build / test commands

```sh
make iso    # sudo nice -n 10 ionice -c 3 ./scripts/build.sh — full ISO to build/silen-linux.iso
make nvidia-iso  # NVIDIA=1 variant to build/silen-linux-nvidia.iso (needs headers-*.tar.zst, auto-installs driver)
make qemu   # boot ISO in UEFI QEMU (4G, q35, 8G build/disk.img). Needs qemu-system-x86_64 + OVMF.
make clean  # rm -rf build /tmp/OVMF_VARS.fd

# Direct script knobs (see scripts/build.sh:29):
COMPRESS=zstd make iso          # zstd (default) | gzip | xz
FULL=1 make iso                 # pack full module tree instead of ALLOW allow-list
AUTO_HOST=1 make iso            # + currently loaded host modules
FORCE=1 make iso                # bypass 2G RAM / disk checks
KERNEL_VERSION=6.18.54-silen KERNEL_SOURCE=/path/vmlinuz MODULES_SOURCE=/path/modules make iso

./scripts/add-wifi.sh           # optional KVER=... override
./scripts/make-grub-bundle.sh   # optional GRUB_SRC=... override
./scripts/mkspk-audio.sh all    # rebuild audio packages + patch mango/niri; upload package dirs and packages/index.json to HF, no ISO rebuild needed
cd cres && go build -o /tmp/cres .  # build cres package manager
cargo test --manifest-path silen-installer/Cargo.toml   # installer unit tests
cargo build --release --manifest-path silen-installer/Cargo.toml
bash -n <edited .sh>            # always syntax-check shell edits
```

- `build/` is often root-owned (script uses sudo). If `rm -rf build` fails, use `sudo rm -rf build` — the script itself tells you this (`scripts/build.sh:6`).
- Missing host deps produce explicit errors: `grub-mkrescue`, `cpio`, `zstd`, `depmod`, `ldconfig`, `strip`, `ldd`, `cargo`. Install them, don't stub around them.

## 4. Boot + install flow (don't break this chain)

1. GRUB (`build/iso/boot/grub/grub.cfg` generated at `scripts/build.sh:1118`): entries — `Silen Linux` (`loglevel=4 console=ttyS0 console=tty0` + `nvidia-drm.modeset=1` on NVIDIA ISO), fallback (`nomodeset`), text installer (`silen.text`). Keep all.
2. Kernel 6.18 + `initramfs.zst` → `rootfs/init`:
   - mounts proc/sys/dev, loads `/etc/modules` via modprobe,
   - starts `dbus-daemon --system`, `iwd` (with `rfkill unblock all`), seatd,
   - scans block devices for tarball, loop-mounts `*silen*.iso` for Ventoy,
   - starts `agetty` on tty2-tty6,
   - execs `/installer/main.sh` (or InstantWM desktop), else drops to `sh` loop.
3. Installer writes GPT (ESP + root: ext4/btrfs) → extracts tarball → unpacks `kernel-*.tar.zst` + `/mnt/firmware` + `network.tar.zst` + `spk` → builds `initramfs-silen.img` with `silen-mkinitramfs` → GRUB EFI.

## 5. Hardware / firmware policy (common breakage area)

- Initramfs module allow-lists: `ALLOW` (storage/net/fs, `scripts/build.sh:37`) + `ALLOW_WIFI` (`scripts/build.sh:50`). Deps resolved via `modinfo -F depends`. `FULL=1` bypasses the list.
- `BLACKLIST` (`scripts/build.sh:93`): `nvidia*`, `zfs*`, `splat`, `icp` — never pack these into the initramfs **except** when `NVIDIA=1`, where `nvidia` modules are intentionally un-blacklisted so they can load after driver installation.
- `nouveau` is added to `ALLOW` when `NVIDIA=1` so the live environment has an open-source NVIDIA driver with KMS (`nvidia-drm.modeset=1` on GRUB cmdline).
- Firmware: per-module `modinfo -F firmware` + explicit per-driver globs (`scripts/build.sh:675`), then full `rootfs/lib/firmware` copy into the live initramfs. GPU firmware (`amdgpu amd-ucode intel-ucode i915 xe nouveau radeon`) is merged into the ISO `firmware/` dir only (`scripts/build.sh`); the installer copies that dir to target `/lib/firmware`.
- **Do NOT add `nvidia` firmware blobs.** ~200M, proprietary-driver-only, pushes ISO over 1.5GB. Use `make nvidia-iso` (prebuilt kmods) — the normal base has no compiler, so on-target `spk get nvidia-drivers` builds are unsupported.
- **Black-screen fix (2026-09-21)**: keep the GPU firmware merge in the ISO `firmware/` dir (offline installs copy it to target). The live initramfs packs no GPU modules, so GPU/ucode firmware was removed from it (2026-10-19, ~60MB saved); don't re-add it unless GPU modules are added to the initramfs.
- GRUB console fallback is intentional: `terminal_output gfxterm console`, verbose default, and NO `set gfxpayload` line (`text` is invalid on UEFI, LP#1711452). Don't "simplify" this.

## 6. `cres` rules

- `cres` is a Go package manager (`cres/main.go`, `cres/internal/cli/cli.go`). `cres install/remove/update/search/list/info`.
- DMs/DEs/kernels/firmware/drivers/network/audio/login MUST be system packages. If you add a package name in that class, ensure it installs to `/` not isolated.
- Audio packages (`pipewire`, `wireplumber`, `lua-libs`, `libpulse`, `libasyncns`, `silen-audio`) are system packages. `mango` and `niri` depend on `silen-audio` and launch `/usr/local/bin/silen-audio-run` from their session desktop files. Keep the full PipeWire payload (SPA plugins, modules, ALSA config); do not shrink it back to only `bin/` and `libpipewire*`.
- `cres remove`: never delete protected configs (`/etc/passwd shadow gshadow group fstab machine-id hostname hosts resolv.conf`) or boot files (`/boot/vmlinuz*`, `/boot/initramuz*`, `/boot/silen-ucode*`, `/boot/grub/**`, `/boot/EFI/**`).
- After installing a payload containing `/boot/vmlinuz`, `cres` runs `/usr/bin/silen-mkinitramfs` (or `/usr/local/bin/...`) so kernel updates regenerate the boot image.
- `cxx-libs` ships GCC 16 libstdc++ as `/usr/lib/silen/cxx/gcc16-libstdc++.`; its postinstall copies it into `/usr/lib64` and the GCC 15 directory. `cres` skips payload files named `libstdc++*` as protected core libs, so direct payload paths would be ignored.
- Default repo URL is hardcoded in `cres/internal/cli/cli.go` (`repository.DefaultBase`).

## 7. Shell style in this repo

- `scripts/build.sh` + `installer/lib/*`: `bash`, `set -e` (builder also `set -E -o pipefail` + ERR trap). `rootfs/init`: `sh` (POSIX — no bashisms, no arrays).
- Error handling pattern: `|| { echo "  ERROR <what> (how to fix)"; exit 1; }`. Keep messages actionable; installer uses `whiptail --msgbox` for user-visible failures.
- Heredocs for `grub.cfg`: quoted vs unquoted `EOF` matters (backticks broke unquoted expansion before — see git log `2c25fed`). If you touch grub.cfg generation, test the output file.
- `copy_libs()` / `copy_app()` in `build.sh:368` resolve `ldd` deps into the ramroot + `ldconfig -r`. NSS (`libnss_dns/files`) is dlopen'd, never in `ldd` — it's copied manually. Don't remove that or live DNS dies.
- No static `/etc/machine-id` in ramroot — live init runs `dbus-uuidgen --ensure` each boot so clones get unique IDs.
- `build.sh` builds `cres` with `go build`. If you change `cres/`, refresh dependencies or the ISO build fails.
- `silen-installer` is a separate Cargo project (`silen-installer/Cargo.toml`). Build with `cargo build --release --manifest-path silen-installer/Cargo.toml`. Test with `cargo test --manifest-path silen-installer/Cargo.toml`.

## 8. Before you finish

1. `bash -n` every edited shell file; `go build ./...` for `cres/`; `cargo test` for `silen-installer/`.
2. If you changed `scripts/build.sh`, `rootfs/init`, `installer/lib/*`, `cres/`, or `silen-installer/`: state in your summary whether you ran `make iso` / `make qemu` or not, and why.
3. Don't commit `build/`, `spk/target/`, `silen-installer/target/`, `tarball-silen.xz`, or `*.iso` (see `.gitignore`).
4. Keep `README.md` (users) and this file (agents) in sync on: kernel version, init system, build commands, installer modes, desktop apps (InstantWM/Rofi/Kitty), Wi-Fi backend (iwd), TTY config.

## 9. Agent working rules (binding)

- Match the surrounding code style exactly: `bash` + `set -e` + `[[ ]]` + tabs in `scripts/` and `installer/`; POSIX `sh` (no bashisms) in `rootfs/init`. Never reformat unrelated lines.
- No new code comments. When auditing or debugging, mark verified sections with the existing `DEBUG-MARK:` tag style (see `spk/src/get.rs`) so proven-correct code is not re-debugged — markers only, no explanations.
- This file is binding: follow every section on every task.
- No major changes without the user's explicit consent: new dependencies, layout/format changes, kernel bumps, installer flow changes, repo-hosting moves. Small fixes go ahead; anything structural gets asked first.