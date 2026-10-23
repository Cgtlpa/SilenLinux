#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-icewm stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
ARCH_MIRROR="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}"

ALSA_FILE="alsa-lib-1.2.16.1-1-x86_64.pkg.tar.zst"
ALSA_UCM_FILE="alsa-ucm-conf-1.2.16.1-1-any.pkg.tar.zst"
ALSA_TOPO_FILE="alsa-topology-conf-1.2.5.1-4-any.pkg.tar.zst"
GIFLIB_FILE="giflib-6.1.3-2-x86_64.pkg.tar.zst"
IMLIB2_FILE="imlib2-1.12.7-3-x86_64.pkg.tar.zst"
JPEG_FILE="libjpeg-turbo-3.2.0-2-x86_64.pkg.tar.zst"
SNDFILE_FILE="libsndfile-1.2.2-4-x86_64.pkg.tar.zst"
FLAC_FILE="flac-1.5.0-1-x86_64.pkg.tar.zst"
LAME_FILE="lame-4.0-1-x86_64.pkg.tar.zst"
MPG123_FILE="mpg123-1.33.7-1-x86_64.pkg.tar.zst"
OGG_FILE="libogg-1.3.6-1-x86_64.pkg.tar.zst"
OPUS_FILE="opus-1.6.1-1-x86_64.pkg.tar.zst"
VORBIS_FILE="libvorbis-1.3.7-4-x86_64.pkg.tar.zst"
DAV1D_FILE="dav1d-1.5.4-1-x86_64.pkg.tar.zst"
LIBRSVG_FILE="librsvg-2:2.63.3-1-x86_64.pkg.tar.zst"
XML2_FILE="libxml2-2.15.4-1-x86_64.pkg.tar.zst"
XRANDR_FILE="xorg-xrandr-1.5.4-1-x86_64.pkg.tar.zst"
ICEWM_FILE="icewm-4.1.0-1-x86_64.pkg.tar.zst"

usage() {
	echo "usage: mkspk-icewm.sh [all|alsa-lib|imlib2|libsndfile|librsvg|xorg-xrandr|icewm]" >&2
	exit 1
}

[ $# -ge 1 ] || usage
mkdir -p "$DLDIR" "$PKGDIR" || exit 1

arch_pkg() {
	_repo="$1"
	_file="$2"
	_path="$DLDIR/$_file"
	if [ ! -f "$_path" ]; then
		echo "  fetching $_file" >&2
		curl -fsSL --max-time 600 -o "$_path" "$ARCH_MIRROR/$_repo/os/x86_64/$_file" || { echo "  ERROR cannot fetch $_file" >&2; exit 1; }
	fi
	printf '%s' "$_path"
}

arch_extract() {
	_pkg="$(arch_pkg "$1" "$2")"
	_tmp="$(mktemp -d /tmp/opencode/icewm.XXXXXX 2>/dev/null || echo /tmp/opencode/icewm.$$)"
	mkdir -p "$_tmp" || exit 1
	tar -xf "$_pkg" -C "$_tmp" || { echo "  ERROR cannot unpack $2"; rm -rf "$_tmp" 2>/dev/null || true; exit 1; }
	printf '%s' "$_tmp"
}

fresh_stage() {
	STAGE="$(mktemp -d /tmp/opencode/icewm-stage.XXXXXX 2>/dev/null || echo /tmp/opencode/icewm-stage.$$)"
	mkdir -p "$STAGE" || exit 1
}

pack() {
	_name="$1"
	_version="$2"
	_depends="$3"
	_desc="$4"
	_cat="$5"
	mkdir -p "$PKGDIR/$_name" || exit 1
	_members=""
	for _m in usr etc; do
		[ -e "$STAGE/$_m" ] || continue
		_members="$_members $_m"
	done
	[ -n "$_members" ] || { echo "  ERROR empty payload for $_name"; exit 1; }
	tar -czpf "$PKGDIR/$_name/$_name.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
	_s="$(sha256sum "$PKGDIR/$_name/$_name.spk" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [%s], "category": "%s", "description": "%s"}' "$_name" "$_s" "$_version" "$_depends" "$_cat" "$_desc" > "$PKGDIR/$_name/package.json"
	echo "$_name $_version $(du -h "$PKGDIR/$_name/$_name.spk" | cut -f1)"
	rm -rf "$STAGE" 2>/dev/null || true
}

build_alsa_lib() {
	_src="$(arch_extract extra "$ALSA_FILE")"
	_ucm="$(arch_extract extra "$ALSA_UCM_FILE")"
	_topo="$(arch_extract extra "$ALSA_TOPO_FILE")"
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" "$STAGE/usr/share/alsa" || exit 1
	cp -a "$_src/usr/lib/"libasound.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_src/usr/lib/"libatopology.so* "$STAGE/usr/lib64/" || exit 1
	for _d in "$_src" "$_ucm" "$_topo"; do
		[ -d "$_d/usr/share/alsa" ] || continue
		cp -a "$_d/usr/share/alsa/." "$STAGE/usr/share/alsa/" || exit 1
	done
	rm -rf "$_src" "$_ucm" "$_topo" 2>/dev/null || true
	pack "alsa-lib" "1.2.16.1" '' "ALSA library and configuration" "media-libs"
}

build_xorg_xrandr() {
	_src="$(arch_extract extra "$XRANDR_FILE")"
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/man/man1" || exit 1
	cp -a "$_src/usr/bin/xrandr" "$STAGE/usr/bin/xrandr" || exit 1
	[ -f "$_src/usr/share/man/man1/xrandr.1.gz" ] && cp -a "$_src/usr/share/man/man1/xrandr.1.gz" "$STAGE/usr/share/man/man1/" || true
	rm -rf "$_src" 2>/dev/null || true
	pack "xorg-xrandr" "1.5.4" '"xorg-libs", "wl-libs"' "X11 RandR configuration utility" "x11-apps"
}

build_imlib2() {
	_src="$(arch_extract extra "$IMLIB2_FILE")"
	_gif="$(arch_extract extra "$GIFLIB_FILE")"
	_jpeg="$(arch_extract extra "$JPEG_FILE")"
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" "$STAGE/usr/lib/imlib2/loaders" "$STAGE/usr/lib/imlib2/filters" || exit 1
	cp -a "$_src/usr/lib/"libImlib2.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_gif/usr/lib/"libgif.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_jpeg/usr/lib/"libjpeg.so* "$STAGE/usr/lib64/" || exit 1
	for _l in ani argb bmp bz2 ff gif ico jpeg lbm lzma png pnm qoi svg tga tiff webp xbm xpm zlib; do
		[ -f "$_src/usr/lib/imlib2/loaders/$_l.so" ] || continue
		cp -a "$_src/usr/lib/imlib2/loaders/$_l.so" "$STAGE/usr/lib/imlib2/loaders/" || exit 1
	done
	if [ -d "$_src/usr/lib/imlib2/filters" ]; then
		cp -a "$_src/usr/lib/imlib2/filters/." "$STAGE/usr/lib/imlib2/filters/" 2>/dev/null || true
	fi
	rm -rf "$_src" "$_gif" "$_jpeg" 2>/dev/null || true
	pack "imlib2" "1.12.7" '"xorg-libs", "gtk-libs", "librsvg"' "Imlib2 image loading library with common loaders" "media-libs"
}

build_libsndfile() {
	_src="$(arch_extract extra "$SNDFILE_FILE")"
	_flac="$(arch_extract extra "$FLAC_FILE")"
	_lame="$(arch_extract extra "$LAME_FILE")"
	_mpg="$(arch_extract extra "$MPG123_FILE")"
	_ogg="$(arch_extract extra "$OGG_FILE")"
	_opus="$(arch_extract extra "$OPUS_FILE")"
	_vorbis="$(arch_extract extra "$VORBIS_FILE")"
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" || exit 1
	cp -a "$_src/usr/lib/"libsndfile.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_flac/usr/lib/"libFLAC.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_lame/usr/lib/"libmp3lame.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_mpg/usr/lib/"libmpg123.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_ogg/usr/lib/"libogg.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_opus/usr/lib/"libopus.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_vorbis/usr/lib/"libvorbis.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_vorbis/usr/lib/"libvorbisenc.so* "$STAGE/usr/lib64/" || exit 1
	rm -rf "$_src" "$_flac" "$_lame" "$_mpg" "$_ogg" "$_opus" "$_vorbis" 2>/dev/null || true
	pack "libsndfile" "1.2.2" '"alsa-lib"' "libsndfile and audio codec runtimes" "media-libs"
}

build_librsvg() {
	_src="$(arch_extract extra "$LIBRSVG_FILE")"
	_dav="$(arch_extract extra "$DAV1D_FILE")"
	_xml="$(arch_extract core "$XML2_FILE")"
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" || exit 1
	cp -a "$_src/usr/lib/"librsvg-2.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_dav/usr/lib/"libdav1d.so* "$STAGE/usr/lib64/" || exit 1
	cp -a "$_xml/usr/lib/"libxml2.so* "$STAGE/usr/lib64/" || exit 1
	rm -rf "$_src" "$_dav" "$_xml" 2>/dev/null || true
	pack "librsvg" "2.63.3" '"gtk-libs", "xorg-libs"' "SVG rendering library" "gnome"
}

build_icewm() {
	_src="$(arch_extract extra "$ICEWM_FILE")"
	fresh_stage
	cp -a "$_src/usr" "$STAGE/" || exit 1
	rm -rf "$_src" 2>/dev/null || true
	pack "icewm" "4.1.0" '"alsa-lib", "imlib2", "libsndfile", "librsvg", "xorg-server", "xorg-drivers", "xorg-libs", "wl-libs", "gtk-libs", "cxx-libs", "xinit", "xkb-data", "dejavu", "perl", "xorg-xrandr"' "IceWM window manager with session files and themes" "x11-wm"
}

if [ "$1" = "all" ]; then
	build_alsa_lib
	build_xorg_xrandr
	build_librsvg
	build_libsndfile
	build_imlib2
	build_icewm
	exit 0
fi
for _p in "$@"; do
	case "$_p" in
		alsa-lib) build_alsa_lib ;;
		xorg-xrandr) build_xorg_xrandr ;;
		imlib2) build_imlib2 ;;
		libsndfile) build_libsndfile ;;
		librsvg) build_librsvg ;;
		icewm) build_alsa_lib; build_xorg_xrandr; build_librsvg; build_libsndfile; build_imlib2; build_icewm ;;
		*) usage ;;
	esac
done
