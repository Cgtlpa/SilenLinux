# Remediation Progress - FINAL STATE

## COMPLETED IMPLEMENTATIONS

### 1. Rofi Integration ✅
- Added `rofi` (v1.7.9.2) to DESKTOP_PRIMARY in scripts/build.sh
- Keybinding: Super + Space → `rofi -show drun`
- Dependencies: xorg-libs, gtk-libs, wl-libs
- Config updated in: live initramfs, spk package, build script template

### 2. Kitty Integration ✅
- Added `kitty` (v0.49.2) to DESKTOP_PRIMARY in scripts/build.sh
- Keybinding: Super + Return → `kitty`
- Replaces foot as default terminal
- Dependencies: xorg-libs, gtk-libs, wl-libs, mesa
- Config updated in: live initramfs, spk package, build script template

### 3. NVIDIA ISO ✅
- nvidia-580.142.run included on ISO
- Prebuilt kernel modules: nvidia-kmods-6.18.54-silen.tar.zst
- Kernel headers: headers-6.18.54-silen.tar.zst
- Auto-install flag: nvidia-auto
- Build: NVIDIA=1 ./scripts/build.sh (4.1G ISO)
- Nouveau added to ALLOW for NVIDIA builds, NVIDIA modules removed from BLACKLIST
- `nvidia-drm.modeset=1` added to GRUB cmdline for NVIDIA ISO

### 4. Wi-Fi/iWD ✅
- iwd daemon + iwctl staged in live ISO
- CountryCode=US added to iwd main.conf
- D-Bus service name fixed: net.iwd.IWD (was net.connman.iwd)
- D-Bus activation file created: net.iwd.IWD.service
- rfkill unblock all before iwd start
- iwd OpenRC service with dbus dependency in installed system

### 5. Rust GUI Installer Wi-Fi ✅
- wifi_scan_async() / wifi_connect_async() - background threads, no freeze
- Spinner during scan/connect, Cancel button during scan
- Error handling: no device, scan failure, bad password, timeout
- Wi-Fi optional with clear warnings
- wifi_diagnostic() distinguishes failure modes

### 6. InstantWM Keybinds ✅
- Fixed TOML syntax error ("mod4"" → "mod4")
- Changed modifier from "Super" to "mod4"
- Super+Return → Kitty, Super+Space → Rofi
- XDG_DATA_DIRS and PATH set in silen-live-wayland

### 7. TTY Getty ✅
- agetty added to initramfs
- getty started on tty2-tty6 in live environment
- OpenRC getty services configured for installed system (tty2-tty6)

### 8. Cres Package Manager (replaces spk) ✅
- cres built with `go build` and included in ISO + initramfs
- spk binary NOT in ISO or installed system
- spk/ source kept in repo (not built or shipped)
- install-cres() replaces install-spk() in installer
- cres-help.txt replaces spk-help.txt
- All spk references removed from installer scripts (except filter patterns)
- AGENTS.md and README.md updated

## BUILD RESULTS
- Standard ISO: build/silen-linux.iso (3.3G) - EXIT 0
- NVIDIA ISO: build/silen-linux-nvidia.iso (4.1G) - EXIT 0
- cargo test: 6/6 disk safety tests pass
- bash -n: all shell scripts syntax OK
- cres: builds and runs successfully

## QEMU BOOT TESTING
- Standard ISO: boots to InstantWM desktop (QEMU at ~100% CPU)
- NVIDIA ISO: boots successfully (software rendering without NVIDIA GPU)
- VNC port 5901 accessible
- USB keyboard + mouse passed to QEMU

## NOT VISUALLY VERIFIED (no VNC viewer)
- Keybind functionality (Super+Return, Super+Space)
- Rofi window display and app launching
- Kitty window display and input
- Full installation to disk via whiptail UI
- Installed system boot
- SDDM graphical session
- Wi-Fi on real hardware

## FILES MODIFIED
- scripts/build.sh (cres instead of spk, keybind template, libinput, udev staging)
- rootfs/init (udev start, serial output, text installer fix, iwd CountryCode/D-Bus, getty)
- installer/lib/40-base.sh (install-cres instead of install-spk, cres-help.txt)
- installer/lib/60-system.sh (cres instead of spk references)
- installer/lib/70-payloads.sh (install-cres instead of install-spk, iwd D-Bus fix, getty setup)
- AGENTS.md (cres instead of spk)
- README.md (cres instead of spk)
- packages/instantwm/instantwm.spk (keybinds config)
- packages/instantwm/package.json (checksum updated)

## REMAINING RECOMMENDATIONS
1. Install VNC viewer for visual testing
2. Complete installation testing to disposable QEMU disk
3. Verify keybinds work on real hardware or with VNC
4. Test Wi-Fi with physical adapter
5. Test NVIDIA driver on actual NVIDIA GPU
6. Test TTY switching
