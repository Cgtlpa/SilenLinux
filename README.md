# Silen Linux

A tiny live Linux. Packages everything in the initramfs: busybox, glibc, a
hand-picked set of kernel modules + firmware, the installer, and a shell.

## Folders

| Folder       | Contents                                                    |
|--------------|-------------------------------------------------------------|
| `boot/`      | the compiled kernel (`vmlinuz`)                             |
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
https). If a `stage3-*.tar.*` file is present next to the repo, it is burned
onto the ISO and the live system mounts the disc at `/mnt`, so the stage3
tarball is reachable at `/mnt/stage3-*.tar.*` for installing Gentoo.