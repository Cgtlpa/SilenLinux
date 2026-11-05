# Silen Linux Consolidated Audit Report

## 1. Executive summary

Two independent audits (Kilo and Clint) were performed against the Silen Linux repository. Both agree on the overall architecture: an independent x86_64 distro with a custom BusyBox live init, OpenRC on the installed system, iwd for networking, UEFI-only GRUB, and offline tarball-based installation. The most significant verified defect is in the live initramfs staging: `scripts/build.sh` copies the udevd binary to the path `/usr/bin/udevadm` and never stages `/usr/bin/udevd`, so the live init's udev startup gate always fails and input device discovery never runs. A second major structural problem is that the Rust/egui graphical installer and the bash fallback installer are not feature-parallel, producing different installed systems. A third is that `cres` (Go package manager) exists in-tree but is not built, shipped, or invoked anywhere in the install path, while `spk` (Rust) is the actual runtime package manager.

## 2. Verified findings

- **udev staging defect (Critical).** `scripts/build.sh:503` runs `copy_app udevd /usr/bin/udevadm`. Consequently `/usr/bin/udevd` is never staged, and `rootfs/init` only starts udev when `[ -x /usr/bin/udevd ]`. With udev absent, `/usr/bin/udevadm` is in fact the udevd binary. Verified by direct inspection of both files. This breaks input device tagging/seat assignment in the live session and any udev-dependent live functionality.
- **Live keyboard/mouse input unreliable (High).** With no udev, seatd/libinput cannot enumerate or tag input devices; InstantWM may still start on DRM but input will not work. Verified as a consequence of the above defect.
- **Two installers, two resulting systems (High).** The Rust GUI (`silen-installer`) omits SDDM setup, syslogd/klogd, busybox ntpd, bootlogd, fstrim, microcode image, resume-offset cmdline, installed-initramfs rebuild, and `target-scripts` copy, all of which the bash installer performs. Verified by comparing `do_install` orchestration against `installer/lib/70-payloads.sh` and `75-extras.sh`.
- **Rust disk list can offer partitions as wipe targets (Critical).** `list_disks()` only skips digit-suffixed names under limited conditions; partitions such as `sda1` can be offered, and `wipefs -a` + `sfdisk` on a partition causes data loss. Verified in clint audit against the Rust source.
- **cres is not integrated (High).** `cres/` is never referenced in `scripts/build.sh`, not built into the ISO, not installed by either installer, and not in spk's `SYSTEM_EXACT`. Two divergent package indexes exist. Verified by grep across build/installer/spk.
- **Installed system has no graphical session by default (High).** Neither installer installs InstantWM, a display manager, or a seat manager into the target. InstantWM is a live-ISO-only feature. Verified against `do_install` and bash `70-payloads.sh`.
- **No systemd/NetworkManager dependency introduced (Verified clean).** Only an intentional elogind shim (`libsystemd.so.0 -> libelogind.so.0`) and a best-effort `rc-update del NetworkManager default`. iwd is built with `--disable-systemd-service`. Verified by grep.
- **SDDM service is effectively dead code on the installed system.** The bash path writes the service only if the sddm binary exists, but no sddm package is installed during offline install. Verified.
- **Silent failures in installer (Medium).** Many steps are `|| true` or logged-and-continue; `run()` discards stdout/stderr; no rollback on partial failure. Verified in clint audit.
- **Missing `/etc/hosts` entry for hostname and no `/etc/machine-id` at install time (Low/Medium).** Verified.

## 3. Unverified findings

- seatd `-g root` permission behavior at runtime.
- InstantWM XKB compose data availability (`/usr/share/X11/locale`) in the live image.
- GPU firmware availability for live KMS (merged into ISO `firmware/` only, not initramfs, by design).
- `efibootmgr`/efivars functionality and boot after install on real firmware; Secure Boot behavior (GRUB is unsigned).
- NVIDIA auto-install path in chroot.
- `spk get` network reachability post-reboot.
- `grub-install --removable` reliability across firmware implementations.
- Whether `dhcpcd`/`udhcpc` are staged in the live image.

## 4. Contradictions between audits

- Kilo reported swapfile creation as potentially missing; Clint verified it is implemented in both frontends (different mechanisms: bash `made_swapfile` flag vs Rust `Path::exists()`). Resolution: implemented, but the two mechanisms must stay in sync.
- Kilo noted no udev defect's downstream impact on input; Clint did not mention udev at all. Kilo's finding is the authoritative one (verified in code).
- Clint reported `cres` as a major unintegrated package manager; Kilo did not cover cres. Clint's finding is authoritative.

## 5. Prioritized issue list

### Critical
1. udev staging defect (`scripts/build.sh:503`) — live input/device discovery broken.
2. Rust `list_disks()` partition exclusion — data-loss risk on wipe.

### High
3. Installer frontend divergence (Rust GUI vs bash) — non-deterministic installed systems.
4. cres not integrated vs spk — two divergent package managers.
5. InstantWM not installed into target — live-only desktop, tty-only installed system.
6. SDDM dead service + no seat manager — graphical login cannot work post-install.

### Medium
7. Silent failures / no rollback in installer.
8. iwd binary copied from live (fails if `NO_WIFI=1`); no networks pre-configured; DNS split-brain with static resolv.conf.
9. Missing wired-network service (dhcpcd) despite docs referencing it.
10. Missing `/etc/machine-id` at install; missing `/etc/hosts` hostname entry.

### Low
11. GRUB `console=ttyS0` hardcoded; no Secure Boot handling; no multi-boot.
12. Rust skips `unicode.pf2` font copy (divergent graphics fallback).
13. No first-boot wizard or auto-network.

## 6. Recommended implementation order

1. Fix udev staging (copy udevd to `/usr/bin/udevd`, and udevadm separately) — smallest, highest impact.
2. Fix Rust disk partition exclusion and add mounted-disk check.
3. Unify installer frontends (port bash extras into Rust or make GUI a wrapper).
4. Decide on one package manager (integrate cres or standardize on spk).
5. Make installed system boot to working desktop or document tty-only explicitly; install seat manager + DM + WM during install if advertised.
6. Add error fatality and rollback.
7. Clarify first-boot network (pre-populate iwd or document `iwctl`).

## 7. Required runtime tests

- QEMU boot of ISO with udev fix; verify `/run/udev/control` socket and input devices.
- QEMU install (both GUI and bash paths) and first boot; compare resulting service sets.
- Real-hardware UEFI boot test; Secure Boot on/off.
- Network test: `iwctl` flow, DNS resolution after connect.
- InstantWM input test (keyboard/mouse) on QEMU with USB input devices.
- spk get over network post-reboot.

## 8. Files likely affected

- `scripts/build.sh` (udev copy, desktop staging, spk/cres build).
- `rootfs/init` (udev startup gate, live session launch).
- `silen-installer/src/main.rs` (disk list, do_install orchestration).
- `installer/lib/30-partition.sh`, `70-payloads.sh`, `75-extras.sh`, `90-grub.sh`.
- `spk/src/get.rs` (SYSTEM_EXACT, install paths).
- `cres/` (integration or removal decision).
- `target-scripts/` (silen-wifi-check, silen-nvidia-check).

## Recommended implementation plan (do not implement)

Address issues in the priority order above. Start with the udev fix and disk-list fix as standalone commits, then tackle installer unification, then package-manager consolidation, then desktop/seat-manager integration. Each step should be validated with the corresponding runtime test from section 7 before proceeding. No destructive or disk-modifying commands should be run outside of isolated QEMU test environments. InstantWM must remain the default WM, OpenRC and iwd must remain (no systemd/NetworkManager), and SPK must not be removed before cres (or vice versa) is verified as a replacement.
" filePath="/home/vgz/silen/SilenLinux/audit_reports/final_audit.md"