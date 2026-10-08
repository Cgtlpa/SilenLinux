#!/bin/bash
# prebuilds the nvidia kernel modules so the iso can carry them
set -e
set -E
set -o pipefail
KVER="${1:-}"
HEADERS_TAR="${2:-}"
NVIDIA_RUN="${3:-}"
OUT_TAR="${4:-}"
[ -n "$KVER" ] || { echo "  ERROR build-nvidia-kmods: missing KVER"; exit 1; }
[ -f "$HEADERS_TAR" ] || { echo "  ERROR build-nvidia-kmods: headers not found $HEADERS_TAR"; exit 1; }
[ -f "$NVIDIA_RUN" ] || { echo "  ERROR build-nvidia-kmods: .run not found $NVIDIA_RUN"; exit 1; }
[ -n "$OUT_TAR" ] || { echo "  ERROR build-nvidia-kmods: missing OUT_TAR"; exit 1; }
command -v gcc >/dev/null 2>&1 || { echo "  ERROR build-nvidia-kmods: gcc not found"; exit 1; }
command -v make >/dev/null 2>&1 || { echo "  ERROR build-nvidia-kmods: make not found"; exit 1; }
command -v zstd >/dev/null 2>&1 || { echo "  ERROR build-nvidia-kmods: zstd not found"; exit 1; }
command -v strip >/dev/null 2>&1 || { echo "  ERROR build-nvidia-kmods: strip not found"; exit 1; }
_TMPBASE="/tmp"
if [ -d build ]; then
	_TMPBASE="$(pwd)/build"
else
	mkdir -p build 2>/dev/null || true
	[ -d build ] && _TMPBASE="$(pwd)/build"
fi
_HDR="$(mktemp -d "$_TMPBASE/silen-nv-hdr.XXXXXX" 2>/dev/null || echo $_TMPBASE/silen-nv-hdr.$$)"
_SRC="$(mktemp -d "$_TMPBASE/silen-nv-src.XXXXXX" 2>/dev/null || echo $_TMPBASE/silen-nv-src.$$)"
_STAGE="$(mktemp -d "$_TMPBASE/silen-nv-stage.XXXXXX" 2>/dev/null || echo $_TMPBASE/silen-nv-stage.$$)"
_LOG="$_TMPBASE/nvidia-kmods-build.log"
rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true
mkdir -p "$_HDR" "$_SRC" "$_STAGE" || { echo "  ERROR build-nvidia-kmods: cannot create temp dirs"; exit 1; }
case "$HEADERS_TAR" in
	*.tar.zst) tar --use-compress-program=unzstd -xf "$HEADERS_TAR" -C "$_HDR" || { echo "  ERROR build-nvidia-kmods: headers unpack failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; } ;;
	*.tar.gz|*.tgz) tar -xzf "$HEADERS_TAR" -C "$_HDR" || { echo "  ERROR build-nvidia-kmods: headers unpack failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; } ;;
	*.tar.xz) tar -xJf "$HEADERS_TAR" -C "$_HDR" || { echo "  ERROR build-nvidia-kmods: headers unpack failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; } ;;
	*) tar -xf "$HEADERS_TAR" -C "$_HDR" || { echo "  ERROR build-nvidia-kmods: headers unpack failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; } ;;
esac
[ -f "$_HDR/usr/src/linux-$KVER/Makefile" ] || { echo "  ERROR build-nvidia-kmods: $_HDR/usr/src/linux-$KVER/Makefile missing"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
sh "$NVIDIA_RUN" -x --target "$_SRC/nv" >/dev/null 2>&1 || { echo "  ERROR build-nvidia-kmods: .run extract failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
[ -d "$_SRC/nv/kernel" ] || { echo "  ERROR build-nvidia-kmods: kernel sources missing in .run"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
_JOBS="$(nproc 2>/dev/null || echo 4)"
make -C "$_SRC/nv/kernel" SYSSRC="$_HDR/usr/src/linux-$KVER" SYSOUT="$_HDR/usr/src/linux-$KVER" -j"$_JOBS" modules >"$_LOG" 2>&1 || { echo "  ERROR build-nvidia-kmods: kernel module build failed (see $_LOG)"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
mkdir -p "$_STAGE/lib/modules/$KVER/updates" || { echo "  ERROR build-nvidia-kmods: cannot create stage dir"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
for _ko in "$_SRC/nv/kernel/nvidia.ko" "$_SRC/nv/kernel/nvidia-uvm.ko" "$_SRC/nv/kernel/nvidia-modeset.ko" "$_SRC/nv/kernel/nvidia-drm.ko" "$_SRC/nv/kernel/nvidia-peermem.ko"; do
	[ -f "$_ko" ] || { echo "  ERROR build-nvidia-kmods: missing $(basename "$_ko")"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
	cp "$_ko" "$_STAGE/lib/modules/$KVER/updates/" || { echo "  ERROR build-nvidia-kmods: cannot stage $(basename "$_ko")"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
done
find "$_STAGE/lib/modules" -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null || true
# stamp the versions in so the installer knows what its unpacking
_NV_VER="$(basename "$NVIDIA_RUN" | sed -n 's/^nvidia-\(.*\)\.run$/\1/p')"
[ -n "$_NV_VER" ] || _NV_VER="unknown"
printf '%s\n' "$_NV_VER" > "$_STAGE/nvidia-version" || { echo "  ERROR build-nvidia-kmods: cannot write version"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
printf '%s\n' "$KVER" > "$_STAGE/nvidia-kver" || { echo "  ERROR build-nvidia-kmods: cannot write kver"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
mkdir -p "$(dirname "$OUT_TAR")" || { echo "  ERROR build-nvidia-kmods: cannot create out dir"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
tar -C "$_STAGE" -I 'zstd -19' -cf "$OUT_TAR" . || { echo "  ERROR build-nvidia-kmods: tar failed"; rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true; exit 1; }
rm -rf "$_HDR" "$_SRC" "$_STAGE" 2>/dev/null || true
echo "  nvidia kmods prebuilt: $(du -h "$OUT_TAR" | cut -f1) -> $OUT_TAR"
