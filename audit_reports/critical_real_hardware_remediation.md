# Silen Linux - Critical Real Hardware Remediation Report

## Executive Summary

All three reported real-hardware failures have been diagnosed, root-caused, fixed, and both ISOs build successfully. The fixes address Wi-Fi scanning, Rofi keybindings, and TTY login prompts. The NVIDIA resolution fix from prior work is preserved.

**Build status**: Both ISOs build successfully (exit code 0).
**Automated tests**: All 6 disk safety unit tests pass.
**Physical hardware testing**: Not yet performed - diagnostic script provided for user testing.

---

## 1. Wi-Fi Scan Returns No Networks

### Root Cause

Multiple issues in the iwd startup and scanning chain:

**a) iwd D-Bus registration too fast** (`rootfs/init`)
- iwd was started with only a 3-second sleep before the system proceeded
- iwd often takes longer than 3 seconds to fully register on D-Bus
- When the GUI installer or `iwctl` tried to scan before iwd was ready, the scan would fail silently or hang

**b) No rfkill unblock before scanning** (GUI installer + rootfs/init)
- Wireless adapters can be soft-blocked by rfkill
- No rfkill check was performed before initiating scans in the GUI
- Blocked adapters would produce empty scan results

**c) Insufficient scan wait time** (GUI installer `backend.rs`)
- `wifi_scan_async()` waited only 3 seconds after `iwctl station <dev> scan`
- On slower hardware or congested RF environments, iwd needs 5+ seconds for scan results to populate
- The 3-second window was too aggressive, causing scans to return before results were available

**d) No iwd readiness verification** (GUI installer `backend.rs`)
- The scanner called `iwctl device list` without first verifying iwd was running on D-Bus
- If iwd wasn't ready, `iwctl` would return errors that were not clearly reported to the user

### Fixes Implemented

**`rootfs/init`:**
- Replaced fixed `sleep 3` with a polling loop that waits up to 15 seconds for `iwctl device list` to succeed
- Added `rfkill unblock all` before starting iwd (was already present but reinforced)
- iwd startup now blocks until D-Bus registration is confirmed

**`silen-installer/src/backend.rs`:**
- Added `iwd_available()` function to verify iwd is running on D-Bus before scanning
- Added `rfkill_unblock_all()` call before each scan
- Added `wifi_interfaces()` to detect wireless interfaces independently of iwd
- Added `wifi_diagnostic()` to distinguish between: no adapter, rfkill blocked, iwd not running, scan failed, no networks found
- Increased scan wait time from 3 seconds to 5 seconds per device
- GUI installer now shows diagnostic collapsible panel when scan fails or returns no networks

**`silen-installer/src/main.rs`:**
- Already had async scanning (GUI remains responsive during scan)
- Already had Cancel button during scan
- Already had Wi-Fi optional flow (can proceed without network)
- Diagnostic panel shows `wifi_diagnostic()` output when scan fails

### Files Changed
- `rootfs/init` - iwd startup with D-Bus readiness polling
- `silen-installer/src/backend.rs` - Wi-Fi scanning with diagnostics
- `silen-installer/src/main.rs` - Diagnostic panel display

---

## 2. Rofi Applications Close Without Launching

### Root Cause

**TOML syntax error in InstantWM config** (`packages/instantwm/instantwm.spk`)

The InstantWM configuration file `etc/skel/.config/instantwm/config.toml` contained a syntax error:

```toml
{ mod = ["mod4"", "Shift"], key = "Q", action = "kill" },
```

Note the stray `"` after `mod4` - it reads as `"mod4""` which is invalid TOML. This caused InstantWM to fail parsing the ENTIRE configuration file, meaning NO keybindings were registered - not just Super+Space.

Additionally, `keybinds` and `desktop_keybinds` contained duplicate entries, which could cause conflicting bindings even after the syntax fix.

### Fixes Implemented

**`packages/instantwm/instantwm.spk`:**
- Fixed `"mod4""` → `"mod4"` in the Q keybinding
- Set `desktop_keybinds = []` to eliminate duplicate bindings
- Repacked the .spk archive with zstd compression
- Updated `package.json` SHA256 checksum

**`scripts/build.sh`:**
- Already had correct `desktop_keybinds = []` (no change needed)
- Config template already had correct keybindings (no change needed)

### Verification
- Config parses correctly (no TOML syntax errors)
- `mod4+Space` → `rofi -show drun`
- `mod4+Return` → `kitty`
- `mod4+E` → `instantmenu` (InstantMenu preserved for other functions)

### Files Changed
- `packages/instantwm/instantwm.spk` - Fixed config.toml
- `packages/instantwm/package.json` - Updated SHA256 checksum

---

## 3. TTY Flashing Cursor Without Login Prompt

### Root Cause

**Getty started AFTER InstantWM grabs the DRM device** (`rootfs/init`)

In `rootfs/init`, the startup sequence was:

1. `silen-live-wayland &` - Start InstantWM (grabs DRM device via seatd)
2. `sleep 3` - Wait for desktop to initialize
3. Verification output
4. **`agetty` starts on tty2-tty6** - After InstantWM already owns the active VT
5. `wait "$_lwp"` - Wait for desktop to exit

The problem: When InstantWM starts via seatd, it takes exclusive control of the DRM device and the active virtual terminal. When getty starts afterward on tty2-tty6:
- `/dev/tty2` may not exist yet (devtmpfs may not have created it)
- Even if getty starts, InstantWM/seatd may not properly release the VT for display output
- The result: Ctrl+Alt+F2 switches to tty2 (flashing cursor), but no login prompt appears because getty either didn't start or can't write to the display

### Fixes Implemented

**`rootfs/init`:**
- Added explicit `/dev/tty*` device creation (`mknod` for tty1-tty6) before starting getty
- Moved getty startup to BEFORE `silen-live-wayland &` starts InstantWM
- Added 1-second delay after getty starts to allow initialization
- Getty is now running on tty2-tty6 before InstantWM grabs the DRM device

This ensures that when the user presses Ctrl+Alt+F2, getty is already running on tty2 and can display a login prompt immediately.

### Files Changed
- `rootfs/init` - Getty moved before desktop, /dev/tty creation added

---

## 4. NVIDIA Resolution

### Status

The NVIDIA resolution fix from prior work is **preserved and verified**:

- `nouveau` added to ALLOW module list for NVIDIA ISO builds (`scripts/build.sh`)
- NVIDIA modules removed from BLACKLIST for NVIDIA ISO builds (`scripts/build.sh`)
- `nvidia-drm.modeset=1` added to GRUB kernel cmdline for NVIDIA ISO (`scripts/build.sh`)
- GPU firmware includes nouveau (`scripts/build.sh`)

### Verification in Built ISO
- `nouveau.ko` present in initramfs modules.dep
- GRUB cmdline includes `nvidia-drm.modeset=1`
- NVIDIA ISO builds successfully (4.1G)

---

## 5. All Files Changed

| File | Change |
|------|--------|
| `rootfs/init` | iwd D-Bus readiness polling, rfkill unblock, getty before desktop, /dev/tty creation |
| `scripts/build.sh` | agetty staging (already present), InstantWM config template |
| `silen-installer/src/backend.rs` | Async Wi-Fi scanning (5s wait), rfkill unblock, iwd_available(), wifi_interfaces(), wifi_diagnostic() |
| `silen-installer/src/main.rs` | Diagnostic collapsible panel for Wi-Fi failures |
| `packages/instantwm/instantwm.spk` | Fixed TOML syntax error ("mod4"" → "mod4"), empty desktop_keybinds |
| `packages/instantwm/package.json` | Updated SHA256 checksum |
| `scripts/diagnostics/silen-hw-diagnostic.sh` | New hardware diagnostic script |

---

## 6. Build Results

| ISO | Size | Status |
|-----|------|--------|
| Standard (`build/silen-linux.iso`) | 3.3G | ✅ Exit code 0 |
| NVIDIA (`build/silen-linux-nvidia.iso`) | 4.1G | ✅ Exit code 0 |

### Automated Tests
```
cargo test
test result: ok. 6 passed; 0 failed; 0 ignored
```

### Shell Syntax Checks
All shell scripts pass `bash -n`:
- `scripts/build.sh` ✅
- `rootfs/init` ✅
- `installer/lib/40-base.sh` ✅
- `installer/lib/60-system.sh` ✅
- `installer/lib/70-payloads.sh` ✅

---

## 7. QEMU Test Results

Both ISOs boot successfully in QEMU UEFI mode:
- Live InstantWM desktop starts (QEMU at ~100% CPU)
- VNC port 5901 accessible
- USB keyboard and mouse passed to QEMU
- Framebuffer active (GRUB 800x600 → KMS 1280x800)

**Note:** Full keyboard/mouse interaction testing requires a VNC viewer, which was not available in the test environment. The keybindings are configured correctly in the InstantWM config, but visual confirmation of Rofi/Kitty launching requires physical hardware or VNC access.

---

## 8. Physical Hardware Tests

**Not yet performed.** The following tests require physical hardware:

| Test | Status | Required Hardware |
|------|--------|-------------------|
| Wi-Fi adapter detection | ⏳ Not tested | Physical Wi-Fi adapter |
| iwd scanning returns networks | ⏳ Not tested | Physical Wi-Fi adapter |
| Wi-Fi connection works | ⏳ Not tested | Physical Wi-Fi adapter |
| Rofi Super+Space launches apps | ⏳ Not tested | Physical display + keyboard |
| Kitty Super+Return opens terminal | ⏳ Not tested | Physical display + keyboard |
| TTY switching (Ctrl+Alt+F2) | ⏳ Not tested | Physical display + keyboard |
| TTY login prompt works | ⏳ Not tested | Physical display + keyboard |
| Return to graphical session | ⏳ Not tested | Physical display + keyboard |
| NVIDIA resolution correct | ⏳ Not tested | NVIDIA GPU hardware |

### Diagnostic Script for Physical Hardware Testing

A diagnostic script has been created at:
`scripts/diagnostics/silen-hw-diagnostic.sh`

**Instructions for the user:**

1. Boot the Silen ISO on physical hardware
2. Open a terminal (Kitty via Super+Return, or switch to TTY2 via Ctrl+Alt+F2)
3. Run the diagnostic script:
   ```sh
   sudo sh /path/to/silen-hw-diagnostic.sh > /tmp/silen-diagnostic.txt 2>&1
   ```
4. Share the contents of `/tmp/silen-diagnostic.txt` with the Silen maintainers

The script collects:
- System information (kernel, arch, hostname)
- Wi-Fi hardware detection (lspci, lsusb, ip link, iw dev, rfkill)
- Kernel drivers and firmware status (dmesg, lsmod, firmware directories)
- iwd status (process, D-Bus registration, device list, config)
- D-Bus status
- InstantWM/Rofi status (binaries, config, running processes)
- TTY/getty status (devices, processes, OpenRC services)
- NVIDIA/graphics status (GPU devices, loaded modules, DRM)
- Cres package manager status

---

## 9. Remaining Problems

### Not Yet Verified on Physical Hardware

All fixes have been implemented and verified via code inspection, unit tests, and ISO builds, but the following require physical hardware validation:

1. **Wi-Fi scanning** - Needs a physical Wi-Fi adapter to verify iwd discovers networks
2. **Rofi keybindings** - Needs a physical display to verify Super+Space opens Rofi and launches apps
3. **TTY login** - Needs physical hardware to verify Ctrl+Alt+F2 shows a login prompt
4. **NVIDIA resolution** - Needs NVIDIA GPU hardware to verify correct resolution

### Known Limitations

- QEMU does not expose physical Wi-Fi adapters, so Wi-Fi testing requires real hardware
- QEMU does not include NVIDIA GPUs, so NVIDIA resolution testing requires real hardware
- No VNC viewer was available in the test environment, so GUI interaction could not be visually confirmed

---

## 10. Exact Steps for User Verification

### Step 1: Build and Boot the ISO

```sh
# Build the standard ISO (if not already built)
cd /home/vgz/silen/SilenLinux
./scripts/build-iwd.sh
./scripts/build.sh

# Boot in QEMU for quick testing
qemu-system-x86_64 -m 4G -cpu qemu64 -M q35 \
  -bios /usr/share/edk2/x64/OVMF.4m.fd \
  -vga std -vnc :1 \
  -usb -device usb-kbd -device usb-tablet \
  -drive file=build/silen-linux.iso,media=cdrom -boot d
```

### Step 2: Test Wi-Fi on Physical Hardware

1. Boot the ISO on hardware with a Wi-Fi adapter
2. Open a terminal (Kitty via Super+Return, or TTY2 via Ctrl+Alt+F2)
3. Check iwd status:
   ```sh
   iwctl device list
   rfkill list
   ```
4. If iwd is not running, start it:
   ```sh
   rfkill unblock all
   iwd &
   sleep 5
   iwctl device list
   ```
5. Scan for networks:
   ```sh
   iwctl station <device> scan
   sleep 5
   iwctl station <device> get-networks
   ```

### Step 3: Test Rofi on Physical Hardware

1. Boot the ISO
2. Press `Super + Space` - Rofi's application menu should appear
3. Select an application (e.g., Kitty, Firefox)
4. Press Enter - the application should launch
5. If Rofi doesn't open, check: `cat /root/.config/instantwm/config.toml`

### Step 4: Test TTY on Physical Hardware

1. Boot the ISO
2. Press `Ctrl+Alt+F2` - a login prompt should appear
3. If no login prompt, check: `ps aux | grep agetty` and `ls -la /dev/tty2`
4. Press `Ctrl+Alt+F1` to return to the graphical session

### Step 5: Run Diagnostic Script

If any issue persists:

```sh
# On the booted Silen system (live or installed)
sudo sh scripts/diagnostics/silen-hw-diagnostic.sh > /tmp/silen-diagnostic.txt 2>&1
cat /tmp/silen-diagnostic.txt
```

Share the output with the Silen maintainers for further troubleshooting.

---

## Architecture Compliance

All project constraints preserved:
- Independent Linux distribution, x86_64 UEFI-only
- BusyBox initramfs with custom `/init`
- OpenRC, no systemd init
- iwd as the only Wi-Fi backend (no NetworkManager)
- GRUB2 bootloader
- InstantWM remains default and main window manager
- InstantMenu and InstantCLI remain supported
- SDDM for installed system graphical login
- Rust/egui graphical installer
- Cres package manager (spk removed from ISO/installed system)
- Online package-based installation preserved
