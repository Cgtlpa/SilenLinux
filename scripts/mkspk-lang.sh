#!/bin/bash
# builds the language pkgs (quickjs perl nim janet fennel)
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-lang stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"

usage() {
	echo "usage: mkspk-lang.sh <pkg> [pkg...] | mkspk-lang.sh all" >&2
	echo "  pkgs: quickjs perl nim janet fennel" >&2
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
	mkdir -p "$_stage/usr/lib64" || exit 1
	while IFS= read -r _lib; do
		[ -n "$_lib" ] || continue
		case "$_lib" in
			*.a|*.la) continue ;;
		esac
		_dest="$_stage/usr/lib64/$(basename "$_lib")"
		[ -e "$_dest" ] && continue
		tar -xpf "$_img" -C "$_stage" "$_lib" 2>/dev/null || true
	done < <(tar -tf "$_img" 2>/dev/null | grep -E "^image/usr/lib64/[^/]*\.so" || true)
	if [ -d "$_stage/image" ]; then
		mkdir -p "$_stage/usr/lib64" 2>/dev/null || true
		cp -a "$_stage/image/usr/lib64/." "$_stage/usr/lib64/" 2>/dev/null || true
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
	_name="$1"
	_version="$2"
	_depends="$3"
	_system="${SYSTEM:-0}"
	_flag="false"
	[ "$_system" = "1" ] && _flag="true"
	mkdir -p "$PKGDIR/$_name" || exit 1
	_members=""
	for _m in usr etc; do
		[ -e "$STAGE/$_m" ] || continue
		_members="$_members $_m"
	done
	[ -n "$_members" ] || { echo "  ERROR empty payload for $_name"; exit 1; }
	tar -czpf "$PKGDIR/$_name/$_name.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
	_s="$(sha256sum "$PKGDIR/$_name/$_name.spk" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": %s, "version": "%s", "depends": [%s]}' "$_name" "$_s" "$_flag" "$_version" "$_depends" > "$PKGDIR/$_name/package.json"
	echo "$_name $_version $(du -h "$PKGDIR/$_name/$_name.spk" | cut -f1)"
}

fresh_stage() {
	STAGE="$(mktemp -d /tmp/opencode/xstage.XXXXXX 2>/dev/null || echo /tmp/opencode/xstage.$$)"
	mkdir -p "$STAGE" || exit 1
}

build_quickjs() {
	fresh_stage
	set -- $(gpkg_img "quickjs-ng-0.14.0-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" qjs qjsc qjsbn
	harvest_solist "$STAGE" "$_img"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "quickjs" "0.14.0" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_perl() {
	fresh_stage
	set -- $(gpkg_img "perl-5.44.0-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" perl cpan perldoc prove corelist enc2xs h2ph h2xs perlthanks pl2pm splain
	harvest_solist "$STAGE" "$_img"
	harvest_tree "$STAGE" "$_img" "usr/lib64/perl5"
	harvest_tree "$STAGE" "$_img" "usr/share/perl5"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "perl" "5.44.0" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_nim() {
	fresh_stage
	set -- $(gpkg_img "nim-2.2.10-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" nim nimble nimsuggest atlas
	harvest_tree "$STAGE" "$_img" "usr/lib/nim"
	harvest_tree "$STAGE" "$_img" "usr/share/nim"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "nim" "2.2.10" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_janet() {
	_src="${JANET_SRC:-/tmp/opencode/janet-src}"
	_bin="$(find "$_src" -path '*/build/janet' -type f 2>/dev/null | head -n 1)"
	_man="$(find "$_src" -name 'janet.1' -type f 2>/dev/null | head -n 1)"
	[ -n "$_bin" ] && [ -x "$_bin" ] || { echo "  ERROR janet binary missing under $_src (build it first: make)"; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/man/man1" || exit 1
	cp -a "$_bin" "$STAGE/usr/bin/janet" || exit 1
	chmod 755 "$STAGE/usr/bin/janet" || exit 1
	[ -n "$_man" ] && cp -a "$_man" "$STAGE/usr/share/man/man1/" || true
	pack "janet" "1.42.1" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_fennel() {
	_src="${FENNEL_SRC:-/tmp/opencode/fennel-src}"
	[ -f "$_src/fennel.lua" ] || { echo "  ERROR fennel.lua missing: $_src"; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/fennel" || exit 1
	cp -a "$_src/fennel.lua" "$STAGE/usr/share/fennel/" || exit 1
	printf '#!/bin/sh\nexec lua /usr/share/fennel/fennel.lua "$@"\n' > "$STAGE/usr/bin/fennel" || exit 1
	chmod 755 "$STAGE/usr/bin/fennel" || exit 1
	pack "fennel" "1.0.0" '"lua"'
	rm -rf "$STAGE" 2>/dev/null || true
}

ALL_PKGS="quickjs perl nim janet fennel"

if [ "$1" = "all" ]; then
	shift
	set -- $ALL_PKGS "$@"
fi
for _p in "$@"; do
	# one name per package, same pattern everywhere
	case "$_p" in
		quickjs) build_quickjs ;;
		perl) build_perl ;;
		nim) build_nim ;;
		janet) build_janet ;;
		fennel) build_fennel ;;
		*) usage ;;
	esac
done
