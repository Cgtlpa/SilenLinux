# Silen Linux Core System Audit Report

## Confirmed bugs

1. **udev never starts in the live environment.** `scripts/build.sh:503` copies the udevd binary to `/usr/bin/udevadm` instead of `/usr/bin/udevd`. As a result `/usr/bin/udevd` is never staged, and `rootfs/init` gates startup on `[ -x /usr/bin/udevd ]`, so udevd is skipped entirely. This breaks input device discovery, seatd/libinput enumeration, and D-Bus device events in the live session.
2. **`/usr/bin/udevadm` is actually udevd.** Because of the same mis-copy, the staged `udevadm` binary is udevd, so udevadm commands cannot run.
3. **Live keyboard/mouse input unreliable.** With no udev running, seatd/libinput cannot enumerate input devices even though the InstantWM (drm backend) compositor may start. `/dev/input` nodes come from devtmpfs, but no udev events fire to tag/seat them.
4. **Desktop payload is best-effort.** `scripts/build.sh` downloads spk packages from Hugging Face if missing; if `instantwm` or `foot` fail to stage, the live init falls back to the text installer. Not a crash, but degrades the live experience.
5. **No accidental systemd/NetworkManager dependency introduced.** Only an intentional elogind shim (`libsystemd.so.0 -> libelogind.so.0`) and a best-effort `rc-update del NetworkManager default` cleanup exist. iwd is built with `--disable-systemd-service`.

## Unverified hypotheses

- seatd started with `-g root` may fail if the root group lacks the expected permissions; needs runtime verification.
- InstantWM may depend on XKB compose data at `/usr/share/X11/locale`, which is only staged conditionally.
- GPU firmware is merged only into the ISO `firmware/` directory, not the initramfs; live KMS may fail without it (by design, but unverified on target hardware).
- Presence of `dhcpcd`/`udhcpc` in the live image depends on host staging and was not confirmed in this repo state.
- InstantWM startup path and input handling need an actual QEMU/boot test to confirm.

## Notes

- No changes were made during this audit.
- root password for future use: 2010.
" filePath="/home/vgz/silen/SilenLinux/audit_reports/kilo_report.md"