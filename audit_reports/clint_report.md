# Silen Linux Installation Audit

## Scope and Methodology

Files audited (all under `/home/vgz/silen/`):
- Rust/egui graphical installer: `Silen-Linux_gui/silen-installer/src/main.rs`, `src/backend.rs`, `Cargo.toml`
- Bash whiptail fallback installer: `SilenLinux/installer/main.sh` + `installer/lib/{00-common,10-medium,20-ui,30-partition,40-base,50-settings,60-system,70-payloads,75-extras,90-grub}.sh`
- `spk` package manager (the runtime package manager actually shipped): `Silen-Linux_gui/spk/src/{get,find,remove,upd}.rs`
- `cres` (Go package manager, claimed as part of the ecosystem): `SilenLinux/cres/{main.go,go.mod,index.json,internal/cli/cli.go,internal/dependency/resolver.go,internal/installer/installer.go}`, `docs/package-schema.md`
- ISO/live desktop builder: `Silen-Linux_gui/scripts/build.sh` (key ranges), `mkspk-instantwm.sh`, `mkspk-greetd.sh`, `rootfs/init`
- `AGENTS.md`, `README.md` for architectural claims

**Constraint honored:** no destructive commands, no disk modification, no file changes. All analysis is static/read-only.

---

## 1. Rust/egui Graphical Installer (`silen-installer/`)

### Genuinely implemented
- Wizard flow: `Loading → Welcome → Disk → Settings → Confirm → Installing → Done`, running the actual install on a background thread so the UI never freezes.
- `--preview` mode (no root, browse only), `--cli` checklist mode (disks, medium, EFI), root requirement enforced at UI and `do_install` time.
- `Confirm` page requires an explicit "I understand the selected disk will be wiped" checkbox before "Install now (wipe disk)" is enabled.
- Disk list, hostname/root-pass/user/locale/keymap/timezone/filesystem/swapfile collection, progress log pane, Reboot/Back-to-start buttons.
- Full `do_install` orchestrator: partition → mount root+boot → find+extract tarball (with single-top-dir detection and `--strip-components=1`) → fix permissions → bind-mount proc/sys/dev/run → write resolv.conf/hostname/fstab → root password → apply settings → ldconfig → install modules → install spk → install network → NVIDIA auto → create user → branding → GRUB → cleanup.

### Issues / incomplete
- **The Rust GUI is a strict subset of the bash installer.** It does NOT call the shell's `install-target-scripts` or `install-extras`, so the following never happen under the GUI: SDDM OpenRC service, syslogd/klogd, busybox ntpd, bootlogd, fstrim service, microcode image, installed-initramfs rebuild, resume-offset kernel cmdline, or copying `/mnt/target-scripts` (e.g. `silen-wifi-check`, `silen-nvidia-check`) to the target. The two installers produce **different installed systems**.
- `run()` captures nothing (stdin=null, stdout/stderr discarded) — failures are reported only as a `bool` with no diagnostics in the log.
- `do_install` does not abort on many non-fatal failures (chpasswd, ldconfig, useradd, password set); it logs and continues, potentially leaving a bootable-but-broken system.
- No rollback: if the install fails mid-way, `/silen` is left half-populated and partially mounted; `cleanup()` only unmounts.
- egui `Context` is cloned/moved across the install thread; while this pattern generally works, any repaint after the window is closed is a latent panic risk (not verified).
- The `create_user` path writes `sudoers.d/10-silen` and the wheel/sudo group logic even if `useradd` silently failed — a non-existent user can end up referenced by sudoers.


---

## 2. Disk Detection and Partitioning

### Genuinely implemented
- **Bash (`30-partition.sh`)**: enumerates only base disks (`/dev/sd[a-z]`, `vd`, `xvd`, `nvme[0-9]*n[0-9]*`, `mmcblk[0-9]*`), correctly skips partitions. Detects model/size/serial from sysfs and lsblk. SSD lock mechanism via `.silen-lock` (`lock-ssd.sh`/`unlock-ssd.sh`), `SILEN_ALLOW_LOCKED` override.
- Wipe-confirm dialog, medium-disk protection (`medium_on_disk` via `/run/silen-medium-dev` and mount source), Ventoy/loop/ISO-file boot support (`10-medium.sh` `rescan_medium`).
- `wipefs -a`, `sfdisk --no-reread` GPT (`label: gpt`, `, 1G, U` ESP, `, , L` root), `partprobe`/`blockdev --rereadpt`, partition node settlement polling, `mkfs.vfat -F 32 -n SILENBOOT` for ESP, `mkfs.ext4`/`mkfs.btrfs` for root with labels.
- Rust `part_devs()`: `nvme`/`mmcblk` → `p1`/`p2`; others → `1`/`2` naming.

### Unsafe disk handling / issues
- **Rust `list_disks()` does not robustly exclude partitions.** It skips names ending in a digit only if they contain `p`; otherwise it only continues when `/sys/block/<name>/device` is missing AND `/dev/<name>` is missing. Partitions such as `sda1` typically still expose a `device` sysfs entry, so they can be offered as install targets. `wipefs -a` + `sfdisk` on a partition = silent data loss. The bash and Rust disk lists **disagree**.
- `wipefs -a` result is discarded (`let _ = run(...)`) — a busy/protected disk can fail silently and `sfdisk` proceeds anyway.
- No check that the selected target disk isn't already mounted/in use beyond the medium-disk check.
- Single-disk, whole-disk-wipe only: no option to preserve existing partitions, select an existing root, or use LUKS/LVM. Full wipe is the only mode (by design, but should be explicit).


---

## 3. UEFI and ESP Handling

### Genuinely implemented
- UEFI-only: `is_efi()` checks `/sys/firmware/efi`; both installers refuse legacy boot (shell `poweroff -f`, Rust `Err`).
- ESP layout: 1 GiB FAT32 partition, GPT type `U` (EFI System), label `SILENBOOT`, mounted at `/silen/boot`.
- `setup_grub` copies `/mnt/boot/vmlinuz` and the first `initramfs.*` to `/silen/boot`, mounts `efivarfs`, runs `grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable` (with fallback to plain `grub-install`), then a second `--bootloader-id=Silen` pass.
- GRUB bundle from `/mnt/grub/usr/local` is copied into the target (`/usr/local`) so `grub-install` can run from the bundled GRUB.
- `efibootmgr` creates/sets the NVRAM boot entry (`\EFI\Silen\grubx64.efi` or `\EFI\BOOT\BOOTX64.EFI`) and sets it first in `BootOrder`, keyed off the ESP PARTUUID.
- `grub.cfg` uses `search --fs-uuid` + `linux /vmlinuz root=UUID=... rootwait loglevel=4 console=ttyS0 console=tty0`, `initrd /...`, verbose boot, `terminal_output gfxterm console` (never black screen).

### Issues / incomplete
- `--removable` writes only `\EFI\BOOT\BOOTX64.EFI`; on firmwares that ignore the removable path and where `efibootmgr`/efivars fail, there is **no guaranteed NVRAM entry**. The `efibootmgr` block is wrapped in `|| true` — boot-order failure is silent and the system may not boot.
- The second `grub-install --bootloader-id=Silen` result is also ignored (`|| true` / `_ = ...`) — its failure is not surfaced.
- `console=ttyS0` is hardcoded in the kernel cmdline (harmless on most PCs, odd on headless/serial-free hardware).
- Rust `setup_grub` does not copy the `unicode.pf2` font (the bash version does), so gfxterm font fallback behavior differs between installers.
- No `os-prober` / multi-OS detection (single-distro assumption — acceptable for this distro).
- GRUB config paths: `linux /vmlinuz` and `initrd /initramfs` are relative to the ESP root because `--boot-directory=/boot`. This is consistent with where files are copied, but fragile if the ESP mountpoint changes.

---

## 4. Filesystem Creation and Mounting

### Genuinely implemented
- `do_partition` formats ESP (FAT32) and root (ext4 default, btrfs optional) with labels `SILENBOOT`/`silenroot`.
- `do_install` mounts root to `/silen`, boot to `/silen/boot`, then bind-mounts `proc`, `sys`, `dev` (rbind), `run` (rbind) into the target so chroot operations (chpasswd, useradd, depmod, ldconfig, grub-install) work.
- `fstab` written by UUID for both `/` and `/boot` (root pass `0 1` for ext4 else `0 0`; boot `0 2`).
- `/etc/resolv.conf` handling: removes symlink, strips `127.0.0.53`, copies live `resolv.conf` if it has nameservers, else falls back to `1.1.1.1`/`9.9.9.9`.
- Swapfile: both installers now create `/swapfile` (`fallocate`/`dd` + `chmod 600` + `mkswap`) and append `/swapfile none swap sw 0 0` to fstab (Rust in `apply_settings`/`do_install`; bash in `60-system.sh` `install-swapfile`). Previously I suspected it was missing — it is implemented in both, though the bash `made_swapfile` flag and Rust `Path::exists()` check are two different mechanisms that must stay in sync.

### Issues / incomplete
- No `sync` or explicit wait between `mkfs` and `mount`; usually fine but not guaranteed on all block devices.
- btrfs offered as an option but no subvolume layout, no compression, no `noatime` — single flat `silenroot` volume.
- ext4 `nodiscard` used; no TRIM service configured unless the bash `install-extras` path runs (fstrim) — GUI installer skips it.


---

## 5. Package Downloading and Installation

### Genuinely implemented
- `spk` (Rust) is the package manager shipped on the ISO and installed to `/usr/bin/spk` in the target. Source: `spk/src/get.rs`.
- Offline install: the tarball, kernel bundle, headers, firmware, `network.tar.*`, and `spk.tar.*` are all expected on the install medium (`/mnt`). No network required during install.
- `spk get` downloads from `https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages`, verifies SHA-256, checks declared `size`, refuses `..`/symlink traversal, extracts system packages to `/` and leaf apps to isolated `/spk_pkgs/<name>` with shims in `/usr/local/bin` (or `~/.local/bin` with `--user`).
- Dependency resolver exists (constraints `>=`, `=`, `>`, `<`, `<=`; `provides`, `conflicts`, `replaces`; cycle detection; `--no-deps`, `--force`).
- Protected basenames never removed: `passwd`, `shadow`, `gshadow`, `group`, `fstab`, `machine-id`, `hostname`, `hosts`, `resolv.conf` (both spk remove and cres `isProtected`).
- `spk` is built into the ISO (`scripts/build.sh` stage `[5b/7]`, `spk/Cargo.toml`) and copied to `RAMROOT/usr/bin/spk`.

### Cres integration — NOT CONNECTED (major finding)
- `cres` is a **separate Go package manager** under `SilenLinux/cres/` with its own index format (`index.json` v2), its own dependency resolver, journal/backup/hook system, `cres install/remove/update/search/sync/build/publish/mkindex/doctor`.
- `cres` is **not** referenced anywhere in `scripts/build.sh`, **not** built into the ISO, **not** installed by either installer, and **not** in `spk`'s `SYSTEM_EXACT`. The two package managers (spk vs cres) have **divergent indexes** (`spk-pkgs/index-entries.json` vs `cres/index.json`, 261 packages), different archive handling, and different config formats (`SPK_BASE_URL` vs `/etc/silen/config.lua`).
- There is **no cres integration** in the installation path: no `cres` binary on the target, no `cres` repo configuration, no package pulled via cres during install. The `docs/package-schema.md` describes features (hooks, backups, conflicts, provides, `size` verification) that `spk` partially lacks and vice versa — the two systems do not agree.

### Issues / incomplete
- `install_spk` (Rust) and the bash equivalent silently succeed even when no `spk` binary is found on the medium or live system — the target ends up with **no package manager** and no error is surfaced. Post-install, the user literally cannot run `spk get`.
- `spk` is installed but its registry/database is not initialized; `spk list` shows nothing until packages are installed.
- No package downloads happen during install (fully offline by design); Wi-Fi/NIC drivers and firmware for the target hardware are not fetched unless pre-staged on the medium.


---

## 6. Installed System Configuration

### Genuinely implemented
- `/etc/hostname`, `/etc/conf.d/hostname` (OpenRC), `/etc/conf.d/keymaps`, `/etc/locale.gen` (single locale), `/etc/localtime` symlink to `/usr/share/zoneinfo/<zone>`.
- Root password via `chpasswd`; optional user with groups `wheel sudo audio video network plugdev`; `sudoers` (`root` + `%wheel NOPASSWD: ALL`, `@includedir sudoers.d`) and `sudoers.d/10-silen`; PAM `sudo`/`sudo-i` files; `bin/bash`/`bin/sh`/`bin/login` symlinks; suid fixes on `su`, `passwd`, `mount`, `sudo`, etc.; `shadow`/`gshadow` `640 root:shadow`; `tmp`/`var/tmp` `1777`.
- `ldconfig` run in target.
- Branding: `fastfetch` logo + `config.jsonc` in `/etc/fastfetch`, `/etc/xdg/fastfetch`, `/etc/skel`, `/root`; `/usr/local/bin/silenfetch` wrapper; `spk-help.txt` guide.
- Quiet boot: `rc_logger="YES"` in `/etc/rc.conf`, `--quiet` in `/etc/inittab`.
- `silen-wifi-check` / `silen-nvidia-check` diagnostics are target-scripts (bash path only; not in Rust GUI).

### Issues / incomplete
- **No `/etc/machine-id` is created during install.** The OpenRC `dbus` init script's `start_pre` runs `dbus-uuidgen --ensure` at first boot, so it is lazily created — but anything needing machine-id before dbus starts may fail.
- `resolv.conf`: static `1.1.1.1`/`9.9.9.9` written by installer, but iwd is configured with `EnableNetworkConfiguration=true`, which can rewrite `resolv.conf` — potential DNS conflict/race on first boot.
- Hostname sanitization differs slightly (Rust `sanitize_hostname` vs bash `tr` pipeline) — cosmetic only.
- No `/etc/hosts` entry for the hostname; no `127.0.1.1` mapping.

---

## 7. OpenRC Service Setup

### Genuinely implemented
- Bash `install-network` (also mirrored by Rust `install_network`): writes `/etc/init.d/dbus` (`dbus-daemon --system --fork`, machine-id handling) and `/etc/init.d/iwd` (backgrounded, `rfkill unblock all`, `provide net`); `rc-update add dbus default`, `rc-update add iwd default`, `rc-update add modules boot`, `rc-update add local default`.
- Bash `install-display-manager` (75-extras): `/etc/init.d/sddm` (`need dbus localmount`, `after bootmisc`, checkpath `/var/lib/sddm /run/sddm`), `/etc/conf.d/sddm`, `rc-update add sddm default` (only if sddm binary exists), `rc-update add dbus default`.
- Bash `install-extras` also adds: `syslogd`, `klogd`, busybox `ntpd`, `fstrim` (weekly), `bootlogd`, `sddm` group/user and `/var/lib/sddm` ownership.

### Issues / incomplete
- **Rust GUI installer does not configure any OpenRC services beyond dbus/iwd/modules/local.** SDDM, syslogd, ntpd, fstrim, bootlogd are never set up under the GUI. The installed system depends on which installer was used.
- **Seat management is missing.** SDDM/greetd need a seat manager (elogind, systemd-logind, or seatd). `AGENTS.md` explicitly states "elogind is not in this image" and suggests `spk get elogind` after reboot. Without a seat manager, a graphical display manager cannot start sessions properly — yet SDDM is enabled by default when its binary happens to exist.
- `rc-update add` calls are `|| true`'d; if OpenRC isn't functional in the target, service enablement fails silently.
- `iwd` is added to `default` runlevel but no network is actually configured — first boot has no connectivity until the user runs `iwctl`.


---

## 8. iwd Configuration

### Genuinely implemented
- `install_network` copies `iwd`, `iwctl`, `iwmon` binaries from the live system into `/usr/libexec` or `/usr/bin` in the target (fallback chain), or unpacks `network.tar.*` from the medium.
- Writes `/etc/iwd/main.conf` (copied from live or `[General]\nEnableNetworkConfiguration=true`), creates `/etc/iwd`, `/var/lib/iwd`, dbus system.d dir, copies `iwd-dbus.conf`.
- OpenRC `iwd` service: `command=/usr/libexec/iwd` (or `/usr/bin/iwd`), `command_background=yes`, `depend() { need dbus localmount modules; after bootmisc; provide net }`, `start_pre` creates `/var/lib/iwd` and `rfkill unblock all`.
- `rc-update add iwd default` so iwd starts on boot.

### Issues / incomplete
- Binary copy from the **live** system is fragile: if the live image was built `NO_WIFI=1`, iwd is absent and the target gets an `iwd` init script pointing at a non-existent binary — service fails silently on first boot.
- No known networks, no `iwctl` station configuration, no `eduroam`/WPA-Enterprise profiles — zero-touch Wi-Fi does not exist; user must manually run `iwctl` after first boot.
- DNS split-brain: installer writes static nameservers while iwd `EnableNetworkConfiguration=true` manages `resolv.conf`.
- `iw`/`wpa_supplicant`/`dhcpcd` are mentioned in docs (`wired uses dhcpcd`) but neither dhcpcd nor a wired-network OpenRC service is installed by the installer payload.

---

## 9. GRUB Installation

### Genuinely implemented
- Copies kernel + initramfs to `/silen/boot` (the ESP mount).
- `grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable`, then `--bootloader-id=Silen`.
- Generates `grub.cfg` with `search --fs-uuid`, `linux /vmlinuz root=UUID=...`, `initrd /...`, verbose console output, gfxterm+console terminal output, all video/EFI modules.
- `efibootmgr` NVRAM entry creation + `BootOrder` re-prioritization keyed on ESP PARTUUID; fallback to `\EFI\BOOT\BOOTX64.EFI` (removable path) if Silen entry missing.
- Logs to `/silen/tmp/grub-install.log` (copied to `/tmp/grub-install.log`); whiptail error on total failure.
- NVIDIA variant: appends `nvidia-drm.modeset=1 nvidia-drm.fbdev=1` to the kernel cmdline when `/mnt/nvidia-auto` and the disable-nouveau conf exist; includes `etc/local.d/nvidia-fallback.start` fail-safe.

### Issues / incomplete
- `--removable` + `--bootloader-id=Silen` both run; on some firmware the removable path is used and no NVRAM entry survives, and the boot-order step is silent-on-failure → machine may not boot after install.
- `grub-install` output is captured to a log but `stderr` is merged into the same file; no per-step distinction.
- Rust version skips font copy (`unicode.pf2`); bash version copies it. Divergent graphics fallback.
- No fallback entry, no `savedefault`, no multi-boot/os-prober, no password protection.


---

## 10. SDDM Configuration

### Genuinely implemented (bash path only)
- `install-display-manager` writes `/etc/init.d/sddm` and `/etc/conf.d/sddm` (`SDDM_ARGS=""`), enables `sddm` in default runlevel **only if** `/usr/bin/sddm` or `/usr/sbin/sddm` exists in the target.
- Creates `sddm` user/group and `/var/lib/sddm` (bash `70-payloads.sh`).

### Issues / incomplete
- **SDDM itself is never installed during the offline install.** No `sddm` package is in the tarball/payload. It must be installed post-reboot via `spk get sddm` (requires network). Until then `rc-update add sddm default` enables a service whose binary does not exist — boot noise, no effect.
- No greeter is configured (no theme, no autologin, no `greeter-session`). `greetd`/`tuigreet` packages exist (`mkspk-greetd.sh`) but are **not wired into any installer path**.
- As `AGENTS.md` admits: "Installed desktop: none — installed system is a clean base that boots to a tty login." So SDDM configuration is effectively dead code until the user installs a display manager + desktop + seat manager.
- Rust GUI installer does not configure SDDM at all.

---

## 11. InstantWM Default Session

### Genuinely implemented (LIVE ISO only)
- `mkspk-instantwm.sh` builds `instantwm` (and `instantwmctl`) into an `.spk` with `/usr/share/wayland-sessions/instantwm.desktop` (`Exec=instantwm --backend drm`), default `config.toml`, keybinds seeded, `/etc/skel` and `/root` config, default apps (kitty/yazi/instantmenu/swaylock/btm).
- `scripts/build.sh` unpacks instantwm + Wayland stack (instantmenu, wl-libs, mesa, xorg-libs, seatd, wlroots, pipewire, kitty, yazi, swaylock, etc.) into the live ramroot, merges host Mesa/DRI, sets `instantwm.desktop`, writes `silen-installer.desktop` and `silen-live-wayland` (compositor first, then installer, DRM backend, no login).
- `rootfs/init` auto-starts the live Wayland session under instantwm as root with no login, and auto-launches `silen-installer`.

### Not implemented (installed target)
- **InstantWM is NOT installed into the target system by either installer.** `do_install` has no instantwm payload. The installed system boots to a tty login with no WM/session. The user must `spk get instantwm` (and mesa/wl-libs/seatd/dbus) after reboot — requiring network that is not pre-configured.
- So "InstantWM default session" is a **live-demo feature, not an installed-system feature**. The claim that the installed system "just works" graphically is not true out of the box.

---

## 12. First Boot

### Genuinely implemented
- GRUB boots kernel from ESP via UUID; initramfs; OpenRC starts `modules`, `dbus`, `iwd`, `local` (+ `sddm` if binary present). Verbose `loglevel=4 console=tty0` so failures are visible.
- Root can log in on tty; optional user created during install with sudo (NOPASSWD wheel).
- `iwd` service starts; user runs `iwctl` to connect. `silenfetch` available if fastfetch installed.
- Reboot button in GUI calls `reboot -f`.

### Issues / not verified
- No first-boot wizard, no network auto-connection, no graphical session auto-start, no user creation at first boot.
- First boot on real hardware (various UEFI firmwares, NVMe vs SATA, Secure Boot) was **not verified** — no test was run, and `grub-install --removable` behavior varies by firmware.
- Secure Boot: no shim/MOK/SBAT handling; GRUB is unsigned. Systems with Secure Boot enabled will refuse to boot. Not mentioned anywhere.
- Whether `efibootmgr`/efivars work in the live environment was not verified.


---

## Cross-Cutting: Do the Installer and Installed System Agree?

| Area | Agreement? | Notes |
|------|-----------|-------|
| **Install root path** | ✅ | Both use `ROOT_PATH=/silen`. |
| **ESP mount** | ✅ | Both mount boot partition at `/silen/boot`; GRUB `--boot-directory=/boot`; `linux /vmlinuz` / `initrd /...` relative to ESP root. |
| **fstab** | ✅ | UUID-based `/` and `/boot` in both. |
| **OpenRC services** | ⚠️ Partial | dbus/iwd/modules/local agree; sddm/syslogd/ntpd/fstrim/bootlogd exist only in bash path. |
| **Package manager** | ⚠️ Partial | `spk` binary installed to `/usr/bin/spk`, but registry not initialized; silent failure if spk missing from medium. |
| **Package names** | ❌ Divergent | `spk SYSTEM_EXACT` list vs `cres` index — two separate repos/package sets, no cross-reference. |
| **Config formats** | ⚠️ Partial | OpenRC init.d/conf.d agree; iwd `main.conf` agrees; fastfetch `config.jsonc` agrees; cres uses `config.lua` (unused). |
| **Network deps** | ⚠️ Partial | iwd `need dbus` ordering agrees; but dhcpcd/wired network mentioned in docs is not installed by either installer. |
| **Desktop/DM** | ❌ Disagree | Bash writes sddm service but doesn't install sddm; instantwm/greetd not installed; GUI writes neither. |

**Key disagreement:** The Rust GUI and the bash fallback are **not feature-parallel**. The GUI omits SDDM, syslogd, ntpd, fstrim, bootlogd, target-scripts, microcode image, resume-offset, initramfs rebuild, and `install-target-scripts`. An installed system's services depend on which installer frontend was used.

---

## Findings Register

### Genuinely implemented (end-to-end, functional)
- UEFI-only gate; GPT ESP+root partitioning; FAT32 ESP + ext4/btrfs root; UUID fstab.
- Tarball extraction with top-dir stripping; bind mounts; hostname/rootpass/user/locale/keymap/timezone.
- `spk` package manager installed; offline kernel/firmware/network bundle install from medium.
- dbus + iwd OpenRC services; GRUB EFI install with NVRAM entry; verbose GRUB/cmdline.
- Swapfile creation + fstab entry (both frontends).
- Wipe-confirmation checkbox (GUI) / dialog (bash); medium-disk protection.
- Live ISO: instantwm Wayland desktop + auto-launched installer, no login.

### Incomplete (present but partial / one-sided / fragile)
- SDDM: service file written but binary not installed; no greeter; no seat manager (elogind absent by design).
- iwd: binary copied from live (fails if `NO_WIFI=1`); no networks pre-configured; DNS conflict with static `resolv.conf`.
- Cres: fully separate, unintegrated package manager; not built, shipped, or invoked anywhere in install.
- InstantWM: live only; not part of installed system.
- First boot: no wizard, no auto-network, tty-only by default.
- Error handling: many steps are `|| true` or logged-and-continue; no rollback on partial failure.

### Not verified (static analysis only; no live/QEMU/hardware run)
- `efibootmgr`/efivars functionality in the live environment; boot after install on real firmware; Secure Boot behavior; `grub-install --removable` reliability across firmwares.
- NVIDIA auto-install path (`nvidia.run` in chroot, `depmod`, fallback local.d).
- `spk get` over the network post-reboot (depends on HuggingFace reachability and index auth).
- `reboot -f` from the GUI.

---

## Highest-Priority Recommendations

1. **Unify the two installer frontends.** Either port `install-extras`, `install-target-scripts`, resume-offset, microcode, and initramfs rebuild into the Rust `do_install`, or make the GUI a thin wrapper around the bash libs. As-is, the installed system is non-deterministic depending on frontend.
2. **Fix disk-list partition exclusion** in Rust `list_disks()` so partitions (e.g. `sda1`, `nvme0n1p1`) can never be offered as wipe targets; check target disk isn't mounted before `wipefs`.
3. **Decide on one package manager.** Either ship and integrate `cres` (build it into the ISO, configure `/etc/silen/config.lua`, use it in the installer) or remove it and standardize on `spk`. Having two diverging package systems with no linkage is a real breakage risk (`spk` won't know about cres-installed packages and vice versa).
4. **Make the installed system boot to a working desktop or explicitly document tty-only.** If SDDM/instantwm are advertised, install `sddm` or `greetd`, a seat manager (elogind/seatd), and a WM during install, not only post-reboot via network.
5. **Add error fatality and rollback.** Critical steps (tarball extract, kernel copy, grub-install) should abort the install; non-critical ones should be clearly marked. On failure, offer to unmount and leave a consistent (even if empty) target rather than a half-installed system.
6. **Clarify first-boot network story.** Pre-populate iwd with a connection flow or document that `iwctl` is mandatory before any `spk` operation can work.

