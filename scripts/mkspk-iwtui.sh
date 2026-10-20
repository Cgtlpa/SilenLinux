#!/bin/bash
# pack iwtui binary into spk file
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-iwtui stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
IWTUI_SRC="${IWTUI_SRC:-}"
IWTUI_BIN="${IWTUI_BIN:-}"

usage() {
	echo "usage: mkspk-iwtui.sh [--src DIR] [--bin PATH]" >&2
	echo "  builds the iwtui spk from a local iwtui checkout" >&2
	echo "  env: IWTUI_SRC=/path/to/iwtui IWTUI_BIN=/path/to/iwtui" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--src) IWTUI_SRC="$2"; shift 2 ;;
		--bin) IWTUI_BIN="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) usage ;;
	esac
done

if [[ -z "$IWTUI_BIN" ]]; then
	if [[ -n "$IWTUI_SRC" ]]; then
		for cand in "$IWTUI_SRC/target/release/iwtui"; do
			if [[ -x "$cand" ]]; then
				IWTUI_BIN="$cand"
				break
			fi
		done
	fi
	for cand in "$HOME/.cargo/bin/iwtui" "/usr/local/bin/iwtui"; do
		if [[ -x "$cand" ]]; then
			IWTUI_BIN="$cand"
			break
		fi
	done
fi
if [[ -z "$IWTUI_BIN" ]] || [[ ! -f "$IWTUI_BIN" ]]; then
	echo "  ERROR iwtui binary not found" >&2
	echo "  build it first: cd \$IWTUI_SRC && cargo build --release" >&2
	echo "  or set IWTUI_BIN=/path/to/iwtui" >&2
	exit 1
fi

# version comes from cargo or binary
IWTUI_VERSION="0.1.0"
if [[ -n "$IWTUI_SRC" && -f "$IWTUI_SRC/Cargo.toml" ]]; then
	IWTUI_VERSION="$(grep -m1 '^version' "$IWTUI_SRC/Cargo.toml" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')"
	[[ -n "$IWTUI_VERSION" ]] || IWTUI_VERSION="0.1.0"
fi

STAGE="$(mktemp -d /tmp/opencode/iwtstage.XXXXXX 2>/dev/null || echo /tmp/opencode/iwtstage.$$)"
mkdir -p "$STAGE" || exit 1
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib/spk" || exit 1

cp -a "$IWTUI_BIN" "$STAGE/usr/bin/iwtui" || exit 1
chmod 755 "$STAGE/usr/bin/iwtui" || exit 1
if command -v strip >/dev/null 2>&1; then
	strip "$STAGE/usr/bin/iwtui" 2>/dev/null || true
fi

# leaf app needs no postinstall
mkdir -p "$STAGE/usr/lib/spk" || exit 1
cat > "$STAGE/usr/lib/spk/postinstall" <<'EOF'
#!/bin/sh
# iwtui postinstall - nothing special needed
exit 0
EOF
chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1


mkdir -p "$PKGDIR/iwtui" || exit 1
_members=""
for _m in usr; do
	[ -e "$STAGE/$_m" ] || continue
	_members="$_members $_m"
done
[ -n "$_members" ] || { echo "  ERROR empty payload for iwtui"; exit 1; }
tar -czpf "$PKGDIR/iwtui/iwtui.spk" -C "$STAGE" $_members || { echo "  ERROR tar failed"; exit 1; }
_s="$(sha256sum "$PKGDIR/iwtui/iwtui.spk" | awk '{print $1}')"
printf '{"filename": "%s.spk", "parts": 1, "sha256": "%s", "system": false, "version": "%s", "depends": []}' "iwtui" "$_s" "$IWTUI_VERSION" > "$PKGDIR/iwtui/package.json"
echo "iwtui $IWTUI_VERSION $(du -h "$PKGDIR/iwtui/iwtui.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true