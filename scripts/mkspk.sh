#!/bin/bash
# generic spk helper, fetch gpkgs and bundle them
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-build/spk-pkgs/dl}"
PKGDIR="${PKGDIR:-build/spk-pkgs/packages}"
BASESO="${BASESO:-/tmp/opencode/baseso.txt}"

usage() {
	echo "usage: mkspk.sh fetch <gpkg-path...> | assemble <name> <version> <category> <desc> <bins> <gpkg...> | manifest <name>" >&2
	exit 1
}

[ $# -ge 1 ] || usage
cmd="$1"
shift

case "$cmd" in
# fetch just downloads stuff, assemble packs it, manifest writes the json
fetch)
	mkdir -p "$DLDIR" || exit 1
	for pkg in "$@"; do
		base="$(basename "$pkg")"
		if [ ! -f "$DLDIR/$base" ]; then
			echo "  fetching $base"
			curl -sSL --max-time 600 -o "$DLDIR/$base" "$pkg" || exit 1
		fi
	done
	;;
assemble)
	[ $# -ge 6 ] || usage
	name="$1"
	version="$2"
	category="$3"
	desc="$4"
	bins="$5"
	shift 5
	stage="$(mktemp -d /tmp/opencode/stage.XXXXXX 2>/dev/null || echo /tmp/opencode/stage.$$)"
	mkdir -p "$stage" || exit 1
	mkdir -p "$stage/bin" "$stage/lib"
	for g in "$@"; do
		[ -f "$g" ] || g="$DLDIR/$(basename "$g")"
		[ -f "$g" ] || { echo "  ERROR gpkg missing: $g"; exit 1; }
		tmp="$(mktemp -d /tmp/opencode/gx.XXXXXX 2>/dev/null || echo /tmp/opencode/gx.$$)"
		mkdir -p "$tmp" || exit 1
		tar -xf "$g" -C "$tmp" 2>/dev/null
		img="$(find "$tmp" -name image.tar.xz -o -name image.tar.zst 2>/dev/null | head -n 1)"
		[ -n "$img" ] || { echo "  ERROR no image in $g"; exit 1; }
		for b in $bins; do
			f="$(tar -tf "$img" 2>/dev/null | grep -E "(^|/)bin/$b$" | head -n 1)"
			[ -n "$f" ] || continue
			tar -xpf "$img" -C "$tmp" "$f" 2>/dev/null || true
			cp -a "$tmp/$f" "$stage/bin/" 2>/dev/null || true
			chmod 755 "$stage/bin/$b" 2>/dev/null || true
		done
		while IFS= read -r lib; do
			[ -n "$lib" ] || continue
			tar -xpf "$img" -C "$tmp" "$lib" 2>/dev/null || true
			cp -a "$tmp/$lib" "$stage/lib/" 2>/dev/null || true
		done < <(tar -tf "$img" 2>/dev/null | grep -E "^image/usr/lib64/[^/]+\.so" | grep -v "\.a$" || true)
		rm -rf "$tmp" 2>/dev/null || true
	done
	mkdir -p "$PKGDIR/$name" || exit 1
	members=""
	for m in bin lib usr; do
		[ -e "$stage/$m" ] || continue
		members="$members $m"
	done
	[ -n "$members" ] || { echo "  ERROR empty payload for $name"; exit 1; }
	tar -czpf "$PKGDIR/$name/$name.spk" -C "$stage" $members || { echo "  ERROR tar failed"; exit 1; }
	rm -rf "$stage" 2>/dev/null || true
	s="$(sha256sum "$PKGDIR/$name/$name.spk" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": false, "version": "%s", "category": "%s"}' "$name" "$s" "$version" "$category" > "$PKGDIR/$name/package.json"
	echo "$name $version [$category] $(du -h "$PKGDIR/$name/$name.spk" | cut -f1)"
	;;
manifest)
	[ $# -ge 4 ] || usage
	name="$1"
	version="$2"
	category="$3"
	desc="$4"
	mkdir -p "$PKGDIR/$name" || exit 1
	f="$PKGDIR/$name/$name.spk"
	[ -f "$f" ] || { echo "  ERROR $f missing (build it first)"; exit 1; }
	s="$(sha256sum "$f" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": false, "version": "%s", "category": "%s"}' "$name" "$s" "$version" "$category" > "$PKGDIR/$name/package.json"
	echo "$name $version [$category] $(du -h "$f" | cut -f1)"
	;;
*)
	usage
	;;
esac
