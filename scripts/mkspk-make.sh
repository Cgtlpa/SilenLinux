#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-make stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
MAKE_VERSION="${MAKE_VERSION:-4.4.1-silen1}"

STAGE="$(mktemp -d /tmp/opencode/make.XXXXXX 2>/dev/null || echo /tmp/opencode/make.$$)"
mkdir -p "$STAGE" || exit 1

mkdir -p "$STAGE/usr/bin" || exit 1

# Copy make binary
cp -a /usr/bin/make "$STAGE/usr/bin/" || exit 1

# Build package
tar -czpf "$PKGDIR/make/make.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/make/make.spk" | awk '{print $1}')"
printf '{"filename": "make.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [], "category": "sys-devel", "description": "GNU Make %s"}' "$_s" "$MAKE_VERSION" "$MAKE_VERSION" > "$PKGDIR/make/package.json"
echo "make $MAKE_VERSION $(du -h "$PKGDIR/make/make.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true