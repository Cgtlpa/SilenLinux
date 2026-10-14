#!/bin/bash
# packs the instantwm binary into a spk file
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-instantwm stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
INSTANT_SRC="${INSTANT_SRC:-/home/vgz/instantWM}"
INSTANT_BIN="${INSTANT_BIN:-}"

usage() {
	echo "usage: mkspk-instantwm.sh [--src DIR] [--bin PATH]" >&2
	echo "  builds the instantwm spk from a local instantWM checkout" >&2
	echo "  env: INSTANT_SRC=/path/to/instantWM INSTANT_BIN=/path/to/instantwm" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--src) INSTANT_SRC="$2"; shift 2 ;;
		--bin) INSTANT_BIN="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

if [[ -z "$INSTANT_BIN" ]]; then
	for cand in "$INSTANT_SRC/target/release/instantwm" /usr/local/bin/instantwm; do
		if [[ -x "$cand" ]]; then
			INSTANT_BIN="$cand"
			break
		fi
	done
fi
if [[ -z "$INSTANT_BIN" ]] || [[ ! -f "$INSTANT_BIN" ]]; then
	echo "  ERROR instantwm binary not found (INSTANT_SRC=$INSTANT_SRC)" >&2
	echo "  build it first: cd \$INSTANT_SRC && cargo build --release" >&2
	exit 1
fi

INSTANT_VERSION="$(grep -m1 '^version' "$INSTANT_SRC/Cargo.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
[[ -n "$INSTANT_VERSION" ]] || INSTANT_VERSION="0.5.0"

STAGE="$(mktemp -d /tmp/opencode/iwstage.XXXXXX 2>/dev/null || echo /tmp/opencode/iwstage.$$)"
mkdir -p "$STAGE" || exit 1
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/wayland-sessions" "$STAGE/usr/share/applications" "$STAGE/etc/skel/.config/instantwm" "$STAGE/usr/share/doc/instantwm" || exit 1

cp -a "$INSTANT_BIN" "$STAGE/usr/bin/instantwm" || exit 1
chmod 755 "$STAGE/usr/bin/instantwm" || exit 1
if command -v strip >/dev/null 2>&1; then
	strip "$STAGE/usr/bin/instantwm" 2>/dev/null || true
fi

if [[ -x "$INSTANT_SRC/target/release/instantwmctl" ]]; then
	cp -a "$INSTANT_SRC/target/release/instantwmctl" "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
	chmod 755 "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
	strip "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
elif [[ -x /usr/local/bin/instantwmctl ]]; then
	cp -a /usr/local/bin/instantwmctl "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
	chmod 755 "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
	strip "$STAGE/usr/bin/instantwmctl" 2>/dev/null || true
fi

if "$STAGE/usr/bin/instantwm" --print-config 2>/dev/null | head -n1 | grep -q .; then
	# ask the binary for its default config so the iso has one
	"$STAGE/usr/bin/instantwm" --print-config > "$STAGE/usr/share/doc/instantwm/config.toml.example" 2>/dev/null || true
	cp -a "$STAGE/usr/share/doc/instantwm/config.toml.example" "$STAGE/etc/skel/.config/instantwm/config.toml" 2>/dev/null || true
	if grep -q '^keybinds = \[\]' "$STAGE/usr/share/doc/instantwm/config.toml.example" 2>/dev/null; then
		sed -i 's|^keybinds = \[\]|keybinds = [{ modifiers = ["super", "shift"], key = "space", action = { spawn = ["instantmenu_run"] } }]|' "$STAGE/usr/share/doc/instantwm/config.toml.example" "$STAGE/etc/skel/.config/instantwm/config.toml" 2>/dev/null || true
	fi
fi

cat > "$STAGE/usr/share/wayland-sessions/instantwm.desktop" <<'EOF'
[Desktop Entry]
Name=instantwm
Comment=instantWM hybrid tiling window manager
Exec=instantwm --backend drm
Type=Application
DesktopNames=instantwm
EOF

cat > "$STAGE/usr/share/applications/silen-installer.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Silen Installer
Comment=Install Silen Linux
Exec=silen-installer
Icon=system-software-install
Terminal=false
Categories=System;
EOF

mkdir -p "$STAGE/usr/lib/spk" || exit 1
cat > "$STAGE/usr/lib/spk/postinstall" <<'EOF'
#!/bin/sh
[ "${SPK_USER_MODE:-0}" = "1" ] && exit 0
R="${SPK_ROOT:-/}"
[ -z "$R" ] && R="/"
seed_one() {
	src="$1"
	rel="$2"
	[ -f "$R$src" ] || return 0
	for h in "$R/root" "$R"/home/*; do
		[ -d "$h" ] || continue
		d="$h/$rel"
		[ -e "$d" ] && continue
		mkdir -p "$(dirname "$d")" 2>/dev/null || continue
		cp -a "$R$src" "$d" 2>/dev/null || continue
		chmod 644 "$d" 2>/dev/null || true
		if [ "$h" != "$R/root" ]; then
			chown --reference="$h" "$d" 2>/dev/null || true
			chown --reference="$h" "$(dirname "$d")" 2>/dev/null || true
		fi
	done
}
seed_one /usr/share/doc/instantwm/config.toml.example .config/instantwm/config.toml
exit 0
EOF
chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1

mkdir -p "$PKGDIR/instantwm" || exit 1
# bundle usr + etc into the spk, thats the whole package
_members=""
for _m in usr etc; do
	[ -e "$STAGE/$_m" ] || continue
	_members="$_members $_m"
done
[ -n "$_members" ] || { echo "  ERROR empty payload for instantwm"; exit 1; }
tar -czpf "$PKGDIR/instantwm/instantwm.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
_s="$(sha256sum "$PKGDIR/instantwm/instantwm.spk" | awk '{print $1}')"
printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [%s]}' "instantwm" "$_s" "$INSTANT_VERSION" '"wl-libs", "gtk-libs", "mesa", "xorg-libs", "xkb-data", "seatd", "vulkan-loader"' > "$PKGDIR/instantwm/package.json"
echo "instantwm $INSTANT_VERSION $(du -h "$PKGDIR/instantwm/instantwm.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true
