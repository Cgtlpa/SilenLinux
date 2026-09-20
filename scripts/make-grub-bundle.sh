#!/bin/bash

set -e

GRUB_SRC="${GRUB_SRC:-$HOME/grub}"
OUT="grub-bundle/usr/local"

if [ ! -x "$GRUB_SRC/config.status" ]; then
	echo "ERROR: no configured GRUB build found at $GRUB_SRC"
	echo "Set GRUB_SRC to the path of your built GRUB tree."
	exit 1
fi

DEST="$(mktemp -d /tmp/grub-dest.XXXXXX)"
trap 'rm -rf "$DEST"' EXIT

echo "== Building GRUB bundle =="
echo "  source: $GRUB_SRC"

( cd "$GRUB_SRC" && make install DESTDIR="$DEST" ) >/tmp/grub-bundle-build.log 2>&1 || { echo "ERROR: make install failed see /tmp/grub-bundle-build.log"; exit 1; }

if [ -d "$DEST/usr/local" ]; then :; elif [ -d "$DEST/usr" ]; then
	mkdir -p "$DEST/usr/local"
	cp -a "$DEST/usr"/. "$DEST/usr/local/" 2>/dev/null || true
else
	echo "ERROR: make install produced nothing at $DEST/usr/local"
	exit 1
fi

rm -rf grub-bundle
mkdir -p grub-bundle
cp -a "$DEST/usr" grub-bundle/

if [ ! -f grub-bundle/usr/local/share/grub/unicode.pf2 ]; then
	if [ -f /usr/share/grub/unicode.pf2 ]; then
		mkdir -p grub-bundle/usr/local/share/grub
		cp /usr/share/grub/unicode.pf2 grub-bundle/usr/local/share/grub/unicode.pf2
	else
		echo "  ! no unicode.pf2 font bundled - grub-install will warn about the missing font"
	fi
fi

mkdir -p "$OUT/lib"
for _libdir in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
	for lib in libdevmapper.so.1.02 liblzma.so.5 libudev.so.1 libgcc_s.so.1 libefivar.so.1; do
		cp -a "$_libdir/$lib"* "$OUT/lib/" 2>/dev/null || true
	done
done
if command -v ldd >/dev/null 2>&1 && [ -x "$DEST/usr/local/bin/grub-install" ]; then
	ldd "$DEST/usr/local/bin/grub-install" 2>/dev/null | grep -o '/[^ ]*' | while IFS= read -r _l; do cp -a "$_l" "$OUT/lib/" 2>/dev/null || true; done
fi

echo "  bundle: $(du -sh grub-bundle | cut -f1)"
echo "  done - grub-bundle/ is ready; build the ISO with 'make iso'"
