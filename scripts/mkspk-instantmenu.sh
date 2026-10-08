#!/bin/bash
# packs the instantmenu binaries into a spk file
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-instantmenu stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
MENU_SRC="${MENU_SRC:-/home/vgz/instantMENU}"
MENU_BIN="${MENU_BIN:-}"

usage() {
	echo "usage: mkspk-instantmenu.sh [--src DIR] [--bin PATH]" >&2
	echo "  builds the instantmenu spk from a local instantMENU checkout" >&2
	echo "  env: MENU_SRC=/path/to/instantMENU MENU_BIN=/path/to/instantmenu" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--src) MENU_SRC="$2"; shift 2 ;;
		--bin) MENU_BIN="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

if [[ -z "$MENU_BIN" ]]; then
	for cand in "$MENU_SRC/target/release/instantmenu" /usr/local/bin/instantmenu; do
		if [[ -x "$cand" ]]; then
			MENU_BIN="$cand"
			break
		fi
	done
fi
if [[ -z "$MENU_BIN" ]] || [[ ! -f "$MENU_BIN" ]]; then
	echo "  ERROR instantmenu binary not found (MENU_SRC=$MENU_SRC)" >&2
	echo "  build it first: cd \$MENU_SRC && cargo build --release --locked" >&2
	exit 1
fi

MENU_VERSION="$(grep -m1 '^version' "$MENU_SRC/Cargo.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
[[ -n "$MENU_VERSION" ]] || MENU_VERSION="5.1.5"

STAGE="$(mktemp -d /tmp/opencode/imstage.XXXXXX 2>/dev/null || echo /tmp/opencode/imstage.$$)"
mkdir -p "$STAGE" || exit 1
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/doc/instantmenu" "$STAGE/usr/share/man/man1" || exit 1

cp -a "$MENU_BIN" "$STAGE/usr/bin/instantmenu" || exit 1
chmod 755 "$STAGE/usr/bin/instantmenu" || exit 1
if command -v strip >/dev/null 2>&1; then
	strip "$STAGE/usr/bin/instantmenu" 2>/dev/null || true
fi

for _helper in instantmenu_path instantmenu_run instantmenu_smartrun; do
	# the little launcher helpers live next to the main binary
	if [[ -f "$MENU_SRC/$_helper" ]]; then
		cp -a "$MENU_SRC/$_helper" "$STAGE/usr/bin/$_helper" || exit 1
		chmod 755 "$STAGE/usr/bin/$_helper" || exit 1
	fi
done
[[ -f "$MENU_SRC/instantmenu.1" ]] && cp -a "$MENU_SRC/instantmenu.1" "$STAGE/usr/share/man/man1/" || true

mkdir -p "$PKGDIR/instantmenu" || exit 1
# bundle it up, same deal as the other mkspk scripts
_members=""
for _m in usr etc; do
	[ -e "$STAGE/$_m" ] || continue
	_members="$_members $_m"
done
[ -n "$_members" ] || { echo "  ERROR empty payload for instantmenu"; exit 1; }
tar -czpf "$PKGDIR/instantmenu/instantmenu.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
_s="$(sha256sum "$PKGDIR/instantmenu/instantmenu.spk" | awk '{print $1}')"
printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [%s]}' "instantmenu" "$_s" "$MENU_VERSION" '"wl-libs", "xorg-libs", "xkb-data"' > "$PKGDIR/instantmenu/package.json"
echo "instantmenu $MENU_VERSION $(du -h "$PKGDIR/instantmenu/instantmenu.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true
