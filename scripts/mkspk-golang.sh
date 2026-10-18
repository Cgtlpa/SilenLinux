#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-golang stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

VERSION="${VERSION:-1.27.2}"
GOARCH="${GOARCH:-amd64}"
DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
SITE="https://go.dev/dl"

usage() {
	echo "usage: VERSION=1.27.2 mkspk-golang.sh" >&2
	exit 1
}

[ $# -eq 0 ] || usage

name=golang
file="go${VERSION}.linux-${GOARCH}.tar.gz"
mkdir -p "$DLDIR" "$PKGDIR/$name" || exit 1

[ -f "$DLDIR/$file" ] || curl -fL -o "$DLDIR/$file" "$SITE/$file" || { echo "  ERROR download failed: $SITE/$file"; exit 1; }
want="$(curl -fsSL "$SITE/?mode=json" | awk -v f="\"$file\"" 'BEGIN { RS = "{" } index($0, f) && match($0, /"sha256": *"[0-9a-f]+"/) { s = substr($0, RSTART, RLENGTH); sub(/.*"sha256": *"/, "", s); sub(/".*/, "", s); print s }')"
[ -n "$want" ] || { echo "  ERROR no sha256 for $file in $SITE/?mode=json"; exit 1; }
got="$(sha256sum "$DLDIR/$file" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "  ERROR sha256 mismatch for $file (want $want, got $got)"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp/opencode}/go.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp/opencode}/go.$$")"
mkdir -p "$work/stage/usr/local" "$work/x" || exit 1
tar -xzf "$DLDIR/$file" -C "$work/x"
mv "$work/x/go" "$work/stage/usr/local/go" || { echo "  ERROR no go/ dir in $file"; exit 1; }
find "$work/stage/usr/local/go" -type f -perm -111 \( -name '*.sh' -o -name '*.bash' -o -name '*.pl' -o -name '*.rc' \) -not -path '*/lib/wasm/*' -exec chmod 644 {} +
tar --sort=name -czf "$PKGDIR/$name/$name.spk" -C "$work/stage" usr || { echo "  ERROR tar failed"; exit 1; }
rm -rf "$work" 2>/dev/null || true

s="$(sha256sum "$PKGDIR/$name/$name.spk" | awk '{print $1}')"
printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s-r1", "category": "dev-lang", "depends": []}' "$name" "$s" "$VERSION" > "$PKGDIR/$name/package.json"
echo "$name $VERSION-r1 [dev-lang] $(du -h "$PKGDIR/$name/$name.spk" | cut -f1)"
