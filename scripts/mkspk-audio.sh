#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-audio stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
BASEURL="${BASEURL:-https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64}"

usage() {
	echo "usage: mkspk-audio.sh pipewire|wireplumber|lua-libs|libasyncns|libpulse|silen-audio|sessions|all" >&2
	exit 1
}

[ $# -ge 1 ] || usage
cmd="$1"

mkdir -p "$DLDIR" "$PKGDIR" || exit 1

fetch_gpkg() {
	rel="$1"
	base="$(basename "$rel")"
	if [ ! -f "$DLDIR/$base" ]; then
		echo "  fetching $base"
		curl -fsSL --max-time 600 -o "$DLDIR/$base" "$BASEURL/$rel" || exit 1
	fi
	printf '%s\n' "$DLDIR/$base"
}

extract_gpkg() {
	gpkg="$1"
	SRC_TMP="$(mktemp -d /tmp/opencode/audio.XXXXXX)"
	tar -xf "$gpkg" -C "$SRC_TMP" || exit 1
	img="$(find "$SRC_TMP" -name image.tar.xz | head -1)"
	[ -n "$img" ] || { echo "  ERROR image.tar.xz missing in $gpkg"; exit 1; }
	mkdir -p "$SRC_TMP/root" || exit 1
	tar -xf "$img" -C "$SRC_TMP/root" || exit 1
	SRC="$SRC_TMP/root/image"
	[ -d "$SRC" ] || { echo "  ERROR image root missing in $gpkg"; exit 1; }
}

stage_init() {
	STAGE="$(mktemp -d /tmp/opencode/stage.XXXXXX)"
	OUT="$STAGE/root"
	mkdir -p "$OUT" || exit 1
}

cleanup() {
	if [ -n "${SRC_TMP:-}" ]; then
		rm -rf "$SRC_TMP"
	fi
	if [ -n "${STAGE:-}" ]; then
		rm -rf "$STAGE"
	fi
	SRC_TMP=""
	STAGE=""
}

copy_paths() {
	src="$1"
	out="$2"
	shift 2
	for rel in "$@"; do
		[ -e "$src/$rel" ] || continue
		mkdir -p "$out/$(dirname "$rel")" || exit 1
		cp -a "$src/$rel" "$out/$rel" || exit 1
	done
}

pack() {
	name="$1"
	version="$2"
	system="$3"
	category="$4"
	desc="$5"
	depends="$6"
	dir="$PKGDIR/$name"
	mkdir -p "$dir" || exit 1
	out="$dir/$name.spk"
	tar --owner=0 --group=0 --numeric-owner -czpf "$out" -C "$OUT" . || exit 1
	python3 - "$out" "$name" "$version" "$system" "$category" "$desc" "$depends" <<'PY'
import hashlib, json, os, sys
out, name, version, system, category, desc, depends = sys.argv[1:]
h = hashlib.sha256()
with open(out, "rb") as fh:
	for chunk in iter(lambda: fh.read(1048576), b""):
		h.update(chunk)
man = {
	"filename": os.path.basename(out),
	"parts": 1,
	"sha256": h.hexdigest(),
	"system": system == "true",
	"version": version,
	"depends": json.loads(depends),
	"category": category,
	"description": desc,
}
with open(os.path.join(os.path.dirname(out), "package.json"), "w") as fh:
	json.dump(man, fh, indent=1)
	fh.write("\n")
PY
	echo "  built $out ($(du -h "$out" | cut -f1))"
	cleanup
}

build_pipewire() {
	gpkg="$(fetch_gpkg media-video/pipewire/pipewire-1.6.8-8.gpkg.tar)"
	extract_gpkg "$gpkg"
	stage_init
	copy_paths "$SRC" "$OUT" \
		usr/bin \
		usr/lib64/libpipewire-0.3.so.0.1608.0 \
		usr/lib64/libpipewire-0.3.so.0 \
		usr/lib64/libpipewire-0.3.so \
		usr/lib64/spa-0.2 \
		usr/lib64/pipewire-0.3 \
		usr/lib64/alsa-lib \
		usr/lib64/gstreamer-1.0 \
		usr/lib/udev/rules.d/90-pipewire-alsa.rules \
		usr/share/pipewire \
		usr/share/alsa \
		usr/share/alsa-card-profile \
		etc/security
	pack pipewire 1.6.8-silen1 true media-sound \
		"PipeWire multimedia server with SPA plugins, ALSA integration and PulseAudio compatibility" \
		'["alsa-lib","dbus"]'
}

build_wireplumber() {
	gpkg="$(fetch_gpkg media-video/wireplumber/wireplumber-0.5.15-2.gpkg.tar)"
	extract_gpkg "$gpkg"
	stage_init
	copy_paths "$SRC" "$OUT" \
		usr/bin/wireplumber \
		usr/bin/wpctl \
		usr/bin/wpexec \
		usr/lib64/libwireplumber-0.5.so.0.515.0 \
		usr/lib64/libwireplumber-0.5.so.0 \
		usr/lib64/libwireplumber-0.5.so \
		usr/lib64/wireplumber-0.5 \
		usr/share/wireplumber \
		usr/share/bash-completion/completions/wpctl
	mkdir -p "$OUT/etc/wireplumber/wireplumber.conf.d" || exit 1
	cat > "$OUT/etc/wireplumber/wireplumber.conf.d/50-silen-audio.conf" <<'EOF'
wireplumber.profiles = {
  main = {
    hardware.audio = required
    hardware.bluetooth = optional
  }
}
EOF
	chmod 644 "$OUT/etc/wireplumber/wireplumber.conf.d/50-silen-audio.conf" || exit 1
	pack wireplumber 0.5.15 true media-sound \
		"WirePlumber session and policy manager for PipeWire" \
		'["pipewire","lua-libs","gtk-libs"]'
}

build_lua_libs() {
	gpkg="$(fetch_gpkg dev-lang/lua/lua-5.4.8-6.gpkg.tar)"
	extract_gpkg "$gpkg"
	stage_init
	copy_paths "$SRC" "$OUT" \
		usr/lib64/liblua5.4.so.0.0.0 \
		usr/lib64/liblua5.4.so.0 \
		usr/lib64/liblua5.4.so
	pack lua-libs 5.4.8 true dev-libs \
		"Lua 5.4 runtime library for WirePlumber" \
		'[]'
}

build_libasyncns() {
	gpkg="$(fetch_gpkg net-libs/libasyncns/libasyncns-0.8-r5-1.gpkg.tar)"
	extract_gpkg "$gpkg"
	stage_init
	copy_paths "$SRC" "$OUT" \
		usr/lib64/libasyncns.so.0.3.1 \
		usr/lib64/libasyncns.so.0 \
		usr/lib64/libasyncns.so
	pack libasyncns 0.8-r5 true net-libs \
		"Asynchronous DNS resolver library for PulseAudio" \
		'[]'
}

build_libpulse() {
	gpkg="$(fetch_gpkg media-libs/libpulse/libpulse-17.0-9.gpkg.tar)"
	extract_gpkg "$gpkg"
	stage_init
	copy_paths "$SRC" "$OUT" \
		usr/lib64/libpulse.so.0.24.3 \
		usr/lib64/libpulse.so.0 \
		usr/lib64/libpulse.so \
		usr/lib64/libpulse-simple.so.0.1.1 \
		usr/lib64/libpulse-simple.so.0 \
		usr/lib64/libpulse-simple.so \
		usr/lib64/libpulse-mainloop-glib.so.0.0.6 \
		usr/lib64/libpulse-mainloop-glib.so.0 \
		usr/lib64/libpulse-mainloop-glib.so \
		usr/lib64/pulseaudio \
		usr/bin/pacat \
		usr/bin/pactl \
		usr/bin/pa-info \
		usr/bin/pamon \
		usr/bin/paplay \
		usr/bin/parec \
		usr/bin/parecord \
		usr/bin/pax11publish \
		etc/pulse/client.conf
	pack libpulse 17.0 true media-libs \
		"PulseAudio client libraries and tools for PipeWire-Pulse" \
		'["libsndfile","libasyncns","dbus","xorg-libs"]'
}

build_silen_audio() {
	stage_init
	mkdir -p "$OUT/usr/local/bin" "$OUT/etc/xdg/autostart" || exit 1
	cat > "$OUT/usr/local/bin/silen-audio-run" <<'EOF'
#!/bin/sh
set -e

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
	exec dbus-run-session -- "$0" "$@"
fi

uid="$(id -u)"
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR:-}" ] || [ ! -w "${XDG_RUNTIME_DIR:-}" ]; then
	XDG_RUNTIME_DIR="/run/user/$uid"
	if ! mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || [ ! -w "$XDG_RUNTIME_DIR" ]; then
		XDG_RUNTIME_DIR="/tmp/silen-audio-$uid"
		mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
	fi
	export XDG_RUNTIME_DIR
fi
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

log="$XDG_RUNTIME_DIR/silen-audio.log"
: >>"$log" 2>/dev/null || log=/dev/null

if [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
	/usr/bin/pipewire >>"$log" 2>&1 &
fi

i=0
while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ] && [ "$i" -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done

if ! pgrep -u "$uid" -x wireplumber >/dev/null 2>&1; then
	/usr/bin/wireplumber >>"$log" 2>&1 &
fi

if [ ! -S "$XDG_RUNTIME_DIR/pulse/native" ]; then
	/usr/bin/pipewire -c pipewire-pulse.conf >>"$log" 2>&1 &
fi

i=0
while [ ! -S "$XDG_RUNTIME_DIR/pulse/native" ] && [ "$i" -lt 50 ]; do
	sleep 0.1
	i=$((i + 1))
done

exec "$@"
EOF
	cat > "$OUT/usr/local/bin/silen-audio-start" <<'EOF'
#!/bin/sh
exec /usr/local/bin/silen-audio-run true
EOF
	cat > "$OUT/etc/xdg/autostart/silen-audio.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Silen Audio
Comment=Start PipeWire, WirePlumber and PipeWire-Pulse
Exec=/usr/local/bin/silen-audio-start
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
	chmod 755 "$OUT/usr/local/bin/silen-audio-run" "$OUT/usr/local/bin/silen-audio-start" || exit 1
	chmod 644 "$OUT/etc/xdg/autostart/silen-audio.desktop" || exit 1
	pack silen-audio 1.0.0 true media-sound \
		"PipeWire, WirePlumber and PipeWire-Pulse session autostart" \
		'["pipewire","wireplumber","alsa-lib","libpulse"]'
}

patch_sessions() {
	for spec in "mango|0.17.5.2-r3|Exec=dbus-run-session -- mango|Exec=dbus-run-session -- /usr/local/bin/silen-audio-run mango" \
		"niri|26.4.2-r1|Exec=niri-session|Exec=dbus-run-session -- /usr/local/bin/silen-audio-run niri-session"; do
		name="${spec%%|*}"
		rest="${spec#*|}"
		version="${rest%%|*}"
		rest="${rest#*|}"
		old="${rest%%|*}"
		new="${rest#*|}"
		oldspk="$PKGDIR/$name/$name.spk"
		[ -f "$oldspk" ] || { echo "  ERROR missing $oldspk"; exit 1; }
		tmp="$(mktemp -d /tmp/opencode/session.XXXXXX)"
		tar -xzf "$oldspk" -C "$tmp" || exit 1
		desktop="$tmp/usr/share/wayland-sessions/$name.desktop"
		[ -f "$desktop" ] || { echo "  ERROR missing $desktop"; exit 1; }
		sed -i "s|^${old}$|${new}|" "$desktop" || exit 1
		tar --owner=0 --group=0 --numeric-owner -czpf "$oldspk.new" -C "$tmp" . || exit 1
		mv "$oldspk.new" "$oldspk" || exit 1
		rm -rf "$tmp"
		python3 - "$PKGDIR/$name/package.json" "$oldspk" "$version" <<'PY'
import hashlib, json, sys
path, spk, version = sys.argv[1:]
man = json.load(open(path))
h = hashlib.sha256()
with open(spk, "rb") as fh:
	for chunk in iter(lambda: fh.read(1048576), b""):
		h.update(chunk)
man["sha256"] = h.hexdigest()
man["version"] = version
if "silen-audio" not in man.get("depends", []):
	man.setdefault("depends", []).append("silen-audio")
with open(path, "w") as fh:
	json.dump(man, fh, indent=1)
	fh.write("\n")
PY
		echo "  patched $name ($version)"
	done
}

case "$cmd" in
pipewire) build_pipewire ;;
wireplumber) build_wireplumber ;;
lua-libs) build_lua_libs ;;
libasyncns) build_libasyncns ;;
libpulse) build_libpulse ;;
silen-audio) build_silen_audio ;;
sessions) patch_sessions ;;
all)
	build_pipewire
	build_wireplumber
	build_lua_libs
	build_libasyncns
	build_libpulse
	build_silen_audio
	patch_sessions
	;;
*) usage ;;
esac
