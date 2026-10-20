#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-sddm stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
SDDM_VERSION="${SDDM_VERSION:-0.21.0-silen1}"
SDDM_PARTS="${SDDM_PARTS:-1}"
SDDM_BASE="${SDDM_BASE:-https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages/sddm}"
SDDM_SRC="${SDDM_SRC:-}"

[ -n "$SDDM_SRC" ] || SDDM_SRC="$DLDIR/sddm.spk"
mkdir -p "$DLDIR" "$PKGDIR/sddm" || exit 1

if [ ! -f "$SDDM_SRC" ]; then
	if [ "$SDDM_PARTS" = "1" ]; then
		echo "  fetching sddm.spk"
		curl -fsSL --max-time 600 -o "$SDDM_SRC" "$SDDM_BASE/sddm.spk" || { echo "  ERROR cannot fetch sddm.spk"; exit 1; }
	else
		_parts=""
		_i=0
		while [ "$_i" -lt "$SDDM_PARTS" ]; do
			_n="$(printf '%03d' "$_i")"
			_p="$DLDIR/sddm.spk.$_n"
			if [ ! -f "$_p" ]; then
				echo "  fetching sddm.spk.$_n"
				curl -fsSL --max-time 600 -o "$_p" "$SDDM_BASE/sddm.spk.$_n" || { echo "  ERROR cannot fetch sddm.spk.$_n"; exit 1; }
			fi
			_parts="$_parts $_p"
			_i=$((_i + 1))
		done
		cat $_parts > "$SDDM_SRC" || { echo "  ERROR cannot join sddm parts"; exit 1; }
	fi
fi

STAGE="$(mktemp -d /tmp/opencode/sddm.XXXXXX 2>/dev/null || echo /tmp/opencode/sddm.$$)"
mkdir -p "$STAGE" || exit 1
tar -xzf "$SDDM_SRC" -C "$STAGE" || { echo "  ERROR cannot unpack $SDDM_SRC"; rm -rf "$STAGE"; exit 1; }

rm -f "$STAGE/usr/lib64/libfontconfig.so.1" \
	"$STAGE/usr/lib64/libEGL.so.1" \
	"$STAGE/usr/lib64/libGLdispatch.so.0" \
	"$STAGE/usr/lib64/libOpenGL.so.0" \
	"$STAGE/usr/lib64/libGLX.so.0" 2>/dev/null || true

mkdir -p "$STAGE/etc/sddm.conf.d" "$STAGE/etc/local.d" "$STAGE/usr/lib/silen" "$STAGE/usr/lib/spk" "$STAGE/usr/bin" || exit 1
cat > "$STAGE/etc/sddm.conf.d/10-silen.conf" <<'EOF'
[General]
DisplayServer=x11
HaltCommand=/usr/bin/poweroff
RebootCommand=/usr/bin/reboot
InputMethod=

[X11]
ServerPath=/usr/bin/Xorg
DisplayCommand=/usr/share/sddm/scripts/Xsetup
DisplayStopCommand=/usr/share/sddm/scripts/Xstop
SessionCommand=/usr/share/sddm/scripts/Xsession
SessionDir=/usr/local/share/xsessions,/usr/share/xsessions

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/local/share/wayland-sessions,/usr/share/wayland-sessions
EOF
chmod 644 "$STAGE/etc/sddm.conf.d/10-silen.conf" || exit 1

cat > "$STAGE/usr/lib/silen/repair-libs.sh" <<'EOF'
#!/bin/sh
R="${SPK_ROOT:-/}"
[ "$R" = "/" ] && R=""
d="$R/usr/lib64"
[ -e "$d/libfontconfig.so.1.17.0" ] && ln -sf libfontconfig.so.1.17.0 "$d/libfontconfig.so.1"
[ -e "$d/libEGL.so.1.1.0" ] && ln -sf libEGL.so.1.1.0 "$d/libEGL.so.1"
[ -e "$d/libGLdispatch.so.0.0.0" ] && ln -sf libGLdispatch.so.0.0.0 "$d/libGLdispatch.so.0"
[ -e "$d/libOpenGL.so.0.0.0" ] && ln -sf libOpenGL.so.0.0.0 "$d/libOpenGL.so.0"
[ -e "$d/libGLX.so.0.0.0" ] && ln -sf libGLX.so.0.0.0 "$d/libGLX.so.0"
[ -e "$R/usr/bin/Xorg" ] && ln -sf Xorg "$R/usr/bin/X"
if [ -z "$R" ]; then
	command -v ldconfig >/dev/null 2>&1 && ldconfig >/dev/null 2>&1
else
	command -v ldconfig >/dev/null 2>&1 && ldconfig -r "$R" >/dev/null 2>&1
fi
exit 0
EOF
chmod 755 "$STAGE/usr/lib/silen/repair-libs.sh" || exit 1

cat > "$STAGE/usr/lib/spk/postinstall" <<'EOF'
#!/bin/sh
R="${SPK_ROOT:-/}"
[ -x "$R/usr/lib/silen/repair-libs.sh" ] && "$R/usr/lib/silen/repair-libs.sh"
exit 0
EOF
chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1

cat > "$STAGE/etc/local.d/silen-repair-libs.start" <<'EOF'
#!/bin/sh
[ -x /usr/lib/silen/repair-libs.sh ] && /usr/lib/silen/repair-libs.sh
EOF
chmod 755 "$STAGE/etc/local.d/silen-repair-libs.start" || exit 1

ln -sfn Xorg "$STAGE/usr/bin/X" || exit 1

tar -czpf "$PKGDIR/sddm/sddm.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/sddm/sddm.spk" | awk '{print $1}')"
printf '{"filename": "sddm.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": ["dm-openrc", "xorg-server", "xorg-drivers", "xinit"], "category": "x11-misc", "description": "SDDM display manager with X11 greeter config"}' "$_s" "$SDDM_VERSION" > "$PKGDIR/sddm/package.json"
echo "sddm $SDDM_VERSION $(du -h "$PKGDIR/sddm/sddm.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true
