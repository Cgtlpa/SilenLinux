# Silen Linux

Silen Linux is an independent, lightweight x86_64 Linux distribution built from the ground up. It is not a reskin of another distro — Silen has its own initramfs (`rootfs/init`), its own offline installer (`installer/`), its own package manager (`spk`), and its own ISO builder (`scripts/build.sh`). No systemd, no NetworkManager, no bloat. Just a minimal, fast base you build on top of.

## What Silen is

| Component | What Silen uses |
|---|---|
| Kernel | Linux 6.18 (`boot/vmlinuz` + `rootfs/lib/modules/`) |
| Init (installed system) | OpenRC (`rc-update`, `elogind`) |
| Live init | Custom BusyBox-based initramfs (`rootfs/init`) |
| Arch | x86_64, UEFI only (legacy boot refused) |
| Bootloader | GRUB2 via `grub-mkrescue` |
| Base system | `tarball-silen.xz` / `stage3-*.tar.*` (Gentoo base without portage tree/compiler) |
| Package manager | `spk` — Rust tool (`spk/src/get.rs`), built into the ISO |
| Wi-Fi backend | iwd + `iwctl`/`iwmon` + D-Bus (no NetworkManager) |
| Window manager | InstantWM (Wayland, DRM/KMS backend) |
| App launcher | Rofi (`mod4+Space`) |
| Terminal | Kitty (`mod4+Return`) |
| License | AGPLv3 (`LICENSE`) |

## Key features

### Independent, not derivative
Silen builds its own live ISO, its own installer, and its own package manager. There is no dependency on Arch, Gentoo, Debian, or any other distro's infrastructure.

### Linux 6.18 kernel
Shipped as `boot/vmlinuz` on the ISO, with a `kernel-6.18.54-silen.tar.zst` bundle unpacked into the installed system.

### Minimal live environment
The ISO boots into a RAM root with BusyBox, bash, `whiptail` (TUI installer), `git`, `curl`, `zstd`, `tar`, `sfdisk`, `blkid`, filesystem tools, iwd Wi-Fi stack, and CA certificates.

### Broad hardware support
- **Storage**: AHCI, NVMe, virtio-blk/scsi, MMC/SDHCI, USB-storage/UAS
- **Wired**: `e1000/e1000e`, `r8169`, `igb`, `ixgbe`, `r8152`, `alx`, `cdc_ether`, `rndis_host`
- **Wi-Fi**: Intel `iwlwifi`, Atheros `ath9k/ath10k/ath11k`, MediaTek `mt76/mt79xx`, Realtek `rtw88/rtw89/rtlwifi`, Broadcom `brcmfmac/b43`, and more
- **GPU firmware** (installed system): `amdgpu`, `amd-ucode`, `intel-ucode`, `i915`, `xe`, `nouveau`, `radeon`
- **NVIDIA**: Opt-in `make nvidia-iso` variant prebuilds the proprietary driver kernel modules; the normal base ships no compiler and no NVIDIA blobs (~200MB saved)

### Offline installer (whiptail TUI)
No network required to install. Filesystem choice (ext4/btrfs), hostname, root password, optional user, locale/keymap/timezone, optional swapfile. Disk is wiped and repartitioned with GPT (ESP + root).

### `spk` package manager
After the first reboot, install packages with network:
```sh
spk get <pkg...>     # install (e.g. spk get linux-firmware mesa sddm)
spk find <pattern>   # search installed registry
spk rm <pkg...>      # remove (never deletes /etc/passwd, shadow, fstab, /boot kernels, or GRUB files)
```
- System packages (kernels, drivers, firmware, DEs, DMs) install to `/`
- Leaf apps install isolated to `/spk_pkgs/<name>` with shims in `/usr/local/bin`
- Audio: `spk get silen-audio` (full PipeWire, WirePlumber, ALSA/Pulse clients)
- Default source: `https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages`

### Desktop: InstantWM + Rofi + Kitty
The live ISO and installed system boot to InstantWM, a lightweight Wayland compositor:
- `mod4+Space` → Rofi application launcher (`rofi -show drun`)
- `mod4+Return` → Kitty terminal
- `mod4+E` → InstantMenu
- `mod4+Shift+Q` → kill focused window
- `mod4+Arrows` → move focus; `mod4+C/M/R` → floating/maximized/reset layout

### TTY access
`agetty` runs on tty2-tty6. Press `Ctrl+Alt+F2` through `F6` to switch to text consoles, `Ctrl+Alt+F1` to return to the graphical session.

### Safe kernel updates
The installer builds `initramfs-silen.img` for the target. `spk` regenerates it automatically when a kernel package is installed, and refuses to delete `/boot` kernels, initramfs images, or GRUB files.

### Built-in diagnostics
`silen-wifi-check` (from `scripts/wifi-check.sh`) dumps `lsmod`, `ip link`, `rfkill`, `lspci/lsusb`, `dmesg`, `iwctl`, `iwd`, and D-Bus status to `/tmp/silen-wifi.log`.

---

## Installation

### 1. Get the ISO
Download the latest `silen-linux.iso` from Releases, or build it yourself (see below).

### 2. Write to USB
```sh
# Replace /dev/sdX with your USB device — WARNING: this wipes the device
sudo dd if=silen-linux.iso of=/dev/sdX bs=4M status=progress
```
Ventoy ISO-file boot is also supported (the installer scans for `*silen*.iso` loop mounts).

### 3. Boot in UEFI mode
Silen is UEFI-only. Legacy/BIOS boot is refused by the installer.

### 4. Install
The live environment starts InstantWM. From there you can:
- Launch the graphical installer (`silen-installer` — Rust/egui GUI) for a guided install with optional Wi-Fi setup
- Or boot with `silen.text` on the GRUB cmdline for the whiptail TUI installer

The installer will:
1. Detect and select the target disk (it will be wiped → GPT + ESP fat32 + root ext4/btrfs)
2. Extract the base system tarball
3. Unpack the kernel bundle, firmware, network bundle (iwd + dbus), and `spk`
4. Build the target's `initramfs-silen.img`
5. Install GRUB to the EFI partition

### 5. First boot
After reboot:
- Log in via TTY or wait for SDDM (if installed via `spk`)
- Configure Wi-Fi with `iwctl` if needed: `iwctl station <device> scan`, then `station <device> connect <SSID>`
- Install desktops and apps with `spk` (needs network):
  ```sh
  spk get sddm              # display manager
  spk get sway foot         # Wayland compositor + terminal
  spk get linux-firmware    # additional firmware
  ```
- Run `silenfetch` to see the distro logo

---

## Building the ISO

### Host requirements
`grub-mkrescue` (`grub`, `xorriso`, `mtools`, `dosfstools`), `cpio`, `zstd`, `tar`, `modinfo`, `depmod`, `ldconfig`, `strip`, `cargo` (for `spk`), OVMF firmware for QEMU.

### Commands
```sh
# Clone
git clone https://github.com/Cgtlpa/SilenLinux.git
cd SilenLinux

# Build the standard ISO
make iso          # builds build/silen-linux.iso (~3.3G)

# Build the NVIDIA variant (prebuilt proprietary driver kmods)
make nvidia-iso   # needs headers-<kver>.tar.zst

# Boot in QEMU (UEFI, 4G RAM, 8G disposable disk)
make qemu

# Clean build artifacts
make clean
```

### Before building
Place these in the repo root (or the build will complain):
- `boot/vmlinuz` — kernel image
- `rootfs/lib/modules/6.18.54-silen/` — module tree
- `rootfs/lib/firmware/` — firmware files
- `tarball-silen.xz` or `stage3-*.tar.*` — Gentoo base rootfs (the installer refuses to install without it)

### Useful environment overrides
| Var | Default | Meaning |
|---|---|---|
| `KERNEL_VERSION` | auto-detected | module dir / depmod version |
| `KERNEL_SOURCE` | `boot/vmlinuz` | kernel image to ship |
| `MODULES_SOURCE` | `rootfs/lib/modules/$KERNEL_VERSION` | module tree path |
| `COMPRESS` | `zstd` | initramfs compression (`zstd`/`gzip`/`xz`) |
| `FULL` | `0` | `1` = pack entire module tree instead of allow-list |
| `FORCE` | `0` | `1` = build even with <2G RAM |

---

## Project layout

```
Makefile                  make iso / qemu / clean
scripts/build.sh          7-stage ISO builder
scripts/add-wifi.sh       vendor Wi-Fi modules/firmware into rootfs/
scripts/make-grub-bundle.sh  package GRUB EFI into grub-bundle/
scripts/wifi-check.sh     live Wi-Fi diagnostics (/usr/bin/silen-wifi-check)
boot/vmlinuz              Linux 6.18 kernel image
rootfs/                   initramfs source: init, busybox, modules, firmware
installer/                whiptail TUI installer (main.sh + lib/)
silen-installer/          Rust/egui graphical installer
spk/                      Rust package manager (get/find/remove)
grub-bundle/              prebuilt GRUB EFI payload
branding/                 fastfetch logo + distro info
LICENSE                   AGPLv3
```

---

## Contributing

Bug reports, fixes, and package contributions are welcome. See `AGENTS.md` for the agent/contributor guide (build commands, repo layout, shell style, binding rules).

Project: https://github.com/Cgtlpa/SilenLinux

---

## License

AGPL-3.0-or-later — see `LICENSE`.