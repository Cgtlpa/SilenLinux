#!/bin/bash
# builds iwd from source so the iso has wifi even if the host dont
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! iwd build stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

ELL_VERSION="${ELL_VERSION:-0.83}"
IWD_VERSION="${IWD_VERSION:-3.12}"
ELL_URL="${ELL_URL:-https://kernel.org/pub/linux/libs/ell/ell-$ELL_VERSION.tar.gz}"
IWD_URL="${IWD_URL:-https://kernel.org/pub/linux/network/wireless/iwd-$IWD_VERSION.tar.gz}"
IWD_ROOT="${IWD_ROOT:-build/iwd-root}"
IWD_SRC="${IWD_SRC:-}"
WORK="build/iwd-src"
LOG="$WORK/build.log"

for cmd in gcc make pkg-config curl tar; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "  ERROR $cmd not found (needed to compile iwd) install it first"
		exit 1
	fi
done

if ! pkg-config --exists readline 2>/dev/null && [ ! -f /usr/include/readline/readline.h ]; then
	echo "  ERROR no readline dev files (iwctl cannot compile)"
	echo "  Install them first e.g. on Fedora sudo dnf install readline-devel"
	echo "  or on Arch sudo pacman -S readline - then rerun this script"
	exit 1
fi

if ! mkdir -p "$WORK" 2>/dev/null; then
	echo "  ERROR cannot create $WORK (build/ is root-owned, leftover of a failed sudo build)"
	echo "  Fix it once then rerun: sudo rm -rf build"
	exit 1
fi
WORK_ABS="$(cd "$WORK" && pwd)"
LOG="$WORK_ABS/build.log"
: > "$LOG" 2>/dev/null || true

if [ -n "$IWD_SRC" ]; then
	echo "== Using caller-provided iwd tree $IWD_SRC =="
	[ -d "$IWD_SRC" ] || { echo "  ERROR IWD_SRC=$IWD_SRC is not a directory"; exit 1; }
	[ -x "$IWD_SRC/configure" ] || { echo "  ERROR no configure in IWD_SRC (need a release tarball tree)"; exit 1; }
	IWD_ABS="$(cd "$IWD_SRC" && pwd)"
else
	echo "== Fetching ell-$ELL_VERSION and iwd-$IWD_VERSION =="
	[ -f "$WORK/ell-$ELL_VERSION.tar.gz" ] || curl -sSL --max-time 120 -o "$WORK/ell-$ELL_VERSION.tar.gz" "$ELL_URL" || { echo "  ERROR cannot download $ELL_URL"; exit 1; }
	[ -f "$WORK/iwd-$IWD_VERSION.tar.gz" ] || curl -sSL --max-time 120 -o "$WORK/iwd-$IWD_VERSION.tar.gz" "$IWD_URL" || { echo "  ERROR cannot download $IWD_URL"; exit 1; }
	[ -d "$WORK/ell-$ELL_VERSION" ] || tar -xzf "$WORK/ell-$ELL_VERSION.tar.gz" -C "$WORK" || { echo "  ERROR cannot unpack ell"; exit 1; }
	[ -d "$WORK/iwd-$IWD_VERSION" ] || tar -xzf "$WORK/iwd-$IWD_VERSION.tar.gz" -C "$WORK" || { echo "  ERROR cannot unpack iwd"; exit 1; }
	IWD_ABS="$(cd "$WORK/iwd-$IWD_VERSION" && pwd)"
fi

ELL_ABS="$WORK_ABS/ell-$ELL_VERSION"
case "$IWD_ROOT" in
	/*) DEST_ABS="$IWD_ROOT" ;;
	*) DEST_ABS="$(pwd)/$IWD_ROOT" ;;
esac

echo "== Building ell-$ELL_VERSION =="
# ell first, iwd links against it statically so no extra lib needed later
if [ ! -f "$ELL_ABS/ell/.libs/libell.a" ]; then
	(
		cd "$ELL_ABS"
		rm -f config.cache config.status
		./configure --prefix=/usr --disable-shared --enable-static >>"$LOG" 2>&1 || { echo "  ERROR ell configure failed (see $LOG)"; exit 1; }
		make -j"$(nproc)" >>"$LOG" 2>&1 || { echo "  ERROR ell build failed (see $LOG)"; exit 1; }
	)
fi

echo "== Building iwd-$IWD_VERSION (static ell link, no runtime libell needed) =="
if [ ! -x "$IWD_ABS/src/iwd" ] || [ ! -x "$IWD_ABS/client/iwctl" ]; then
	(
		cd "$IWD_ABS"
		rm -f config.cache config.status
		export CPPFLAGS="$CPPFLAGS -I$ELL_ABS"
		export ELL_CFLAGS="-I$ELL_ABS"
		export ELL_LIBS="$ELL_ABS/ell/.libs/libell.a"
		./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
			--enable-external-ell --disable-systemd-service >>"$LOG" 2>&1 || { echo "  ERROR iwd configure failed (see $LOG)"; exit 1; }
		make -j"$(nproc)" >>"$LOG" 2>&1 || { echo "  ERROR iwd build failed (see $LOG)"; exit 1; }
	)
fi
[ -x "$IWD_ABS/src/iwd" ] || { echo "  ERROR iwd daemon did not build (see $LOG)"; exit 1; }
[ -x "$IWD_ABS/client/iwctl" ] || { echo "  ERROR iwctl did not build (need readline headers, see $LOG)"; exit 1; }

echo "== Installing to $IWD_ROOT =="
# plain make install into a staging dir, build.sh grabs it from there
rm -rf "$IWD_ROOT"
mkdir -p "$IWD_ROOT"
make -C "$IWD_ABS" DESTDIR="$DEST_ABS" install >>"$LOG" 2>&1 || { echo "  ERROR iwd install failed (see $LOG)"; exit 1; }

if [ -x "$IWD_ROOT/usr/libexec/iwd" ] && [ -x "$IWD_ROOT/usr/bin/iwctl" ]; then
	echo "  iwd:     $IWD_ROOT/usr/libexec/iwd"
	echo "  iwctl:   $IWD_ROOT/usr/bin/iwctl"
	echo "  policy:  $IWD_ROOT/usr/share/dbus-1/system.d/iwd-dbus.conf"
	echo
	echo "Done - ./scripts/build.sh picks this up automatically"
else
	echo "  ERROR expected files missing under $IWD_ROOT (see $LOG)"
	exit 1
fi
