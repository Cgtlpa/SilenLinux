#!/bin/bash
# bundles kernel headers for nvidia module builds on the target
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! make-headers-bundle stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

KVER="${KVER:-$(ls -d rootfs/lib/modules/[0-9]* 2>/dev/null | head -n1 | xargs basename 2>/dev/null)}"
SRC="${KERNEL_SRC:-}"
OUT="${OUT:-headers-${KVER}.tar.zst}"

usage() {
	echo "usage: KERNEL_SRC=/path/to/build-tree [KVER=6.18.54-silen] ./scripts/make-headers-bundle.sh" >&2
	echo "  KERNEL_SRC must be the EXACT tree that built the running kernel" >&2
	echo "  (same source, same .config, same Module.symvers - check with" >&2
	echo "  scripts/nvidia-check.sh and by comparing Module.symvers CRCs)." >&2
	echo "  A foreign tree produces modules the kernel refuses to load." >&2
	echo "  Output $OUT is picked up by scripts/build.sh onto the ISO" >&2
	echo "  and unpacked by the installer to /usr/src + /lib/modules/<kver>/{build,source}." >&2
	exit 1
}

[ -n "$KVER" ] || usage
[ -n "$SRC" ] || usage
[ -d "$SRC" ] || { echo "  ERROR KERNEL_SRC missing: $SRC" >&2; usage; }
[ -f "$SRC/Makefile" ] || { echo "  ERROR $SRC has no Makefile (not a kernel tree?)" >&2; exit 1; }
[ -f "$SRC/.config" ] || { echo "  ERROR $SRC/.config missing" >&2; exit 1; }
[ -f "$SRC/Module.symvers" ] || { echo "  ERROR $SRC/Module.symvers missing (full kernel build first)" >&2; exit 1; }
[ -d "$SRC/include" ] || { echo "  ERROR $SRC/include missing" >&2; exit 1; }
command -v zstd >/dev/null 2>&1 || { echo "  ERROR zstd not found"; exit 1; }

STAGE_BASE="${TMPDIR:-/tmp/opencode}"
mkdir -p "$STAGE_BASE" || exit 1
STAGE="$(mktemp -d "$STAGE_BASE/stage.XXXXXX" 2>/dev/null || echo "$STAGE_BASE/stage.$$")"
mkdir -p "$STAGE/usr/src/linux-$KVER" || exit 1

tar -C "$SRC" --exclude=.git --exclude=./.git --exclude=Documentation --exclude=./Documentation --exclude=samples --exclude=./samples -cf - . | tar -C "$STAGE/usr/src/linux-$KVER" -xf - || exit 1
T="$STAGE/usr/src/linux-$KVER"
find "$T" \( -name '*.o' -o -name '*.ko' -o -name '*.cmd' \) -not -path '*/scripts/*' -not -path '*/tools/objtool/*' -not -path '*/tools/bpf/*' -delete 2>/dev/null || true
find "$T" -name '*.a' -not -path '*/tools/*' -delete 2>/dev/null || true
rm -rf "$T/.tmp_versions" "$T/.cache" "$T/firmware" 2>/dev/null || true
rm -rf "$T/tools" 2>/dev/null || true
mkdir -p "$T/tools" || exit 1
for keep in objtool bpf; do
	[ -e "$SRC/tools/$keep" ] || continue
	mkdir -p "$T/tools" || exit 1
	cp -a "$SRC/tools/$keep" "$T/tools/" || exit 1
done
rm -f "$T/vmlinux" "$T/vmlinux."* "$T/System.map" "$T/.version" "$T/modules.order" "$T/modules.builtin"* 2>/dev/null || true
rm -f "$T/certs/signing_key.pem" "$T/certs/signing_key.x509" 2>/dev/null || true
# never ship private signing keys, the target makes its own
rm -rf "$T/conftest" "$T/.nvidia_conftest"* 2>/dev/null || true
if command -v pahole >/dev/null 2>&1; then
	_pahole="$(command -v pahole)"
	mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib64" || exit 1
	cp -a "$_pahole" "$STAGE/usr/bin/pahole" 2>/dev/null || echo "  ! cannot bundle pahole (target BTF builds need it)"
	for _lib in $(ldd "$_pahole" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true); do
		case "$(basename "$_lib")" in
			libdwarves*) cp -a "$_lib" "$STAGE/usr/lib64/" 2>/dev/null || true ;;
		esac
	done || true
else
	echo "  ! pahole not found (target BTF module builds need it)"
fi

tar -C "$STAGE" -I 'zstd -19' -cf "$OUT" usr || { echo "  ERROR tar failed (disk full?)"; exit 1; }
rm -rf "$STAGE" 2>/dev/null || true
echo "headers bundle: $(du -h "$OUT" | cut -f1) -> $OUT"
echo "build the ISO with this file in the repo root, then: spk get nvidia-drivers"
