# Silen Linux

> Reliable by default. Powerful when you want it.

Silen Linux is an independent, lightweight Linux distribution focused on simplicity, stability, and performance. It boots as a minimal live environment and installs a clean base system you build on top of — no bloat, no forced desktop, full control.

---

## At a glance

| Component | What Silen uses |
|---|---|
| Kernel | Linux 6.18 (`boot/vmlinuz` + `rootfs/lib/modules/`) |
| Init (installed system) | OpenRC (`rc-update`, `installer/lib/70-payloads.sh:404`) |
| Live init | Custom BusyBox-based initramfs, `/init` from `rootfs/init` |
| Arch | x86_64, UEFI only (installer refuses legacy boot, `installer/lib/90-grub.sh`) |
| Bootloader | GRUB2 via `grub-mkrescue`, EFI bundle from `grub-bundle/` |
| Base system | `tarball-silen.xz` / `stage3-*.tar.*` unpacked onto target |
| Package manager | `spk` — Rust tool in `spk/src/get.rs`, built into the ISO |
| Live networking | iwd + `iwctl`/`iwmon` + D-Bus |
| Filesystems (live + install) | ext4, btrfs, xfs, vfat, exfat, ntfs3, squashfs, isofs, fuse |
| License | AGPLv3 (`LICENSE`) |

---

## Features

- **Independent distro** — own ISO builder (`scripts/build.sh`), init (`rootfs/init:1`), installer (`installer/`), and package manager (`spk/`).
- **Linux 6.18 kernel** — ships as `boot/vmlinuz` on the ISO plus a `kernel-$KVER.tar.zst` bundle that gets unpacked into the installed system (`scripts/build.sh:847`).
- **Minimal live RAM root** — BusyBox + bash, `whiptail`, `git`, `curl`, `zstd`, `tar`, `sfdisk`, `blkid`, `mkfs.ext4/vfat`, iwd stack, CA certs, terminfo — assembled in `scripts/build.sh:279`.
- **Broad hardware support out of the box:**
  - Storage: AHCI, NVMe, virtio-blk/scsi, MMC/SDHCI, USB-storage/UAS (`scripts/build.sh:32`).
  - Wired + USB tethering: `e1000/e1000e`, `r8169`, `igb`, `ixgbe`, `r8152`, `alx`, `cdc_ether`, `rndis_host` (`scripts/build.sh:37`).
  - Wi-Fi: Intel `iwlwifi`, Atheros `ath9k/ath10k/ath11k/ath12k`, MediaTek `mt76/mt79xx`, Realtek `rtw88/rtw89/rtlwifi/rtl8xxxu`, Broadcom `brcmfmac/b43`, Marvell, Ralink, TI, etc. (`scripts/build.sh:44`, `scripts/add-wifi.sh:38`).
  - GPU firmware merged for live + offline installs: `amdgpu`, `amd-ucode`, `intel-ucode`, `i915`, `xe`, `nouveau`, `radeon` (`scripts/build.sh:739`). NVIDIA blobs are intentionally excluded (~200M) — install later via `spk get nvidia-drivers` after reboot.
- **Offline installer** — whiptail TUI (`installer/lib/20-ui.sh:1`): base system only, no network needed. Filesystem choice (ext4/btrfs/vfat), 15 timezones, 15 keymaps, hostname defaults to `silen`.
- **`spk` package manager** — `spk get / find / rm` (`spk/src/get.rs:1`, `spk/src/find.rs:1`, `spk/src/remove.rs:1`). System packages (kernels, drivers, DEs, DMs) install to `/`; leaf apps go isolated to `/spk_pkgs/<name>` with shims in `/usr/local/bin`.
- **Post-install via `spk`** (after reboot, with network): `spk get linux-firmware`, Wi-Fi drivers, GPU drivers, desktops (KDE Plasma, GNOME, XFCE, i3, Sway) + DMs (SDDM/GDM/LightDM).
- **Diagnostics built in** — `silen-wifi-check` (from `scripts/wifi-check.sh`) dumps `lsmod`, `ip link`, `rfkill`, `lspci/lsusb`, `dmesg`, `iwctl`, `iwd`, D-Bus helper status to `/tmp/silen-wifi.log`.

---

## Live ISO layout

Built by `scripts/build.sh` into `build/silen-linux.iso` via `grub-mkrescue`:

```text
/boot/vmlinuz              kernel (Linux 6.18)
/boot/initramfs.zst        compressed cpio ramdisk (zstd default, gzip/xz optional)
/boot/grub/grub.cfg        "Silen Linux" + "Silen Linux (fallback, nomodeset)"
/kernel-*.tar.zst          kernel + full module tree for the installed system
/network.tar.zst           iwd/iwctl/iwmon/dbus bundle
/firmware/                 Wi-Fi + GPU firmware copied to target on offline installs
/spk                       prebuilt spk binary (also re-packed into the initramfs at scripts/build.sh:931)
/grub/usr/local/           GRUB EFI bundle (see scripts/make-grub-bundle.sh:1)
/branding/                 fastfetch logo + info (branding/fastfetch_logo.txt:1)
stage3-*.tar.* / tarball-silen.xz   base rootfs the installer extracts
```

GRUB menu is verbose by default (`loglevel=4 console=tty0`, `terminal_output gfxterm console`) so boot failures are visible instead of a black screen (`scripts/build.sh:1027`).

---

## Installer

Entry: `/installer/main.sh` in the live env (started by `rootfs/init:354`). Modular libs in `installer/lib/`:

- `10-medium.sh` — finds the install medium / tarball, handles Ventoy ISO-file boot + loop-mount.
- `20-ui.sh` — offline menu (Install/Shell/Reboot).
- `30-partition.sh` — disk pick, wipe confirm, GPT layout: 1MiB–513MiB ESP (`fat32`, `esp on`) + root to 100%. Handles `nvme/mmcblk` `p1/p2` naming.
- `40-base.sh` — mounts target, extracts tarball (strips single top-level dir).
- `50-settings.sh` — hostname, root password, optional user, locale/keymap/timezone, swapfile.
- `60-system.sh` — suid/permissions fix, `elogind`, quiet OpenRC, motd, `silenfetch` (`fastfetch -l ~/.ascii` with `branding/fastfetch_logo.txt`).
- `70-payloads.sh` — installs kernel bundle, firmware, network bundle, `spk` binary, writes OpenRC services for `dbus`/`iwd`.
- Extra drivers, firmware, and desktops are installed after reboot via `spk` (needs network).
- `90-grub.sh` — copies kernel/initramfs to target, requires UEFI (`/sys/firmware/efi`), installs GRUB from `/mnt/grub`.

Root filesystems offered: BTRFS, ext4, FAT32 (whiptail menu).

---

## `spk` package manager

Source: `spk/` (`spk/Cargo.toml:1`, `spk/Makefile:1`).

```sh
spk get <pkg...>     # install (e.g. spk get linux-firmware, spk get plasma-desktop)
spk find <pattern>   # search installed registry
spk rm <pkg...>      # remove (never deletes /etc/passwd, shadow, fstab, hostname, ...)
```

- System packages land in `/` (drivers, firmware, DEs, DMs — see `SYSTEM_EXACT` in `spk/src/get.rs:28`).
- Leaf apps land isolated with shims, per-user with `--user`.
- Default package source: `https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages` (`spk/src/get.rs:15`). Override per-call with `SPK_BASE_URL=...`.

---

## Building

### Requirements (host)

`grub-mkrescue` (`grub`, `xorriso`, `mtools`, `dosfstools`), `cpio`, `zstd`/`gzip`/`xz`, `tar`, `modinfo`, `depmod`, `ldconfig`, `strip`, `cargo` (for `spk`), OVMF firmware for QEMU. The script tells you exactly what's missing (`scripts/build.sh:151`, `scripts/build.sh:799`).

### Commands

```sh
make iso    # sudo nice -n 10 ionice -c 3 ./scripts/build.sh  (Makefile:9)
make qemu   # boot build/silen-linux.iso in UEFI QEMU (4G RAM, q35, 8G disk.img)
make clean  # rm -rf build
```

Place your kernel at `boot/vmlinuz`, modules at `rootfs/lib/modules/<ver>/`, firmware at `rootfs/lib/firmware/`, and `tarball-silen.xz` (or `stage3-*.tar.*`) in the repo root before building — otherwise the ISO boots but the installer refuses to install (`scripts/build.sh:889`).

### Useful env overrides (`scripts/build.sh:13`)

| Var | Default | Meaning |
|---|---|---|
| `KERNEL_VERSION` | auto from `rootfs/lib/modules/*` | module dir / depmod version |
| `KERNEL_SOURCE` | `boot/vmlinuz` | kernel image to ship |
| `MODULES_SOURCE` | `rootfs/lib/modules/$KERNEL_VERSION` | falls back to host `/usr/lib/modules/$(uname -r)` |
| `FIRMWARE_SOURCE` | `rootfs/lib/firmware` | merged with host `/lib/firmware` |
| `COMPRESS` | `zstd` | `zstd` / `gzip` / `xz` initramfs compression |
| `FULL` | `0` | `1` = pack entire module tree instead of allow-list |
| `AUTO_HOST` | `0` | `1` = also include currently loaded host modules |
| `FORCE` | `0` | `1` = build even with <2G RAM |
| `MIN_RAM_MB` / `MIN_DISK_MB` | `2048` | safety checks |

### Helper scripts

- `scripts/add-wifi.sh` — sync Wi-Fi modules + firmware from the host into `rootfs/` (run before `make iso` when adding new drivers).
- `scripts/make-grub-bundle.sh` — build `grub-bundle/` from a compiled GRUB tree (`GRUB_SRC=~/grub`), required for the installer to set up EFI boot.
- `scripts/wifi-check.sh` — live Wi-Fi diagnostics, installed as `/usr/bin/silen-wifi-check`.

---

## Project layout

```text
Makefile                  make iso / qemu / clean
scripts/build.sh          7-stage ISO builder (modules -> ramdisk -> initramfs -> ISO)
scripts/add-wifi.sh       vendor Wi-Fi modules/firmware into rootfs/
scripts/make-grub-bundle.sh  package GRUB EFI bits into grub-bundle/
scripts/wifi-check.sh     live diagnostics
boot/vmlinuz              Linux 6.18 kernel image
rootfs/                   initramfs source: init, bin/busybox, lib/modules, lib/firmware
installer/                whiptail installer (main.sh + lib/00-common..90-grub)
spk/                      Rust package manager (get/find/remove)
grub-bundle/              prebuilt GRUB EFI payload shipped on the ISO
branding/                 fastfetch logo + distro info
```

---

## Installation (user flow)

1. Download the latest ISO from Releases.
2. Write it to USB (`dd` is most reliable; Ventoy ISO-file boot is also scanned for).
3. Boot the USB in **UEFI mode**.
4. Install (base only, offline).
5. Select disk (it will be wiped → GPT + ESP + root), hostname, root password, user.
6. Optionally pick GPU driver and desktop + display manager.
7. Reboot into Silen. Run `iwctl` if Wi-Fi needs configuring, `silenfetch` for the logo.

QEMU smoke test: `make qemu` (needs `qemu-system-x86_64` + OVMF, creates `build/disk.img` on first run).

---

## Contributing

Bug reports and contributions: https://discord.gg/WxbRRURcZ

---

## License

AGPL-3.0-or-later — see `LICENSE`.
