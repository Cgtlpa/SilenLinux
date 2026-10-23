#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-linux-headers stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
KVER="${KVER:-6.18.54-silen}"
KSRC="${KSRC:-/home/vgz/misc/kernel-build/linux-6.18.54}"

STAGE="$(mktemp -d /tmp/opencode/linux-headers.XXXXXX 2>/dev/null || echo /tmp/opencode/linux-headers.$$)"
mkdir -p "$STAGE" || exit 1

mkdir -p "$STAGE/usr/include" || exit 1

# Copy kernel uapi headers
cp -a "$KSRC/include/uapi/." "$STAGE/usr/include/" || exit 1

# Create asm symlink for x86_64
if [ -d "$STAGE/usr/include/asm-x86_64" ]; then
    ln -sfn asm-x86_64 "$STAGE/usr/include/asm" || exit 1
elif [ -d "$KSRC/include/uapi/asm-x86_64" ]; then
    cp -a "$KSRC/include/uapi/asm-x86_64/." "$STAGE/usr/include/asm/" || exit 1
fi

# Build package
tar -czpf "$PKGDIR/linux-headers/linux-headers.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/linux-headers/linux-headers.spk" | awk '{print $1}')"
printf '{"filename": "linux-headers.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [], "category": "sys-libs", "description": "Linux kernel headers %s"}' "$_s" "$KVER" "$KVER" > "$PKGDIR/linux-headers/package.json"
echo "linux-headers $KVER $(du -h "$PKGDIR/linux-headers/linux-headers.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true