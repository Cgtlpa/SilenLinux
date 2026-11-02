#!/bin/bash
set -e
set -E
set -o pipefail

SRC="${BASE_ROOT:-/tmp/opencode/base-root}"
DEST="${1:-build/packages/silen-base/root}"
[ -d "$SRC" ] || { echo "ERROR base root $SRC not found"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
rsync -aHAX --numeric-ids "$SRC"/ "$DEST"/

for path in \
	usr/lib/python3.14 \
	usr/lib/python \
	usr/lib/python-exec \
	usr/lib/gcc \
	usr/libexec/gcc \
	usr/x86_64-pc-linux-gnu \
	usr/include \
	usr/share/doc \
	usr/share/man \
	usr/share/info \
	usr/share/groff \
	usr/share/texi2any \
	usr/share/sgml \
	usr/share/locale \
	usr/share/cmake \
	usr/share/autoconf-2.72 \
	usr/share/automake-1.18 \
	usr/share/automake-1.18.1 \
	usr/share/aclocal \
	usr/share/aclocal-1.18 \
	usr/share/libtool \
	usr/share/gcc-data \
	usr/share/binutils-data \
	usr/share/gettext \
	usr/share/gettext-0.23.2 \
	usr/share/gtk-doc \
	usr/share/elt-patches \
	usr/share/bison \
	usr/share/texinfo \
	usr/share/gdb \
	usr/share/re2c \
	usr/share/gnuconfig \
	usr/share/eselect \
	usr/share/unimaps \
	usr/share/consoletrans \
	usr/share/awk \
	usr/share/vim \
	usr/share/nano \
	usr/share/zsh \
	usr/share/fish \
	usr/share/openpgp-keys \
	usr/share/gcc-config \
	usr/share/pkgconfig \
	usr/share/sandbox \
	usr/share/ss \
	usr/share/xtables \
	usr/share/et \
	usr/share/tabset \
	usr/share/polkit-1 \
	usr/share/libgpg-error \
	usr/share/gnupg \
	usr/lib64/*.a \
	usr/lib/*.a \
; do
	[ -e "$DEST/$path" ] || continue
	rm -rf "$DEST/$path"
done

for pattern in \
	'usr/bin/python*' \
	'usr/bin/perl*' \
	'usr/bin/pydoc*' \
	'usr/bin/2to3*' \
	'usr/bin/cpan*' \
	'usr/bin/corelist*' \
	'usr/bin/enc2xs*' \
	'usr/bin/encguess' \
	'usr/bin/piconv' \
	'usr/bin/pod*' \
	'usr/bin/prove' \
	'usr/bin/pstruct' \
	'usr/bin/ptar*' \
	'usr/bin/shasum' \
	'usr/bin/json_pp' \
	'usr/bin/instmodsh' \
	'usr/bin/perlbug' \
	'usr/bin/perldoc' \
	'usr/bin/perlivp' \
	'usr/bin/perlthanks' \
	'usr/bin/splain' \
	'usr/bin/xsubpp' \
	'usr/bin/zipdetails' \
	'usr/bin/gcc*' \
	'usr/bin/g++*' \
	'usr/bin/cc' \
	'usr/bin/c++' \
	'usr/bin/cpp*' \
	'usr/bin/gfortran*' \
	'usr/bin/gcov*' \
	'usr/bin/gprof' \
	'usr/bin/addr2line' \
	'usr/bin/ar' \
	'usr/bin/as' \
	'usr/bin/ld' \
	'usr/bin/ld.bfd' \
	'usr/bin/ld.gold' \
	'usr/bin/nm' \
	'usr/bin/objcopy' \
	'usr/bin/objdump' \
	'usr/bin/ranlib' \
	'usr/bin/readelf' \
	'usr/bin/size' \
	'usr/bin/strings' \
	'usr/bin/strip' \
	'usr/bin/elfedit' \
	'usr/bin/make' \
	'usr/bin/gmake' \
	'usr/bin/cmake' \
	'usr/bin/ctest' \
	'usr/bin/cpack' \
	'usr/bin/ccmake' \
	'usr/bin/ninja' \
	'usr/bin/ninja-reference' \
	'usr/bin/bison' \
	'usr/bin/yacc' \
	'usr/bin/flex' \
	'usr/bin/flex++' \
	'usr/bin/autoconf*' \
	'usr/bin/autoheader*' \
	'usr/bin/autom4te*' \
	'usr/bin/automake*' \
	'usr/bin/autopoint' \
	'usr/bin/autoreconf*' \
	'usr/bin/autoscan*' \
	'usr/bin/autoupdate*' \
	'usr/bin/aclocal*' \
	'usr/bin/libtool*' \
	'usr/bin/gettext*' \
	'usr/bin/msgfmt' \
	'usr/bin/msgmerge' \
	'usr/bin/msgunfmt' \
	'usr/bin/xgettext' \
	'usr/bin/ngettext' \
	'usr/bin/gdb*' \
	'usr/bin/strace' \
	'usr/bin/ltrace' \
	'usr/bin/perf' \
	'usr/bin/re2c' \
	'usr/bin/re2go' \
	'usr/bin/re2rust' \
	'usr/bin/troff' \
	'usr/bin/groff*' \
	'usr/bin/nroff' \
	'usr/bin/grotty' \
	'usr/bin/grops' \
	'usr/bin/gropdf' \
	'usr/bin/grodvi' \
	'usr/bin/grolbp' \
	'usr/bin/grolj4' \
	'usr/bin/gdiffmk' \
	'usr/bin/geqn' \
	'usr/bin/gpinyin' \
	'usr/bin/grn' \
	'usr/bin/grem' \
	'usr/bin/glilypond' \
	'usr/bin/gperl' \
	'usr/bin/grap2graph' \
	'usr/bin/grodvi' \
	'usr/bin/groff' \
	'usr/bin/gtroff' \
	'usr/bin/pdfroff' \
	'usr/bin/pfbtops' \
	'usr/bin/preconv' \
	'usr/bin/psbb' \
	'usr/bin/soelim' \
	'usr/bin/tbl' \
	'usr/bin/eqn' \
	'usr/bin/neqn' \
	'usr/bin/pic' \
	'usr/bin/refer' \
	'usr/bin/vgrind' \
; do
	for f in $DEST/$pattern; do
		[ -e "$f" ] || [ -L "$f" ] || continue
		rm -rf "$f"
	done
done

mkdir -p "$DEST/etc/silen" "$DEST/usr/local/bin" "$DEST/var/lib/iwd" "$DEST/var/lib/dhcpcd" "$DEST/run/dbus" "$DEST/var/cache/cres"
cp target-scripts/silen-mkinitramfs "$DEST/usr/local/bin/silen-mkinitramfs"
chmod 755 "$DEST/usr/local/bin/silen-mkinitramfs"
BUSYBOX_TMP="$(mktemp -d)"
trap 'rm -rf "$BUSYBOX_TMP"' EXIT
tar -xzf /tmp/opencode/localrepo/packages/busybox/busybox.spk -C "$BUSYBOX_TMP" 2>/dev/null || tar -xf /tmp/opencode/localrepo/packages/busybox/busybox.spk -C "$BUSYBOX_TMP"
cp "$BUSYBOX_TMP/bin/busybox" "$DEST/usr/bin/busybox"
chmod 755 "$DEST/usr/bin/busybox"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$DEST/etc/resolv.conf"
printf 'silen\n' > "$DEST/etc/hostname"
printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\tsilen\n' > "$DEST/etc/hosts"
printf 'en_US.UTF-8 UTF-8\nC.UTF-8 UTF-8\n' > "$DEST/etc/locale.gen"
printf '\ndenyinterfaces wlan*\n' >> "$DEST/etc/dhcpcd.conf"
printf 'hostname="silen"\n' > "$DEST/etc/conf.d/hostname"
printf 'keymap="us"\n' > "$DEST/etc/conf.d/keymaps"
printf 'TIMEZONE="UTC"\n' > "$DEST/etc/conf.d/timezone" 2>/dev/null || true

if [ -x "$DEST/usr/bin/localedef" ]; then
	mkdir -p "$DEST/usr/lib/locale"
	"$DEST/usr/bin/localedef" --prefix "$DEST" -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1 || true
fi

if [ ! -e "$DEST/etc/init.d/dbus" ]; then
	printf '#!/sbin/openrc-run\ndescription="D-Bus system message bus"\ncommand=/usr/bin/dbus-daemon\ncommand_args="--system --nofork --nopidfile"\npidfile=/run/dbus/pid\ncommand_background=true\n' > "$DEST/etc/init.d/dbus"
	chmod 755 "$DEST/etc/init.d/dbus"
fi

mkdir -p "$DEST/etc/runlevels/boot"
ln -sfn /etc/init.d/dbus "$DEST/etc/runlevels/boot/dbus"
mkdir -p "$DEST/etc/runlevels/default"
ln -sfn /etc/init.d/dhcpcd "$DEST/etc/runlevels/default/dhcpcd"
ln -sfn /etc/init.d/local "$DEST/etc/runlevels/default/local"

du -sh "$DEST"
