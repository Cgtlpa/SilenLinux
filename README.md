# Silen Linux

A tiny live Linux. Packages everything in the initramfs: busybox, glibc, a
hand-picked set of kernel modules + firmware, the installer, and a shell.

The same initramfs also boots an *installed* system: when the kernel command
line has `root=...` it mounts that root and `switch_root`s into `/sbin/init`;
with no `root=` (the live ISO) it runs the installer instead.

## Folders

| Folder       | Contents                                                    |
|--------------|-------------------------------------------------------------|
| `boot/`      | the kernel (`vmlinuz`, currently the zen 7.2.4 build)        |
| `rootfs/`    | the live root staging tree: `init`, busybox, kernel modules |
| `installer/` | the installer script (`main.sh`)                            |
| `scripts/`   | the ISO build script (`build.sh`)                           |
| `build/`     | generated output (initramfs + ISO), safe to delete          |

## Usage

```
make iso      # or: ./scripts/build.sh
make qemu     # boot it in QEMU
make clean
```

`scripts/build.sh` options: `COMPRESS=gzip`, `AUTO_HOST=0`, `FULL=1` (see the
top of the script).

The live environment includes `git` and `curl` (with CA certificates for
https). If a `tarball-*.xz` / `stage3-*.tar.*` file is present next to the repo,
it is burned onto the ISO and the live system mounts the disc at `/mnt`, so the
tarball is reachable for installing.

The full kernel module tree + `vmlinuz` are packed into a single
`kernel-<version>.tar.zst` on the ISO. The installer untars it into the
installed system so the running kernel and its modules match. A module tree's
own `build/`/`source/`/`vmlinuz` entries are excluded.
