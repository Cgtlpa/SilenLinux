#!/bin/bash
# builds the waylandPkgs out of gpkg images, run with "all" or names
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-wayland stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

DLDIR="${DLDIR:-spk-pkgs/dl}"
PKGDIR="${PKGDIR:-spk-pkgs/packages}"
SNAPVER="${SNAPVER:-20261007}"

usage() {
	echo "usage: mkspk-wayland.sh <pkg> [pkg...] | mkspk-wayland.sh all" >&2
	echo "  pkgs: gtk-libs wl-libs wofi rofi alacritty kitty gtk3 libcjson cxx-libs pipewire waybar niri vulkan-loader wlroots scenefx seatd mango" >&2
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
	mkdir -p "$_stage/usr/lib64" || exit 1
	while IFS= read -r _lib; do
		[ -n "$_lib" ] || continue
		case "$_lib" in
			*.a|*.la) continue ;;
		esac
		case "$(basename "$_lib")" in
			libudev.so*) continue ;;
		esac
		_dest="$_stage/usr/lib64/$(basename "$_lib")"
		[ -e "$_dest" ] && continue
		tar -xpf "$_img" -C "$_stage" "$_lib" 2>/dev/null || true
	done < <(tar -tf "$_img" 2>/dev/null | grep -E "^image/$_lb/[^/]*\.so" || true)
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
	_depends="$3"
	mkdir -p "$PKGDIR/$_name" || exit 1
	_members=""
	for _m in usr etc; do
		[ -e "$STAGE/$_m" ] || continue
		_members="$_members $_m"
	done
	[ -n "$_members" ] || { echo "  ERROR empty payload for $_name"; exit 1; }
	tar -czpf "$PKGDIR/$_name/$_name.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
	_s="$(sha256sum "$PKGDIR/$_name/$_name.spk" | awk '{print $1}')"
	printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [%s]}' "$_name" "$_s" "$_version" "$_depends" > "$PKGDIR/$_name/package.json"
	echo "$_name $_version $(du -h "$PKGDIR/$_name/$_name.spk" | cut -f1)"
}

fresh_stage() {
	STAGE="$(mktemp -d /tmp/opencode/xstage.XXXXXX 2>/dev/null || echo /tmp/opencode/xstage.$$)"
	mkdir -p "$STAGE" || exit 1
}

gtk_so_gpkgs="glib-2.88.2-6.gpkg.tar cairo-1.18.4-r1-31.gpkg.tar pango-1.57.1-3.gpkg.tar harfbuzz-12.3.2-5.gpkg.tar fribidi-1.0.13-1.gpkg.tar graphite2-1.3.14_p20210810-r5-7.gpkg.tar gdk-pixbuf-2.44.7-2.gpkg.tar atk-2.46.0-1.gpkg.tar at-spi2-core-2.58.8-5.gpkg.tar libjpeg-turbo-3.1.3-7.gpkg.tar tiff-4.7.1-8.gpkg.tar libwebp-1.4.0-7.gpkg.tar libfmt-12.1.0-6.gpkg.tar spdlog-1.17.0-3.gpkg.tar libxml2-compat-2.13.9-1.gpkg.tar lcms-2.19.1-2.gpkg.tar icu-78.3-6.gpkg.tar"

build_gtk_libs() {
	fresh_stage
	for _g in $gtk_so_gpkgs; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		harvest_solist "$STAGE" "$_img" "usr/lib64"
		rm -rf "$_tmp" 2>/dev/null || true
	done
	set -- $(gpkg_img "gdk-pixbuf-2.44.7-2.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_tree "$STAGE" "$_img" "usr/lib64/gdk-pixbuf"
	harvest_bins "$STAGE" "$_img" gdk-pixbuf-query-loaders
	rm -rf "$_tmp" 2>/dev/null || true
	mkdir -p "$STAGE/usr/lib/spk" || exit 1
	printf '#!/bin/sh\ncommand -v gdk-pixbuf-query-loaders >/dev/null 2>&1 && gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1 || true\nexit 0\n' > "$STAGE/usr/lib/spk/postinstall" || exit 1
	chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1
	if [ -d "$DLDIR/fedora-libs" ]; then
		cp -a "$DLDIR/fedora-libs"/libthai.so* "$DLDIR/fedora-libs"/libdatrie.so* "$STAGE/usr/lib64/" 2>/dev/null || true
	fi
	pack "gtk-libs" "$SNAPVER" '"xorg-libs"'
	rm -rf "$STAGE" 2>/dev/null || true
}

wl_so_gpkgs="wayland-1.25.0-r1-2.gpkg.tar libxkbcommon-1.13.2-2.gpkg.tar gtk-layer-shell-0.10.1-2.gpkg.tar startup-notification-0.12-r2-7.gpkg.tar xcb-util-0.4.1-11.gpkg.tar xcb-util-wm-0.4.2-1.gpkg.tar xcb-util-image-0.4.1-11.gpkg.tar xcb-util-renderutil-0.3.10-11.gpkg.tar xcb-util-cursor-0.1.6-6.gpkg.tar libXcomposite-0.4.7-2.gpkg.tar libXcursor-1.2.3-8.gpkg.tar libXdamage-1.1.7-2.gpkg.tar libXfixes-6.0.2-7.gpkg.tar libXi-1.8.3-1.gpkg.tar libXrandr-1.5.5-2.gpkg.tar libXtst-1.2.5-9.gpkg.tar libXinerama-1.1.6-1.gpkg.tar"

build_wl_libs() {
	fresh_stage
	for _g in $wl_so_gpkgs; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		harvest_solist "$STAGE" "$_img" "usr/lib64"
		rm -rf "$_tmp" 2>/dev/null || true
	done
	pack "wl-libs" "20261007" '"xorg-libs", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

seed_postinstall() {
	_stage="$1"
	shift
	mkdir -p "$_stage/usr/lib/spk" || exit 1
	{
		printf '#!/bin/sh\n'
		printf '[ "${SPK_USER_MODE:-0}" = "1" ] && exit 0\n'
		printf 'R="${SPK_ROOT:-/}"\n'
		printf '[ -z "$R" ] && R="/"\n'
		printf 'seed_one() {\n'
		printf '\tsrc="$1"\n'
		printf '\trel="$2"\n'
		printf '\t[ -f "$R$src" ] || return 0\n'
		printf '\tfor h in "$R/root" "$R"/home/*; do\n'
		printf '\t\t[ -d "$h" ] || continue\n'
		printf '\t\td="$h/$rel"\n'
		printf '\t\t[ -e "$d" ] && continue\n'
		printf '\t\tmkdir -p "$(dirname "$d")" 2>/dev/null || continue\n'
		printf '\t\tcp -a "$R$src" "$d" 2>/dev/null || continue\n'
		printf '\t\tchmod 644 "$d" 2>/dev/null || true\n'
		printf '\t\tif [ "$h" != "$R/root" ]; then\n'
		printf '\t\t\tchown --reference="$h" "$d" 2>/dev/null || true\n'
		printf '\t\t\tchown --reference="$h" "$(dirname "$d")" 2>/dev/null || true\n'
		printf '\t\tfi\n'
		printf '\tdone\n'
		printf '}\n'
		for _seed in "$@"; do
			printf 'seed_one %s\n' "$_seed"
		done
		printf 'exit 0\n'
	} > "$_stage/usr/lib/spk/postinstall" || exit 1
	chmod 755 "$_stage/usr/lib/spk/postinstall" || exit 1
}

build_wofi() {
	fresh_stage
	set -- $(gpkg_img "wofi-1.4.1-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" wofi
	harvest_tree "$STAGE" "$_img" "usr/share/wofi"
	harvest_tree "$STAGE" "$_img" "usr/share/wayland-sessions"
	rm -rf "$_tmp" 2>/dev/null || true
	mkdir -p "$STAGE/usr/share/wofi" || exit 1
	cat > "$STAGE/usr/share/wofi/config" <<'EOF'
show=drun
width=35%
lines=6
matching=fuzzy
insensitive=true
allow_images=true
image_size=28
EOF
	cat > "$STAGE/usr/share/wofi/style.css" <<'EOF'
window {
	background-color: #1e1e2e;
	color: #cdd6f3;
	border: none;
}
#input {
	background-color: #313244;
	color: #cdd6f3;
	border: none;
	margin: 4px;
}
#entry:selected {
	background-color: #89b4fa;
	color: #11111b;
}
EOF
	seed_postinstall "$STAGE" "/usr/share/wofi/config .config/wofi/config" "/usr/share/wofi/style.css .config/wofi/style.css"
	pack "wofi" "1.4.2" '"wl-libs", "gtk-libs", "gtk3", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_rofi() {
	fresh_stage
	set -- $(gpkg_img "rofi-1.7.9.1-1.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_bins "$STAGE" "$_img" rofi
	harvest_tree "$STAGE" "$_img" "usr/share/rofi"
	rm -rf "$_tmp" 2>/dev/null || true
	cat > "$STAGE/usr/share/rofi/config.rasi" <<'EOF'
configuration {
	modi: "drun,run,window";
	show-icons: true;
	matching: "fuzzy";
	font: "monospace 10";
}
EOF
	seed_postinstall "$STAGE" "/usr/share/rofi/config.rasi .config/rofi/config.rasi"
	pack "rofi" "1.7.9.2" '"xorg-libs", "gtk-libs", "wl-libs"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_alacritty() {
	_src="${ALACRITTY_SRC:-$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/alacritty-0.17.0}"
	_bin="${ALACRITTY_BIN:-/tmp/opencode/alacritty-root/bin/alacritty}"
	[ -f "$_bin" ] || { echo "  ERROR alacritty binary missing: $_bin"; exit 1; }
	[ -f "$_src/extra/linux/Alacritty.desktop" ] || { echo "  ERROR alacritty extras missing: $_src"; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/scalable/apps" "$STAGE/usr/share/terminfo" || exit 1
	cp -a "$_bin" "$STAGE/usr/bin/alacritty" || exit 1
	chmod 755 "$STAGE/usr/bin/alacritty" || exit 1
	cp -a "$_src/extra/linux/Alacritty.desktop" "$STAGE/usr/share/applications/" || exit 1
	cp -a "$_src/extra/logo/alacritty-term.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/Alacritty.svg" || exit 1
	tic -x -o "$STAGE/usr/share/terminfo" "$_src/extra/alacritty.info" || { echo "  ERROR tic failed"; exit 1; }
	pack "alacritty" "0.17.0" '"xorg-libs", "gtk-libs", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_gtk3() {
	fresh_stage
	set -- $(gpkg_img "gtk+-3.24.52-3.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	harvest_bins "$STAGE" "$_img" gtk-query-settings gtk-launch
	harvest_tree "$STAGE" "$_img" "usr/lib64/gtk-3.0"
	harvest_tree "$STAGE" "$_img" "usr/share/GConf"
	rm -rf "$_tmp" 2>/dev/null || true
	_srcbld="${GTK3_SRCBLD:-/tmp/opencode/gtk/build}"
	if [ -f "$_srcbld/gtk/libgtk-3.so" ]; then
		cp -a "$_srcbld"/gtk/libgtk-3.so* "$STAGE/usr/lib64/" 2>/dev/null || true
		cp -a "$_srcbld"/gdk/libgdk-3.so* "$STAGE/usr/lib64/" 2>/dev/null || true
	fi
	pack "gtk3" "3.24.52" '"gtk-libs", "xorg-libs", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_libcjson() {
	_src="$DLDIR/cjson-1.7.19.tar.gz"
	[ -f "$_src" ] || { echo "  ERROR cjson tarball missing: $_src"; exit 1; }
	_tmp="$(mktemp -d /tmp/opencode/cj.XXXXXX 2>/dev/null || echo /tmp/opencode/cj.$$)"
	mkdir -p "$_tmp" || exit 1
	tar -xzf "$_src" -C "$_tmp" || exit 1
	_cd="$(find "$_tmp" -maxdepth 2 -name 'cJSON.c' | head -n 1 | xargs dirname)"
	[ -n "$_cd" ] || { echo "  ERROR cjson sources missing"; rm -rf "$_tmp" 2>/dev/null || true; exit 1; }
	(cd "$_cd" && make shared 2>&1 | tail -n 1) || { echo "  ERROR cjson build failed"; rm -rf "$_tmp" 2>/dev/null || true; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" || exit 1
	cp -a "$_cd"/libcjson.so* "$STAGE/usr/lib64/" || exit 1
	rm -rf "$_tmp" 2>/dev/null || true
	pack "libcjson" "1.7.19" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_pipewire() {
	fresh_stage
	set -- $(gpkg_img "pipewire-1.6.8-8.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "pipewire" "1.6.8" '"xorg-libs"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_cxx_libs() {
	fresh_stage
	for _g in glibmm-2.66.8-8.gpkg.tar libsigc++-2.12.1-5.gpkg.tar cairomm-1.14.5-5.gpkg.tar pangomm-2.46.4-6.gpkg.tar atkmm-2.28.4-6.gpkg.tar gtkmm-3.24.11-1.gpkg.tar; do
		set -- $(gpkg_img "$_g")
		_tmp="$1"
		_img="$2"
		harvest_solist "$STAGE" "$_img" "usr/lib64"
		rm -rf "$_tmp" 2>/dev/null || true
	done
	pack "cxx-libs" "20261007" '"gtk-libs", "xorg-libs"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_waybar() {
	_src="${WAYBAR_STAGE:-/tmp/opencode/waybar-stage}"
	_bin="${WAYBAR_BIN:-/tmp/opencode/waybar/build/waybar}"
	[ -f "$_bin" ] || { echo "  ERROR waybar binary missing: $_bin"; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/etc/xdg/waybar" || exit 1
	cp -a "$_bin" "$STAGE/usr/bin/waybar" || exit 1
	chmod 755 "$STAGE/usr/bin/waybar" || exit 1
	if [ -d "$_src/etc/xdg/waybar" ]; then
		cp -a "$_src/etc/xdg/waybar/." "$STAGE/etc/xdg/waybar/" 2>/dev/null || true
	fi
	seed_postinstall "$STAGE" "/etc/xdg/waybar/config.jsonc .config/waybar/config.jsonc" "/etc/xdg/waybar/style.css .config/waybar/style.css"
	pack "waybar" "0.15.1" '"wl-libs", "gtk-libs", "gtk3", "mesa", "xorg-libs", "pipewire", "xkb-data", "cxx-libs"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_kitty() {
	_src="${KITTY_STAGE:-/tmp/opencode/kitty-stage}"
	[ -f "$_src/usr/bin/kitty" ] || { echo "  ERROR kitty staging missing: $_src"; exit 1; }
	fresh_stage
	cp -a "$_src/usr" "$STAGE/" || exit 1
	mkdir -p "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/128x128/apps" || exit 1
	printf '[Desktop Entry]\nType=Application\nName=kitty\nGenericName=Terminal\nComment=A fast, feature-rich, GPU-based terminal emulator\nTryExec=kitty\nExec=kitty\nIcon=kitty\nTerminal=false\nCategories=System;TerminalEmulator;\nStartupWMClass=kitty\n' > "$STAGE/usr/share/applications/kitty.desktop" || exit 1
	[ -f "$_src/usr/lib/kitty/logo/kitty-128.png" ] && cp -a "$_src/usr/lib/kitty/logo/kitty-128.png" "$STAGE/usr/share/icons/hicolor/128x128/apps/kitty.png" || true
	pack "kitty" "0.49.2" '"xorg-libs", "gtk-libs", "wl-libs", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_niri() {
	_src="${NIRI_SRCDIR:-/tmp/opencode/niri-stage}"
	_bin="$_src/usr/bin/niri"
	[ -f "$_bin" ] || { _bin="${NIRI_BIN:-/tmp/opencode/niri-root/bin/niri}"; }
	[ -f "$_bin" ] || { echo "  ERROR niri binary missing"; exit 1; }
	_res="${NIRI_RES:-$HOME/.cargo/git/checkouts/niri-980187e09d334e53/ed22699/resources}"
	fresh_stage
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/wayland-sessions" "$STAGE/usr/share/xdg-desktop-portal" "$STAGE/usr/share/doc/niri" || exit 1
	cp -a "$_bin" "$STAGE/usr/bin/niri" || exit 1
	chmod 755 "$STAGE/usr/bin/niri" || exit 1
	if [ -d "$_src/usr/share" ]; then
		cp -a "$_src/usr/share/." "$STAGE/usr/share/" 2>/dev/null || true
	fi
	[ -f "$_res/niri.desktop" ] && cp -a "$_res/niri.desktop" "$STAGE/usr/share/wayland-sessions/" || true
	[ -f "$_res/niri-portals.conf" ] && cp -a "$_res/niri-portals.conf" "$STAGE/usr/share/xdg-desktop-portal/" || true
	[ -f "$_res/default-config.kdl" ] && cp -a "$_res/default-config.kdl" "$STAGE/usr/share/doc/niri/" || true
	if [ -f "$STAGE/usr/share/doc/niri/default-config.kdl" ]; then
		mkdir -p "$STAGE/etc/skel/.config/niri" || exit 1
		cp -a "$STAGE/usr/share/doc/niri/default-config.kdl" "$STAGE/etc/skel/.config/niri/config.kdl" || exit 1
	fi
	seed_postinstall "$STAGE" "/usr/share/doc/niri/default-config.kdl .config/niri/config.kdl"
	pack "niri" "26.4.2" '"wl-libs", "gtk-libs", "mesa", "xorg-libs", "seatd", "pipewire", "xkb-data", "vulkan-loader"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_vulkan_loader() {
	fresh_stage
	set -- $(gpkg_img "vulkan-loader-1.4.350.0-2.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	rm -rf "$_tmp" 2>/dev/null || true
	pack "vulkan-loader" "1.4.350.0" '"mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_wlroots() {
	fresh_stage
	set -- $(gpkg_img "wlroots-0.20.2-2.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	rm -rf "$_tmp" 2>/dev/null || true
	set -- $(gpkg_img "libdisplay-info-0.3.0-8.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	harvest_bins "$STAGE" "$_img" di-edid-decode
	rm -rf "$_tmp" 2>/dev/null || true
	pack "wlroots" "0.20.2" '"xorg-libs", "mesa", "wl-libs", "seatd"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_scenefx() {
	_src="${SCENAFX_SYSROOT:-/tmp/opencode/wlsys}"
	[ -f "$_src/usr/lib64/libscenefx-0.5.so" ] || { echo "  ERROR scenefx lib missing: $_src"; exit 1; }
	fresh_stage
	mkdir -p "$STAGE/usr/lib64" || exit 1
	cp -a "$_src/usr/lib64"/libscenefx-0.5.so* "$STAGE/usr/lib64/" || exit 1
	pack "scenefx" "0.5" '"wlroots", "mesa"'
	rm -rf "$STAGE" 2>/dev/null || true
}

build_seatd() {
	fresh_stage
	set -- $(gpkg_img "seatd-0.9.3-r1-3.gpkg.tar")
	_tmp="$1"
	_img="$2"
	harvest_solist "$STAGE" "$_img" "usr/lib64"
	rm -rf "$_tmp" 2>/dev/null || true
	if [ -n "${SEATD_BUILD:-}" ] && [ -x "$SEATD_BUILD/seatd" ]; then
		mkdir -p "$STAGE/usr/bin" "$STAGE/etc/init.d" || exit 1
		cp -a "$SEATD_BUILD/seatd" "$STAGE/usr/bin/seatd" || exit 1
		[ -x "$SEATD_BUILD/seatd-launch" ] && cp -a "$SEATD_BUILD/seatd-launch" "$STAGE/usr/bin/seatd-launch" || true
		chmod 755 "$STAGE/usr/bin/seatd" 2>/dev/null || true
		[ -f "$STAGE/usr/bin/seatd-launch" ] && chmod 755 "$STAGE/usr/bin/seatd-launch" 2>/dev/null || true
		if command -v strip >/dev/null 2>&1; then
			strip "$STAGE/usr/bin/seatd" 2>/dev/null || true
		fi
		cat > "$STAGE/etc/init.d/seatd" <<'EOF'
#!/sbin/openrc-run
command=/usr/bin/seatd
command_args="-g seat"
pidfile=/run/seatd.pid
command_background="yes"
name="seat management daemon"
depend() {
	need localmount
	before elogind
}
start_pre() {
	mkdir -p /run/seatd 2>/dev/null || true
}
EOF
		chmod 755 "$STAGE/etc/init.d/seatd" || exit 1
	fi
	pack "seatd" "0.9.3" ''
	rm -rf "$STAGE" 2>/dev/null || true
}

build_mango() {
	_src="${MANGO_SRCDIR:-/tmp/opencode/mango-stage}"
	[ -f "$_src/usr/bin/mango" ] || { echo "  ERROR mango staging missing: $_src"; exit 1; }
	fresh_stage
	cp -a "$_src/usr" "$STAGE/" || exit 1
	[ -d "$_src/etc" ] && cp -a "$_src/etc" "$STAGE/" || true
	if [ -f "$STAGE/etc/mango/config.conf" ]; then
		mkdir -p "$STAGE/etc/skel/.config/mango" || exit 1
		cp -a "$STAGE/etc/mango/config.conf" "$STAGE/etc/skel/.config/mango/config.conf" || exit 1
	fi
	seed_postinstall "$STAGE" "/etc/mango/config.conf .config/mango/config.conf"
	pack "mango" "0.17.5.2" '"wlroots", "scenefx", "seatd", "wl-libs", "gtk-libs", "mesa", "xorg-libs", "xkb-data", "libcjson", "vulkan-loader"'
	rm -rf "$STAGE" 2>/dev/null || true
}

ALL_PKGS="gtk-libs wl-libs wofi rofi"

if [ "$1" = "all" ]; then
	shift
	set -- $ALL_PKGS "$@"
fi
for _p in "$@"; do
	# one name per package, add new ones here too
	case "$_p" in
		gtk-libs) build_gtk_libs ;;
		wl-libs) build_wl_libs ;;
		wofi) build_wofi ;;
		rofi) build_rofi ;;
		alacritty) build_alacritty ;;
		gtk3) build_gtk3 ;;
		libcjson) build_libcjson ;;
		vulkan-loader) build_vulkan_loader ;;
		pipewire) build_pipewire ;;
		cxx-libs) build_cxx_libs ;;
		waybar) build_waybar ;;
		niri) build_niri ;;
		kitty) build_kitty ;;
		wlroots) build_wlroots ;;
		scenefx) build_scenefx ;;
		seatd) build_seatd ;;
		mango) build_mango ;;
		*) usage ;;
	esac
done
