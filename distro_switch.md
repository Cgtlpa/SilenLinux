# Silen Linux – Distro Switch Guide

Everything you need to switch to Silen Linux: from building the ISO to installing
and configuring your new system.

---

## 1. What is Silen Linux?

Silen is an independent, lightweight x86_64 Linux distribution.

| Component | Choice |
|-----------|--------|
| Init system | OpenRC |
| Package manager | Cres (custom, Go) |
| Wi-Fi backend | iwd only (no NetworkManager) |
| Desktop | InstantWM (Wayland) |
| Bootloader | GRUB2 (UEFI-only) |
| Kernel | Linux 6.18 LTS |
| TTYs | tty2–tty6 (agetty) |

Silen ships as a minimal live ISO that boots into a text-based installer.
Most packages (desktop, apps, drivers) are downloaded during installation
via Cres — the ISO itself stays small.

---

## 2. Prerequisites (what you need)

### Host system (for building the ISO)

You need a Linux host with the following tools installed:

```bash
# Build essentials
build-essential  (gcc, make, etc.)
go               (for building Cres)
cargo            (for installer tests, optional)
sudo             (the build script uses sudo for mount/loop devices)
xorriso          (grub-mkrescue backend)
grub-mkrescue
cpio
zstd
depmod
ldconfig
strip
ldd
curl
```

The build script also needs kernel modules and a base tarball in the repo root:

```text
boot/vmlinuz              # Kernel image
rootfs/lib/modules/       # Kernel module tree
tarball-silen.xz          # Gentoo-based stage3 tarball
```

### Target hardware (for installation)

- UEFI-capable system (BIOS/legacy boot is not supported)
- At least 8 GiB disk space
- Internet connection (Ethernet or Wi-Fi) for package downloads
- 2 GiB+ RAM recommended

---

## 3. Building the ISO

Clone the repository:

```bash
git clone https://github.com/Cgtlpa/SilenLinux.git
cd SilenLinux
```

### Basic build (minimal ISO)

```bash
FORCE=1 MINIMAL_ISO=1 make iso
```

### Full build (includes desktop packages in the ISO)

```bash
FORCE=1 make iso
```

### Build options

| Variable | Default | Description |
|----------|---------|-------------|
| `FORCE` | unset | Bypass RAM/disk checks (set to `1` to skip) |
| `MINIMAL_ISO` | `1` | Skip desktop packages (download during install) |
| `COMPRESS` | `zstd` | Initramfs compression: `zstd`, `gzip`, `xz` |
| `FULL` | unset | Pack full module tree instead of allow-list |
| `AUTO_HOST` | unset | Include currently loaded host modules |
| `KERNEL_VERSION` | auto-detect | Override kernel version |
| `KERNEL_SOURCE` | `boot/vmlinuz` | Custom kernel image path |
| `MODULES_SOURCE` | auto-detect | Custom modules directory |
| `NVIDIA` | unset | Build NVIDIA variant (`make nvidia-iso`) |

### Output

```
build/silen-linux.iso        # The bootable ISO (UEFI)
```

Size is approximately 2.9 GB (minimal) or 3.3 GB (full).

---

## 4. Testing in QEMU

```bash
make qemu
```

This boots the ISO in UEFI QEMU with:
- 4 GB RAM
- Q35 machine type
- 8 GB virtual disk (`build/disk.img`)
- OVMF firmware

**Note:** QEMU without KVM (`/dev/kvm` missing) uses TCG emulation, which may be slow
and can trigger AVX instruction crashes with host-built libraries. If available,
ensure KVM is loaded:

```bash
sudo modprobe kvm_intel   # or kvm_amd
```

Clean up:

```bash
make clean
```

---

## 5. Installing on Real Hardware

### Write the ISO to USB

```bash
# Find your USB device (BE CAREFUL — this destroys all data on it)
lsblk

# Write the ISO
sudo dd if=build/silen-linux.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Replace `/dev/sdX` with your actual USB device.

### Boot the installer

1. Insert the USB and reboot
2. Enter your system's boot menu (usually F12, F2, Esc, or Del)
3. Select the USB drive
4. Choose **Silen Installer** from the GRUB menu
5. The system boots into a text-based installer

### Installation workflow

1. **Welcome** — Introduction to Silen
2. **Internet check** — If no connection, the Wi-Fi setup screen appears
3. **Disk selection** — Choose the target disk
4. **Partitioning** — GPT with ESP (FAT32) + root (ext4/btrfs)
5. **Settings** — Hostname, root password, user account, timezone, keymap, filesystem
6. **Base system** — Extracts the stage3 tarball
7. **Cres packages** — Downloads and installs packages online (InstantWM, Kitty, etc.)
8. **Bootloader** — GRUB2 EFI installation
9. **Initramfs** — Generated for the target kernel
10. **Tutorial** — Short Silen introduction screens
11. **Complete** — Reboot or exit to shell

---

## 6. Wi-Fi in the Live ISO

Silen uses **iwd** as its Wi-Fi backend.

### If Wi-Fi doesn't work

1. Check that your wireless interface is detected:
   ```bash
   iwctl device list
   ```

2. Unblock Wi-Fi:
   ```bash
   rfkill unblock all
   ```

3. Bring the interface up:
   ```bash
   ip link set wlan0 up
   ```

4. Scan and connect via the installer's Wi-Fi screen, or manually:
   ```bash
   iwctl station wlan0 scan
   iwctl station wlan0 get-networks
   iwctl station wlan0 connect <SSID>
   ```

5. Verify internet:
   ```bash
   ping -c 3 1.1.1.1
   ```

---

## 7. Using Cres (Package Manager)

Cres is Silen's custom package manager written in Go.

### Basic commands

```bash
# Search for packages
cres search <pattern>

# Show package details
cres info <package>

# List installed packages
cres list

# List available packages in repo
cres list --available

# Install a package
sudo cres get <package>

# Install multiple packages
sudo cres get pkg1 pkg2 pkg3

# Remove a package
sudo cres rm <package>

# Update all packages
sudo cres update

# Sync package index
sudo cres sync

# Check for updates
cres update --check
```

### Package types

| Type | Installs to | Example |
|------|-------------|---------|
| System | `/` (root filesystem) | Kernels, drivers, desktop, dbus, iwd |
| Leaf app | Isolated with shim in `/usr/local/bin` | Firefox, Kitty, Yazi |

### Example: Install a web browser

```bash
sudo cres get firefox
```

---

## 8. Post-Installation Setup

### First boot

After installation completes, reboot into your new Silen system. You'll be at a text login.

### Start the desktop

```bash
# InstantWM (default Wayland compositor)
instantwm --backend drm
```

### Key bindings (InstantWM)

| Key | Action |
|-----|--------|
| Super+Return | Open terminal (Kitty) |
| Super+Space | Application launcher (Rofi) |
| Super+E | InstantMenu |
| Super+Shift+Q | Close window |
| Super+C | Toggle floating |
| Super+M | Toggle tiling/maximized |
| Super+Arrows | Focus windows |

### Service management (OpenRC)

```bash
# Check running services
rc-status

# Start a service
rc-service <name> start

# Stop a service
rc-service <name> stop

# Enable at boot
rc-update add <name> default

# Disable from boot
rc-update del <name> default
```

### Essential services

```bash
# Wi-Fi
rc-update add iwd default

# Display manager (if using SDDM)
rc-update add sddm default

# D-Bus
rc-update add dbus default
```

---

## 9. Configuration Files

| File | Purpose |
|------|---------|
| `/etc/hostname` | System hostname |
| `/etc/conf.d/keymaps` | Keyboard layout |
| `/etc/conf.d/hostname` | OpenRC hostname |
| `/etc/timezone` | Timezone |
| `/etc/localtime` | Timezone symlink |
| `/etc/fstab` | Filesystem mounts |
| `/etc/resolv.conf` | DNS (managed by iwd) |
| `/etc/iwd/main.conf` | iwd Wi-Fi configuration |
| `~/.config/instantwm/config.toml` | InstantWM config |
| `/var/cache/cres` | Cres download cache |
| `/var/lib/cres` | Cres package database |

---

## 10. Troubleshooting

### ISO won't boot

- Ensure UEFI mode is enabled in your BIOS
- Disable Secure Boot if enabled
- Verify the USB was written correctly (`dd` + `sync`)

### No Wi-Fi networks found

```bash
rfkill list          # Check for soft/hard blocks
rfkill unblock all   # Unblock everything
ip link set <iface> up  # Bring interface up
iwctl device list    # Check iwd sees the device
```

### Installer hangs

- Ensure you have an active internet connection
- Check available disk space (8 GiB+ minimum)
- Try the "fallback, nomodeset" GRUB entry for graphics issues

### Package install fails

```bash
# Check Cres status
cres doctor

# Sync index
sudo cres sync

# Retry with verbose output
sudo cres get -v <package>

# Use --force to ignore conflicts (use with caution)
sudo cres get --force <package>
```

---

## 11. Repository Structure

```
SilenLinux/
├── Makefile              # Build targets (iso, qemu, clean, nvidia-iso)
├── scripts/build.sh      # ISO builder (7 stages)
├── rootfs/init           # Live ISO init (sh)
├── rootfs/bin/busybox    # Static busybox
├── boot/vmlinuz          # Kernel image
├── installer/            # Whiptail/TUI installer
│   ├── main.sh           # Loader
│   └── lib/              # Modular installer scripts
├── cres/                 # Go package manager
│   ├── main.go
│   └── internal/
├── packages/             # SPK package definitions
├── tarball-silen.xz      # Base stage3 tarball
├── branding/             # Logo, info
└── README.md             # User-facing README
```

---

## 12. License

Silen Linux is licensed under AGPLv3. See `LICENSE` for details.

---

## Quick Reference

```bash
# Build ISO
FORCE=1 MINIMAL_ISO=1 make iso

# Test in QEMU
make qemu

# Clean build artifacts
make clean

# Install package
sudo cres get <package>

# Update system
sudo cres update

# Check Wi-Fi
iwctl device list
```

Good luck with your distro switch! Welcome to Silen.