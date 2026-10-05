#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! binpkg inject stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

TREE_ROOT="${1:-build/portage-work/root/stage3-tarball-silen}"
BINHOST="${BINHOST:-https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64}"
DLDIR="${DLDIR:-build/portage-work/binpkgs}"

GIT_PKG="dev-vcs/git/git-2.55.0-5.gpkg.tar"
TEXINFO_PKG="sys-apps/texinfo/texinfo-7.3-1.gpkg.tar"
NASM_PKG="dev-lang/nasm/nasm-3.02-1.gpkg.tar"
YASM_PKG="dev-lang/yasm/yasm-1.3.0-r2-1.gpkg.tar"
UNZIP_PKG="app-arch/unzip/unzip-6.0_p31-1.gpkg.tar"
ZIP_PKG="app-arch/zip/zip-3.0-r7-1.gpkg.tar"
BC_PKG="sys-devel/bc/bc-1.08.2-1.gpkg.tar"
NATSPEC_PKG="dev-libs/libnatspec/libnatspec-0.3.0-1.gpkg.tar"

[ -d "$TREE_ROOT/usr/bin" ] || { echo "  ERROR $TREE_ROOT is not an extracted system tree"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "  ERROR curl not found"; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "  ERROR readelf not found (binutils)"; exit 1; }

mkdir -p "$DLDIR" || { echo "  ERROR cannot create $DLDIR"; exit 1; }

for pkg in "$GIT_PKG" "$TEXINFO_PKG" "$NASM_PKG" "$YASM_PKG" "$UNZIP_PKG" "$ZIP_PKG" "$BC_PKG" "$NATSPEC_PKG"; do
	base="$(basename "$pkg")"
	if [ ! -f "$DLDIR/$base" ]; then
		echo "  fetching $base"
		curl -sSL --max-time 300 -o "$DLDIR/$base" "$BINHOST/$pkg" || { echo "  ERROR cannot download $pkg"; exit 1; }
	fi
	tmp="$(mktemp -d /tmp/silen-gpkg.XXXXXX 2>/dev/null || echo /tmp/silen-gpkg.$$)"
	mkdir -p "$tmp" || { echo "  ERROR cannot create $tmp"; exit 1; }
	tar -xf "$DLDIR/$base" -C "$tmp" --wildcards "*/image.tar.xz" || { echo "  ERROR cannot open $base"; exit 1; }
	img="$(find "$tmp" -name image.tar.xz | head -n 1)"
	[ -n "$img" ] || { echo "  ERROR no image in $base"; exit 1; }
	tar -xpf "$img" -C "$TREE_ROOT" --strip-components=1 || { echo "  ERROR cannot unpack $base"; exit 1; }
	rm -rf "$tmp" 2>/dev/null || true
done

if [ -f "$TREE_ROOT/usr/bin/bc-reference" ]; then
	ln -sf bc-reference "$TREE_ROOT/usr/bin/bc" 2>/dev/null || true
fi
if [ -f "$TREE_ROOT/usr/bin/dc-reference" ]; then
	ln -sf dc-reference "$TREE_ROOT/usr/bin/dc" 2>/dev/null || true
fi

if [ -L "$TREE_ROOT/usr/lib64/libgcc_s.so.1" ] && [ ! -e "$TREE_ROOT/usr/lib64/libgcc_s.so.1" ]; then
	_real=""
	for cand in "$TREE_ROOT"/usr/lib/gcc/*/*/libgcc_s.so.1; do
		[ -f "$cand" ] && [ ! -L "$cand" ] || continue
		_real="$cand"
		break
	done || true
	if [ -n "$_real" ]; then
		cp "$_real" "$TREE_ROOT/usr/lib64/libgcc_s.so.1" || { echo "  ERROR cannot repair libgcc_s"; exit 1; }
	else
		echo "  ERROR no real libgcc_s found to repair the dangling link"
		exit 1
	fi
fi

fail=0
for b in usr/bin/git usr/bin/makeinfo usr/bin/bc usr/bin/nasm usr/bin/yasm usr/bin/unzip usr/bin/zip usr/bin/natspec; do
	[ -e "$TREE_ROOT/$b" ] || continue
	for lib in $(readelf -d "$TREE_ROOT/$b" 2>/dev/null | grep -oE '\[lib[^]]+\]' | tr -d '[]' || true); do
		if [ ! -e "$TREE_ROOT/usr/lib64/$lib" ] && [ ! -e "$TREE_ROOT/usr/lib/$lib" ] && [ ! -e "$TREE_ROOT/lib64/$lib" ] && [ ! -e "$TREE_ROOT/lib/$lib" ]; then
			echo "  ERROR $b needs missing $lib"
			fail=1
		fi
	done || true
done || true
[ "$fail" = 0 ] || exit 1

echo "Done - binpkgs injected into $TREE_ROOT"
