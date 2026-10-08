#!/bin/bash
# builds the xorg pkgs out of gpkg images, same deal as wayland one
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-xorg stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
SNAPVER="${SNAPVER:-20261007}"

usage() {
	echo "usage: mkspk-xorg.sh <pkg> [pkg...] | mkspk-xorg.sh all" >&2
	echo "  pkgs: xorg-server xorg-libs llvm xkb-data dejavu xorg-drivers xinit dwm dmenu st" >&2
	exit 1
}

[ $# -ge 1 ] || usage

gpkg_img() {
	_g="$1"
	[ -f "$_g" ] || _g="$DLDIR/$(basename "$_g")"
	[ -f "$_g" ] || { echo "  ERROR gpkg missing: $1"; exit 1; }
	_tmp="$(mktemp -d /tmp/opencode/gx.XXXXXX 2>/dev/null || echo /tmp/opencode/gx.$$)"
	mkdir -p "$_tmp" || exit 1
	tar -xf "$_g" -C "$_tmp" 2>/dev/null
	_img="$(find "$_tmp" -name 'image.tar.*' ! -name '*.sig' | head -n 1)"
	[ -n "$_img" ] || { echo "  ERROR no image in $1"; rm -rf "$_tmp" 2>/dev/null || true; exit 1; }
	printf '%s %s\n' "$_tmp" "$_img"
}

harvest_bins() {
	_stage="$1"
	_img="$2"
	shift 2
	mkdir -p "$_stage/usr/bin" || exit 1
	for _b in "$@"; do
		_f="$(tar -tf "$_img" 2>/dev/null | grep -E "(^|/)usr/bin/$_b$" | head -n 1 || true)"
		[ -n "$_f" ] || { echo "  ! bin $_b not in image"; continue; }
		tar -xpf "$_img" -C "$_stage" "$_f" 2>/dev/null || true
	done
	if [ -d "$_stage/image" ]; then
		cp -a "$_stage/image/." "$_stage/" 2>/dev/null || true
		rm -rf "$_stage/image" 2>/dev/null || true
	fi
	for _b in "$@"; do
		[ -e "$_stage/usr/bin/$_b" ] && chmod 755 "$_stage/usr/bin/$_b" 2>/dev/null || true
	done
}

harvest_solist() {
	_stage="$1"
	_img="$2"
	_lb="${3:-usr/lib64}"
	_sub="$4"
	mkdir -p "$_stage/usr/lib64" || exit 1
	while IFS= read -r _lib; do
		[ -n "$_lib" ] || continue
		case "$_lib" in
			*.a|*.la) continue ;;
		esac
		case "$(basename "$_lib")" in
			libudev.so*|libdbus-1.so*|libbrotli*.so*) continue ;;
		esac
		_dest="$_stage/usr/lib64/$(basename "$_lib")"
		[ -e "$_dest" ] && continue
		tar -xpf "$_img" -C "$_stage" "$_lib" 2>/dev/null || true
	done < <(tar -tf "$_img" 2>/dev/null | grep -E "^image/$_lb/$_sub[^/]*\.so" || true)
	if [ -d "$_stage/image" ]; then
		mkdir -p "$_stage/usr/lib64" 2>/dev/null || true
		cp -a "$_stage/image/$_lb/." "$_stage/usr/lib64/" 2>/dev/null || true
		rm -rf "$_stage/image" 2>/dev/null || true
	fi
}

harvest_tree() {
	_stage="$1"
	_img="$2"
	_tree="$3"
	while IFS= read -r _e; do
		[ -n "$_e" ] || continue
		tar -xpf "$_img" -C "$_stage" "$_e" 2>/dev/null || true
	done < <(tar -tf "$_img" 2>/dev/null | grep -E "^image/$_tree" || true)
	if [ -d "$_stage/image" ]; then
		cp -a "$_stage/image/." "$_stage/" 2>/dev/null || true
		rm -rf "$_stage/image" 2>/dev/null || true
	fi
}

pack() {
	# tar up whatever got harvested into name.spk
	_name="$1"
	_version="$2"
	mkdir -p "$PKGDIR/$_name" || exit 1
	_members=""
	for _m in usr etc; do
		[ -e "$STAGE/$_m" ] || continue
		_members="$_members $_m"
	done
	[ -n "$_members" ] || { echo "  ERROR empty payload for $_name"; exit 1; }
	tar -czpf "$PKGDIR/$_name/$_name.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
	_s="$(sha256sum "$PKGDIR/$_name/$_name.spk" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s"}' "$_name" "$_s" "$_version" > "$PKGDIR/$_name/package.json"
	echo "$_name $_version $(du -h "$PKGDIR/$_name/$_name.spk" | cut -f1)"
}

fresh_stage() {
	STAGE="$(mktemp -d /tmp/opencode/xstage.XXXXXX 2>/dev/null || echo /tmp/opencode/xstage.$$)"
	mkdir -p "$STAGE" || exit 1
}

so_gpkgs="libX11-1.8.13-2.gpkg.tar libXau-1.0.12-9.gpkg.tar libXdmcp-1.1.5-11.gpkg.tar libXext-1.3.7-2.gpkg.tar libXfont2-2.0.9-1.gpkg.tar libXft-2.3.9-6.gpkg.tar libXmu-1.3.1-1.gpkg.tar libXrender-0.9.12-9.gpkg.tar libXt-1.3.1-r1-8.gpkg.tar libXxf86vm-1.1.7-2.gpkg.tar libSM-1.2.6-6.gpkg.tar libICE-1.1.2-8.gpkg.tar libxcb-1.17.0-14.gpkg.tar libpciaccess-0.19-1.gpkg.tar libxshmfence-1.3.3-8.gpkg.tar libxcvt-0.1.3-7.gpkg.tar libfontenc-1.1.9-1.gpkg.tar libxkbfile-1.2.0-1.gpkg.tar pixman-0.46.4-7.gpkg.tar libepoxy-1.5.10-r3-10.gpkg.tar libpng-1.6.58-2.gpkg.tar freetype-2.14.3-7.gpkg.tar fontconfig-2.18.3-1.gpkg.tar brotli-1.2.0-r1-3.gpkg.tar libbsd-0.11.8-7.gpkg.tar libevdev-1.13.6-7.gpkg.tar libinput-1.31.3-1.gpkg.tar mtdev-1.1.7-6.gpkg.tar dbus-1.16.2-24.gpkg.tar libglvnd-1.7.0-13.gpkg.tar openssl-3.5.8-1.gpkg.tar systemd-261.2-1.gpkg.tar libgudev-238-r2-8.gpkg.tar"

build_xorg_libs() {
	fresh_stage
	for _g in $so_gpkgs; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		harvest_solist "$STAGE" "$_img" "usr/lib64" ""
		rm -rf "$_tmp" 2>/dev/null || true
	done
	set -- $(gpkg_img "libinput-1.31.3-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_tree "$STAGE" "$_img" "usr/lib/udev"
	rm -rf "$_tmp" 2>/dev/null || true
	set -- $(gpkg_img "fontconfig-2.18.3-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" fc-cache fc-list fc-match
	rm -rf "$_tmp" 2>/dev/null || true
	printf 'GROUP ( libGLX_mesa.so.0 libGLdispatch.so.0 )\n' > "$STAGE/usr/lib64/libGL.so.1" || exit 1
	if [ -d "$DLDIR/fedora-libs" ]; then
		cp -a "$DLDIR/fedora-libs"/libwacom.so* "$STAGE/usr/lib64/" 2>/dev/null || true
	fi
	pack "xorg-libs" "$SNAPVER"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_llvm() {
	fresh_stage
	set -- $(gpkg_img "llvm-22.1.8-5.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib/llvm/22/lib64" ""
	rm -rf "$_tmp" 2>/dev/null || true
	set -- $(gpkg_img "spirv-tools-1.4.350.0-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64" ""
	rm -rf "$_tmp" 2>/dev/null || true
	pack "llvm" "22.1.8"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_xorg_server() {
	fresh_stage
	set -- $(gpkg_img "xorg-server-21.1.24-6.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" Xorg gtf
	harvest_tree "$STAGE" "$_img" "usr/lib64/xorg"
	harvest_tree "$STAGE" "$_img" "usr/share/X11/xorg.conf.d"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "xorg-server" "21.1.24"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_xkb_data() {
	fresh_stage
	set -- $(gpkg_img "xkeyboard-config-2.48-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_tree "$STAGE" "$_img" "usr/share/xkeyboard-config-2"
	rm -rf "$_tmp" 2>/dev/null || true
	set -- $(gpkg_img "xkbcomp-1.5.0-r2-5.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" xkbcomp
	rm -rf "$_tmp" 2>/dev/null || true
	mkdir -p "$STAGE/usr/share/X11" || exit 1
	ln -sfn "../xkeyboard-config-2" "$STAGE/usr/share/X11/xkb" || exit 1
	pack "xkb-data" "2.48"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_dejavu() {
	fresh_stage
	set -- $(gpkg_img "dejavu-2.37-2.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_tree "$STAGE" "$_img" "usr/share/fonts"
	rm -rf "$_tmp" 2>/dev/null || true
	mkdir -p "$STAGE/usr/lib/spk" || exit 1
	printf '#!/bin/sh\ncommand -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true\nexit 0\n' > "$STAGE/usr/lib/spk/postinstall" || exit 1
	chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1
	pack "dejavu" "2.37"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_xorg_drivers() {
	fresh_stage
	for _g in xf86-video-amdgpu-25.0.0-r1-11.gpkg.tar xf86-video-nouveau-1.0.18-15.gpkg.tar xf86-input-libinput-1.5.0-15.gpkg.tar; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		harvest_tree "$STAGE" "$_img" "usr/lib64/xorg"
		harvest_tree "$STAGE" "$_img" "usr/share/X11/xorg.conf.d"
		rm -rf "$_tmp" 2>/dev/null || true
	done
	pack "xorg-drivers" "$SNAPVER"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_xinit() {
	fresh_stage
	set -- $(gpkg_img "xinit-1.4.4-5.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" xinit startx
	harvest_tree "$STAGE" "$_img" "etc/X11"
	rm -rf "$_tmp" 2>/dev/null || true
	for _g in xauth-1.1.5-5.gpkg.tar iceauth-1.0.11-1.gpkg.tar xrdb-1.2.3-r2-1.gpkg.tar; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		_bn="$(basename "$_g" | sed -E 's/-[0-9].*//')"
		harvest_bins "$STAGE" "$_img" "$_bn"
		rm -rf "$_tmp" 2>/dev/null || true
	done
	pack "xinit" "1.4.4"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_dwm() {
	fresh_stage
	set -- $(gpkg_img "dwm-6.8-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" dwm
	harvest_tree "$STAGE" "$_img" "etc/X11"
	rm -rf "$_tmp" 2>/dev/null || true
	mkdir -p "$STAGE/usr/share/xsessions" || exit 1
	printf '[Desktop Entry]\nName=dwm\nComment=Dynamic window manager\nExec=dwm\nType=XSession\n' > "$STAGE/usr/share/xsessions/dwm.desktop" || exit 1
	pack "dwm" "6.8"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_dmenu() {
	fresh_stage
	set -- $(gpkg_img "dmenu-5.4-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" dmenu dmenu_path dmenu_run stest
	rm -rf "$_tmp" 2>/dev/null || true
	pack "dmenu" "5.4"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_st() {
	fresh_stage
	set -- $(gpkg_img "st-0.9.2-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" st
	rm -rf "$_tmp" 2>/dev/null || true
	set -- $(gpkg_img "st-terminfo-0.9.3-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_tree "$STAGE" "$_img" "usr/share/terminfo"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "st" "0.9.2"
	rm -rf "$STAGE" 2>/dev/null || true
}

ALL_PKGS="xorg-libs llvm xorg-server xkb-data dejavu xorg-drivers xinit dwm dmenu st"

if [ "$1" = "all" ]; then
	shift
	set -- $ALL_PKGS "$@"
fi
for _p in "$@"; do
	# one name per package, add new ones here too
	case "$_p" in
		xorg-libs) build_xorg_libs ;;
		llvm) build_llvm ;;
		xorg-server) build_xorg_server ;;
		xkb-data) build_xkb_data ;;
		dejavu) build_dejavu ;;
		xorg-drivers) build_xorg_drivers ;;
		xinit) build_xinit ;;
		dwm) build_dwm ;;
		dmenu) build_dmenu ;;
		st) build_st ;;
		*) usage ;;
	esac
done
