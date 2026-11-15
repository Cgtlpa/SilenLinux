# Silen Linux Audit Verification — Independent Review of Kilo and Clint Reports

**Task:** Independently review and challenge the findings in `kilo_report.md`, `clint_report.md`, and `final_audit.md` against the actual source code under `/home/vgz/silen/SilenLinux/` and `/home/vgz/silen/Silen-Linux_gui/`.

**Constraint:** Read-only. No source files modified, no destructive operations.

---

## 1. Executive Summary of Verification

| Report | Size | Key Findings Verified | Key Findings Challenged |
|--------|------|----------------------|------------------------|
| `kilo_report.md` (8124 bytes) | Live environment focus | cres not integrated, Silent failures, SDDM dead service | **udev staging defect (entirely incorrect)** |
| `clint_report.md` (26154 bytes) | Installation focus | Most findings technically correct | Minor misclassifications, overlooked issues |
| `final_audit.md` (consolidated) | Combined | Good synthesis | Repeats kilo's incorrect udev claim as "Critical" |

**Most important correction:** The `kilo_report.md` and `final_audit.md` claim a "Critical" udev staging defect at `scripts/build.sh:503` (`copy_app udevd /usr/bin/udevadm`). **This code does not exist.** Line 503 of `build.sh` is `copy_libs "/usr/lib/git-core/$helper"`. There is no `copy_app udevd` anywhere in `build.sh`, and `rootfs/init` contains no udev startup gate. This finding is **incorrect** and should be removed from the consolidated report.

---

## 2. Finding-by-Finding Verification

### 2.1. udev Staging Defect — INCORRECT

**Original finding (kilo_report #1, final_audit "Verified findings"):**
> `scripts/build.sh:503` runs `copy_app udevd /usr/bin/udevadm`. Consequently `/usr/bin/udevd` is never staged, and `rootfs/init` only starts udev when `[ -x /usr/bin/udevd ]`.

**Conclusion: INCORRECT**

**Technical reasoning:**
- Line 503 of `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh` is `copy_libs "/usr/lib/git-core/$helper"` — part of git-core helper library copying, not udev.
- `grep -n "udev" build.sh` returns only one match: line 920, `libudev.so*` in a Mesa/DRI library merge loop (linking, not binary staging).
- `grep -n "udev" rootfs/init` returns **no matches** — there is no udev startup gate in the live init.
- There is no `copy_app udevd`, `copy_app udevadm`, or any udev binary staging in build.sh.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh:503` (actual content: git-core helper)
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh:920` (libudev.so* library merge)
- `/home/vgz/silen/Silen-Linux_gui/rootfs/init` (no udev reference)

**Suggested correction:** Remove the entire udev staging defect finding from all reports. It describes code that does not exist in this repository state.


### 2.2. Live Keyboard/Mouse Input Unreliable — PARTIALLY CONFIRMED

**Original finding (kilo_report #3, final_audit):**
> With no udev running, seatd/libinput cannot enumerate input devices; InstantWM may start on DRM but input will not work.

**Conclusion: PARTIALLY CONFIRMED** — the consequence is real, but the root cause is not the (non-existent) udev mis-copy.

**Technical reasoning:**
- `rootfs/init` does not start udevd at all (no udev binary staged into initramfs).
- `rootfs/init` does start iwd and dbus, and mounts devtmpfs, so `/dev/input/event*` nodes exist.
- However, without udevd, input devices are not tagged with seat information (`ID_SEAT`), which seatd/libinput rely on for proper device assignment.
- InstantWM (DRM backend) uses `libseat` + `libinput` for input. Without seatd running and without udev tagging, input may not work correctly.
- The live init does NOT start seatd either. It only starts dbus and iwd.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/rootfs/init` (no seatd, no udevd startup)

**Suggested correction:** Reclassify as: "Live environment does not start udevd or seatd; input device enumeration and seat assignment will be broken for InstantWM's libinput/libseat path." This is a real issue but not caused by a udevd/udevadm mis-copy.

---

### 2.3. Cres Not Integrated vs SPK — CONFIRMED

**Original finding (clint_report, final_audit):**
> `cres/` is never referenced in `scripts/build.sh`, not built into the ISO, not installed by either installer, and not in spk's `SYSTEM_EXACT`.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- `grep -rn "cres" scripts/build.sh` returns no matches.
- `grep -rn "cres" silen-installer/src/` returns no matches.
- `grep -rn "cres" installer/` returns no matches.
- cres is a separate Go package manager (`/home/vgz/silen/SilenLinux/cres/`) with its own index (`cres/index.json`, 261 packages), dependency resolver (`cres/internal/dependency/resolver.go`), and installer (`cres/internal/installer/installer.go`).
- `spk` (Rust) is the only package manager built into the ISO and installed to `/usr/bin/spk`.
- cres and spk have divergent indexes (`cres/index.json` vs `spk-pkgs/index-entries.json`), different archive handling, and different config formats (`/etc/silen/config.lua` vs `SPK_BASE_URL`).

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh` (no cres references)
- `/home/vgz/silen/SilenLinux/installer/` (no cres references)
- `/home/vgz/silen/SilenLinux/spk/src/get.rs` (cres not in SYSTEM_EXACT)
- `/home/vgz/silen/SilenLinux/cres/` (complete standalone package manager)

**Suggested correction:** Finding is correct. The question of whether cres is "replacing" spk is not answered by code — cres exists in parallel with no integration path, no migration story, and no shared database.


### 2.4. Package JSON Validity / Dependencies — PARTIALLY CONFIRMED

**Original finding (implied in multiple reports):**
> cres index uses `checksum` field (v2 compliant), package dependencies are declared.

**Conclusion: PARTIALLY CONFIRMED**

**Technical reasoning:**
- All cres index entries inspected use `checksum` (64 hex sha256), matching `docs/package-schema.md` v2 requirements.
- Entries include `deps` arrays with constraint strings (e.g., `"wl-libs"`, `"mesa"`).
- Sample entries verified:
  - `instantwm` (line 984): `system: true`, deps include `seatd`, `dbus`, `wl-libs`, `gtk-libs`, `mesa`, `xorg-libs`, `xkb-data`, `seatd`, `vulkan-loader`, `xwayland`, `cursor-theme`, `instantmenu`, `instantcli`, `dejavu`, `noto-fonts`, `nerd-symbols`, `foot`, `instantmenu-extras`, `silen-audio`.
  - `sddm` (line 2060): `system: true`, deps include `dm-openrc`, `xorg-server`, `xorg-libs`, `xorg-drivers`, `xinit`, `dejavu`, `libglvnd`, `mesa`, `elogind`.
  - `elogind` (line 495): `system: true`, no deps.
  - `seatd` (line 2082): `system: true`.
  - `libinput` (line 1263): present.
- **However:** Not all 261 entries were validated. Some entries may be missing required fields (`name`, `version`, `checksum`, `url`). The package-schema.md states placeholder checksums are rejected, but this was not verified against all entries.
- The `spk` package manager (`spk/src/get.rs`) does not read cres indexes and vice versa — no cross-validation possible.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/cres/index.json` (261 packages, spot-checked ~10 entries)
- `/home/vgz/silen/SilenLinux/docs/package-schema.md` (v2 schema definition)
- `/home/vgz/silen/SilenLinux/spk/src/get.rs` (spk, separate from cres)

**Suggested correction:** Finding is correct but scope-limited. Full validation of all 261 cres entries was not performed. The two package managers cannot validate each other's packages.

---

### 2.5. Rust GUI vs Bash Installer Differences — CONFIRMED

**Original finding (clint_report, final_audit):**
> The Rust GUI omits SDDM setup, syslogd/klogd, busybox ntpd, bootlogd, fstrim, microcode image, resume-offset cmdline, installed-initramfs rebuild, and target-scripts copy.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- Rust `do_install` (backend.rs:1053) calls: `do_partition` → mount → tarball extract → `fix_permissions` → bind mounts → resolv.conf/hostname → chpasswd → fstab → `apply_settings` → ldconfig → `install_modules` → `install_spk` → `install_network` → `install_nvidia_auto` → `create_user` → `install_branding` → GRUB → cleanup.
- Rust `do_install` does NOT call any equivalent of bash `install-extras` (which does `install-busybox-tools`, `install-log-services`, `install-ntp-service`, `install-bootlogd`, `install-fstrim-service`, `install-efibootmgr`, `install-display-manager`, `build-microcode-image`, `compute-resume-params`, `build-installed-initramfs`).
- Rust `do_install` does NOT call any equivalent of bash `install-target-scripts` (copies `/mnt/target-scripts/*` to `/usr/local/bin/`).
- Bash `70-payloads.sh:69` does `rc-update add udev sysinit`; Rust `install_modules` also does this (confirmed in backend.rs).
- **Critical divergence:** Bash enables SDDM service via `install-display-manager` (75-extras.sh) and creates sddm user/group + `/var/lib/sddm` (70-payloads.sh:332-350). Rust does none of this.
- **Critical divergence:** Bash copies target-scripts (diagnostics like `silen-wifi-check`, `silen-nvidia-check`); Rust does not.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:1053` (`do_install`)
- `/home/vgz/silen/SilenLinux/installer/lib/75-extras.sh` (`install-extras`, `install-display-manager`)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh:332-350` (sddm user/group, /var/lib/sddm)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh:539-548` (`install-target-scripts`)

**Suggested correction:** Finding is correct. The two installers produce materially different installed systems, which is a significant reliability issue.


### 2.6. Disk and Partition Safety — CONFIRMED (Rust), CONFIRMED (Bash has protections)

**Original finding (clint_report):**
> Rust `list_disks()` does not robustly exclude partitions. Partitions such as `sda1` can be offered as wipe targets.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- `list_disks()` (backend.rs:87-130): When a name ends with a digit but does NOT contain 'p' (e.g., `sda1`), the code checks if `/sys/block/sda1/device` exists. Partitions DO have this sysfs entry, so the condition is false and the code does NOT `continue`. The partition `sda1` falls through and is added to the disk list.
- If `/dev/sda1` is selected as the "disk", `part_devs()` (backend.rs:304) returns `/dev/sda11` and `/dev/sda12` (treating the partition as a disk), and `sfdisk` writes a GPT table to the partition — destroying its filesystem.
- Bash `30-partition.sh` correctly skips partitions with `case "$d" in *p[0-9]*) continue ;; esac` for p-suffixed names, and the glob patterns `/dev/sd[a-z]` etc. only match base disks (no digits).
- Rust's additional fallback loop iterates `/dev/sd[a-z]` through `/dev/sd[z]` which also only matches base disks, but the `/sys/block` enumeration path is the buggy one.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:87-130` (`list_disks()`)
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:304-311` (`part_devs()`)
- `/home/vgz/silen/SilenLinux/installer/lib/30-partition.sh:104-113` (bash disk enumeration — correct)

**Suggested correction:** Finding is correct. The Rust `list_disks()` must skip any name ending in a digit unconditionally (or verify it's not a partition via `/sys/block/<name>/partition` or by checking if a parent disk exists).

---

### 2.7. OpenRC Boot and Service Configuration — CONFIRMED (with corrections)

**Original finding (clint_report, final_audit):**
> dbus/iwd configured; SDDM dead service (written but binary not installed); no seat manager.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- Both installers enable `dbus`, `iwd`, `modules`, `local` via `rc-update add`.
- Bash `75-extras.sh:14-50` writes `/etc/init.d/sddm` and `/etc/conf.d/sddm`, enables sddm only if binary exists.
- Bash `70-payloads.sh:332-350` creates sddm user/group and `/var/lib/sddm`.
- **No sddm binary is installed during offline install** — neither tarball nor payloads include sddm. It must be installed post-reboot via `spk get sddm` (requires network).
- **No seat manager installed:** `elogind` is in spk's `SYSTEM_EXACT` (line 55 of get.rs) and in cres index, but neither installer pulls it during offline install. Without seatd/elogind, SDDM/greetd cannot manage sessions, and InstantWM's DRM backend lacks seatd.
- Rust GUI does not configure any OpenRC services beyond dbus/iwd/modules/local (confirmed in `do_install`).
- Bash `install-modules` (70-payloads.sh:69) does `rc-update add udev sysinit`, but **no udevd binary is installed into the target**. The udev OpenRC service will fail on first boot because `/usr/bin/udevd` doesn't exist in the target.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/installer/lib/75-extras.sh:14-50` (SDDM service)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh:332-350` (sddm user/group)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh:69` (rc-update add udev sysinit)
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:1053` (do_install — no udev binary install, no seat manager)

**Suggested correction:** Finding is correct. Add: "udev OpenRC service is enabled but udevd binary is not installed into target — service will fail on first boot." Also: "No seat manager (seatd/elogind) installed — graphical login and InstantWM DRM input will not function."

---

### 2.8. InstantWM Installation and Startup — CONFIRMED (live only)

**Original finding (clint_report, final_audit):**
> InstantWM is live-ISO-only; not installed into target system.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- `scripts/build.sh` unpacks instantwm + Wayland stack into live ramroot (line 899-904) and writes `silen-live-wayland` (line 1051) which auto-launches instantwm.
- `rootfs/init` auto-starts instantwm Wayland session as root, no login.
- Rust `do_install` has **no instantwm payload** — no copy of instantwm binary, no Wayland session files, no seatd, no libinput.
- Bash `70-payloads.sh` / `75-extras.sh` have **no instantwm installation**.
- `spk`'s `SYSTEM_EXACT` includes `instantwm` and `instantwmctl` (line 28), so `spk get instantwm` would install it as a system package post-reboot — but this requires network which is not pre-configured.
- cres index has `instantwm` with `system: true` and deps including `seatd`, `dbus`, `wl-libs`, etc.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh:897-911` (instantwm staged into live)
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh:1051-1060` (`silen-live-wayland`)
- `/home/vgz/silen/Silen-Linux_gui/rootfs/init` (auto-starts instantwm live)
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:1053` (`do_install` — no instantwm)

**Suggested correction:** Finding is correct. If InstantWM is advertised as the default WM, it must be installed during offline install along with seatd and libinput, or the documentation must explicitly state "installed system boots to tty only."


### 2.9. iwd Networking — CONFIRMED

**Original finding (clint_report):**
> iwd binary copied from live (fails if NO_WIFI=1); no networks pre-configured; DNS conflict with static resolv.conf.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- Rust `install_network` (backend.rs:744): Copies iwd/iwctl/iwmon from live system or unpacks `network.tar.*`. If `NO_WIFI=1` was used to build the ISO, iwd is absent from live, so the target gets an iwd init script pointing to a non-existent binary.
- Writes `/etc/iwd/main.conf` with `EnableNetworkConfiguration=true`.
- `rc-update add iwd default` — iwd starts on boot but no networks are pre-configured.
- Installer writes static `1.1.1.1`/`9.9.9.9` to `/etc/resolv.conf`, but iwd with `EnableNetworkConfiguration=true` may overwrite it — DNS split-brain.
- No dhcpcd or wired network OpenRC service installed despite docs referencing dhcpcd for wired.

**Relevant files:**
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:744-809` (`install_network`)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh` (bash equivalent)

**Suggested correction:** Finding is correct. Add: "No wired network service (dhcpcd) installed despite documentation claiming wired uses dhcpcd."

---

### 2.10. SDDM and Graphical Session Dependencies — CONFIRMED

**Original finding (clint_report, final_audit):**
> SDDM service is effectively dead code on installed system; no greeter configured; no seat manager.

**Conclusion: CONFIRMED**

**Technical reasoning:**
- Bash writes SDDM OpenRC service but only enables it if sddm binary exists (it doesn't after offline install).
- No greeter (theme, autologin, greeter-session) configured.
- `greetd`/`tuigreet` packages exist (`mkspk-greetd.sh`) but are not wired into any installer path.
- No seat manager (seatd/elogind) installed during offline install.
- `sddm` in cres index has deps: `dm-openrc`, `xorg-server`, `xorg-libs`, `xorg-drivers`, `xinit`, `dejavu`, `libglvnd`, `mesa`, `elogind` — all required for SDDM to function, none installed.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/installer/lib/75-extras.sh:14-50` (SDDM service)
- `/home/vgz/silen/SilenLinux/cres/index.json:2060` (sddm deps)

**Suggested correction:** Finding is correct.

---

### 2.11. Swapfile — CONFIRMED in both (resolves kilo/clint contradiction)

**Original finding (kilo vs clint contradiction):**
> Kilo reported swapfile creation as potentially missing; Clint verified it exists.

**Conclusion: CONFIRMED (clint was right)**

**Technical reasoning:**
- Bash `60-system.sh:129-138` (`install-swapfile`): creates `/swapfile` via `fallocate`/`dd`, `chmod 600`, `mkswap`; sets `made_swapfile="1"`.
- Bash `40-base.sh:103-105`: appends `/swapfile none swap sw 0 0` to fstab if `made_swapfile` set.
- Rust `backend.rs:482-483` (`apply_settings`): `fallocate -l $want_swap /swapfile && chmod 600 /swapfile && mkswap /swapfile`.
- Rust `backend.rs:1127-1131` (`do_install`): appends swapfile entry to fstab if `/swapfile` exists.
- Both implement swapfile creation with different mechanisms. They must stay in sync.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/installer/lib/60-system.sh:129-138`
- `/home/vgz/silen/SilenLinux/installer/lib/40-base.sh:103-105`
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:482-483`
- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs:1127-1131`

**Suggested correction:** The final_audit correctly resolved this. No change needed.


---

## 3. Contradictions Between Reports

| Issue | kilo_report | clint_report | final_audit | Verification |
|-------|------------|--------------|-------------|-------------|
| udev staging | Critical defect (build.sh:503) | Not mentioned | Repeats as Critical | **INCORRECT** — code doesn't exist |
| swapfile | Potentially missing | Implemented in both | Resolved: implemented | clint correct |
| cres | Not covered | Not integrated | Not integrated | clint correct |
| Installer divergence | Not covered | Confirmed | Confirmed | clint correct |
| InstantWM target | Not covered | Live-only | Live-only | clint correct |
| SDDM dead service | Not covered | Confirmed | Confirmed | clint correct |
| Disk partition safety | Not covered | Rust bug confirmed | Confirmed | clint correct |

**Key contradiction resolved:** The udev finding in kilo_report/final_audit is factually wrong. Line 503 of build.sh is a git-core helper library copy, not udev. There is no udevd binary staging and no udev startup gate in rootfs/init.

---

## 4. Missing Critical Issues (Overlooked by Both Reports)

### 4.1. No udevd binary installed into target system
Both installers enable the udev OpenRC service (`rc-update add udev sysinit`), but neither installs the udevd binary into the target. On first boot, OpenRC will attempt to start udev and fail silently (`|| true`). This affects device management, firmware loading, and input device enumeration.

**Files:** `installer/lib/70-payloads.sh:69`, `silen-installer/src/backend.rs` (install_modules)

### 4.2. No seat manager installed into target
`seatd` and `elogind` are in spk's `SYSTEM_EXACT` and cres index, but neither installer pulls them during offline install. Without a seat manager, InstantWM's DRM backend cannot acquire input devices, and SDDM/greetd cannot manage graphical sessions.

**Files:** `spk/src/get.rs:30` (seatd in SYSTEM_EXACT), `silen-installer/src/backend.rs:1053` (do_install — no seat manager)

### 4.3. No libinput installed into target
`libinput` is in cres index and spk's SYSTEM_EXACT (via `xf86-input-libinput` prefix), but not installed during offline install. InstantWM's libinput code path will have no input devices to read from.

**Files:** `spk/src/get.rs:42` (`xf86-input-libinput`), `cres/index.json:1263` (libinput entry)

### 4.4. No wired network service despite documentation
Docs state "wired uses dhcpcd" but neither installer installs dhcpcd or a wired network OpenRC service. A system with only Ethernet and no Wi-Fi will have no network after install.

**Files:** `installer/lib/70-payloads.sh` (no dhcpcd service), docs (claims dhcpcd for wired)

### 4.5. udev service enabled but binary missing (target)
Same as 4.1 but emphasizing: `rc-update add udev sysinit` runs in both installers, but `/usr/bin/udevd` or `/usr/libexec/udevd` is never copied into `/silen`. First-boot OpenRC will fail to start udev.

### 4.6. GRUB `console=ttyS0` hardcoded
The kernel command line in both installers includes `console=ttyS0`, which is unnecessary for most hardware and can cause boot messages to go to a non-existent serial port.

**Files:** `silen-installer/src/backend.rs:1045`, `installer/lib/90-grub.sh`

---

## 5. Dependencies Between Fixes (Implementation Order)

The recommended implementation order in `final_audit.md` section 6 is generally sound but has dependency issues. Here is the corrected order with dependency analysis:

### Step 1: Fix Rust disk partition exclusion (CRITICAL — data loss)
- **Dependency:** None. Standalone fix.
- **Risk if delayed:** Any install using the Rust GUI could destroy data on a partition selected as a "disk."
- **Must precede:** Any installer unification work (the disk list is shared code).

### Step 2: Add udevd binary to target / fix udev service (CRITICAL — boot)
- **Dependency:** None, but related to Step 5 (seat manager).
- **Risk if delayed:** First boot fails to start device manager; input, firmware, and device events broken.
- **Note:** The kilo_report's "fix udev staging in build.sh" is wrong — the fix is in the installer (copy udevd into `/silen`), not in build.sh.

### Step 3: Install seatd + libinput into target (HIGH — graphical session)
- **Dependency:** Step 2 (udev for device events) — seatd/libinput need udev for proper device tagging.
- **Risk if delayed:** InstantWM DRM backend has no input; SDDM/greetd cannot manage sessions.
- **Must precede:** Step 5 (desktop/WM installation).

### Step 4: Unify installer frontends (HIGH — determinism)
- **Dependency:** Step 1 (disk list fix), Step 2 (udev fix), Step 3 (seat manager).
- **Risk if delayed:** GUI and bash installs continue producing different systems.
- **Approach:** Either port `install-extras` + `install-target-scripts` into Rust `do_install`, or make Rust a wrapper around bash libs.

### Step 5: Decide on package manager (cres vs spk) (HIGH — architectural)
- **Dependency:** None technical, but affects all package-related fixes.
- **Risk if delayed:** Two divergent package managers with no linkage cause confusion and breakage.
- **Note:** cres is not "replacing" spk — they are parallel systems. Decision: either integrate cres fully (build into ISO, wire into installer, unify indexes) or remove cres and standardize on spk.

### Step 6: Install InstantWM + DM + seat manager into target (HIGH — advertised feature)
- **Dependency:** Step 3 (seatd/libinput), Step 5 (package manager for spk/cres install).
- **Risk if delayed:** Installed system boots to tty only despite InstantWM being advertised as default WM.
- **Files:** `do_install` needs to install instantwm, seatd, and either sddm or greetd + greeter.

### Step 7: Add error fatality and rollback (MEDIUM — reliability)
- **Dependency:** Step 4 (installer unification — error handling should be unified).
- **Risk if delayed:** Partial installs leave half-configured systems with no recovery path.

### Step 8: Fix iwd/wired network (MEDIUM — first-boot usability)
- **Dependency:** Step 5 (package manager for dhcpcd/iwd install) or Stage 6.
- **Risk if delayed:** First boot has no network; `spk get` cannot work post-reboot.

### Step 9: Minor fixes (LOW)
- GRUB `console=ttyS0` removal
- `/etc/hosts` hostname entry
- `/etc/machine-id` at install time
- Rust `unicode.pf2` font copy (parity with bash)


---

## 6. Corrected Recommended Implementation Order

1. **Fix Rust `list_disks()` partition exclusion** — prevent data-loss on partition-as-disk selection. Standalone, no dependencies.
2. **Install udevd binary into target** — fix the udev OpenRC service that's enabled but has no binary. Copy udevd into `/silen` during install (both frontends).
3. **Install seatd + libinput into target** — required for InstantWM DRM input and any graphical DM. Depends on udev being functional.
4. **Unify installer frontends** — port missing `install-extras` and `install-target-scripts` into Rust `do_install`, or make GUI a bash wrapper. Depends on fixes 1-3 being incorporated into the unified path.
5. **Decide cres vs spk** — either integrate cres fully into build/installer or remove it. Architectural decision, affects all package-related work.
6. **Install InstantWM + DM (sddm or greetd) + greeter into target** — so the installed system boots to a graphical session as advertised. Depends on fixes 3-5.
7. **Add error fatality and rollback** — critical install steps should abort on failure; partial installs should leave consistent state. Depends on frontend unification.
8. **Fix iwd / wired network** — install dhcpcd or ensure iwd binary is present even when NO_WIFI=1; pre-configure network or document iwctl requirement. Depends on package manager decision.
9. **Minor polish** — GRUB console=ttyS0, /etc/hosts, /etc/machine-id, unicode.pf2 parity.

---

## 7. Files Likely Affected (Corrected)

- `/home/vgz/silen/Silen-Linux_gui/silen-installer/src/backend.rs` — `list_disks()`, `do_install()`, `install_modules()`, `install_network()`, `install_spk()`
- `/home/vgz/silen/SilenLinux/installer/lib/30-partition.sh` — bash disk enumeration (reference for correct behavior)
- `/home/vgz/silen/SilenLinux/installer/lib/70-payloads.sh` — `install-modules`, udev sysinit, sddm user/group
- `/home/vgz/silen/SilenLinux/installer/lib/75-extras.sh` — `install-extras`, `install-display-manager`
- `/home/vgz/silen/SilenLinux/installer/lib/90-grub.sh` — GRUB install, console=ttyS0
- `/home/vgz/silen/Silen-Linux_gui/spk/src/get.rs` — SYSTEM_EXACT list
- `/home/vgz/silen/SilenLinux/cres/` — standalone package manager (integrate or remove)
- `/home/vgz/silen/Silen-Linux_gui/scripts/build.sh` — live ISO staging (NOT where udev fix belongs)
- `/home/vgz/silen/Silen-Linux_gui/rootfs/init` — live init (no udev gate to fix)

---

## 8. Summary of Corrections to Consolidated Report

| Item | final_audit says | Correction |
|------|-----------------|------------|
| udev staging defect | "Critical — verified" | **Remove entirely** — code does not exist |
| Live input unreliable | "High — consequence of udev defect" | Rephrase: "Live lacks udevd + seatd; input broken for InstantWM libinput/libseat" |
| cres replacing spk | "cres not integrated vs spk" | Clarify: cres is parallel, not replacing; no integration path exists |
| swapfile | "Resolved — implemented in both" | Correct |
| Installer divergence | "High — confirmed" | Correct |
| InstantWM target | "High — live only" | Correct |
| SDDM dead service | "High — confirmed" | Correct |
| Disk partition safety | "Critical — confirmed" | Correct |

---

**Verification complete.** All findings were checked against actual source code under `/home/vgz/silen/`. No source files were modified. No destructive operations were performed.

