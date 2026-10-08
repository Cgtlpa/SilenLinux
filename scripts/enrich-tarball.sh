#!/bin/bash
# stuffs sudo + wifi tools into tarball-silen.xz, skips what the installer already brings
# usage: ./scripts/enrich-tarball.sh [tarball] [--with-git]
set -e
set -E
set -o pipefail

TARBALL="${1:-tarball-silen.xz}"
case "$TARBALL" in --*) TARBALL="tarball-silen.xz" ;; esac
WITH_GIT=0
for a in "$@"; do [ "$a" = "--with-git" ] && WITH_GIT=1; done

[ -f "$TARBALL" ] || { echo "ERROR: $TARBALL not found"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "ERROR: tar not found"; exit 1; }
command -v xz >/dev/null 2>&1 || { echo "ERROR: xz not found"; exit 1; }
command -v ldd >/dev/null 2>&1 || { echo "ERROR: ldd not found"; exit 1; }

TOP=""
set +o pipefail
TOP="$(tar -tf "$TARBALL" 2>/dev/null | head -n1 | cut -d/ -f1)"
set -o pipefail
[ -n "$TOP" ] || { echo "ERROR: cannot read top dir of $TARBALL"; exit 1; }
echo "== enrich-tarball: $TARBALL (top: $TOP) =="

WORK="$(mktemp -d /tmp/enrich-tarball.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "  extracting (218M, takes a bit)..."
tar -xf "$TARBALL" -C "$WORK"
STAGE="$WORK/$TOP"
[ -d "$STAGE/usr/bin" ] || { echo "ERROR: $STAGE/usr/bin missing, unexpected layout"; exit 1; }
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib64" "$STAGE/usr/libexec" "$STAGE/etc"

copy_libs() {
    local bin="$1" lib
    while IFS= read -r lib; do
        lib="$(printf '%s' "$lib" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$lib" in /*) ;; *) continue ;; esac
        case "$lib" in *linux-vdso*|*linux-gate*) continue ;; esac
        [ -e "$lib" ] || { echo "  ! lib $lib (needed by $bin) not on host, skipping"; continue; }
        bn="$(basename "$lib")"
        if [ -e "$STAGE/usr/lib64/$bn" ] || [ -e "$STAGE/usr/lib/$bn" ]; then continue; fi
        cp -a "$lib" "$STAGE/usr/lib64/" 2>/dev/null \
            && echo "  + lib $bn" \
            || echo "  ! cannot copy lib $lib"
    done < <(ldd "$bin" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true)
}

add_tool() {
    local name="$1" src=""
    src="$(command -v "$name" 2>/dev/null || true)"
    [ -n "$src" ] && [ -f "$src" ] || { echo "  ! $name not on host, skipping"; return 0; }
    if [ -e "$STAGE/usr/bin/$name" ]; then echo "  = $name already in tarball"; return 0; fi
    tmp="$(mktemp)"
    cp -a "$src" "$tmp" 2>/dev/null || { echo "  ! cannot read $src"; rm -f "$tmp"; return 0; }
    chmod 755 "$tmp" 2>/dev/null || true
    cp -a "$src" "$STAGE/usr/bin/$name" 2>/dev/null || { echo "  ! cannot stage $name"; rm -f "$tmp"; return 0; }
    chmod 755 "$STAGE/usr/bin/$name" 2>/dev/null || true
    copy_libs "$tmp"
    rm -f "$tmp"
    echo "  + $name"
}

for t in lspci lsusb iw; do add_tool "$t"; done
[ "$WITH_GIT" = "1" ] && add_tool git || true

if [ -e "$STAGE/usr/bin/sudo" ]; then
    echo "  = sudo already in tarball"
else
    # host sudo is execute-only so read it through sudo itself if plain cp fails
    _sudo_src="${SUDO_SRC:-/usr/bin/sudo}"
    if [ -f "$_sudo_src" ] || [ -n "$SUDO_SRC" ]; then
        tmp="$(mktemp)"
        if ! cp -a "$_sudo_src" "$tmp" 2>/dev/null; then
            if sudo -n true 2>/dev/null; then
                sudo -n cat "$_sudo_src" > "$tmp" 2>/dev/null || true
            else
                echo "  (need sudo password to read $_sudo_src)"
                sudo cat "$_sudo_src" > "$tmp" 2>/dev/null || true
            fi
        fi
        if [ -s "$tmp" ]; then
            chmod 755 "$tmp" 2>/dev/null || true
            cp -a "$tmp" "$STAGE/usr/bin/sudo" && chmod 4755 "$STAGE/usr/bin/sudo" \
                && echo "  + sudo (setuid)" \
                || echo "  ! cannot stage sudo"
            copy_libs "$tmp"
        else
            echo "  ! cannot read /usr/bin/sudo, skipping binary (plugins kept)"
        fi
        rm -f "$tmp"
        if [ -d /usr/libexec/sudo ]; then
            mkdir -p "$STAGE/usr/libexec/sudo"
            for plug in sudoers.so libsudo_util.so libsudo_util.so.0 libsudo_util.so.0.0.0; do
                [ -f "/usr/libexec/sudo/$plug" ] || continue
                [ -e "$STAGE/usr/libexec/sudo/$plug" ] && continue
                cp -a "/usr/libexec/sudo/$plug" "$STAGE/usr/libexec/sudo/" 2>/dev/null \
                    && echo "  + sudo plugin $plug" || true
            done
            if [ -f "$STAGE/usr/libexec/sudo/sudoers.so" ]; then
                copy_libs "$STAGE/usr/libexec/sudo/sudoers.so"
            fi
        fi
        if [ ! -f "$STAGE/etc/sudoers" ]; then
            cat > "$STAGE/etc/sudoers" <<'EOF'
root ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL
@includedir /etc/sudoers.d
EOF
            chmod 0440 "$STAGE/etc/sudoers" 2>/dev/null || true
            mkdir -p "$STAGE/etc/sudoers.d" && chmod 755 "$STAGE/etc/sudoers.d" 2>/dev/null || true
            echo "  + /etc/sudoers (root + %wheel)"
        else
            echo "  = /etc/sudoers already present"
        fi
    else
        echo "  ! /usr/bin/sudo not on host, skipping"
    fi
fi

BACKUP="${TARBALL}.bak"
if [ -f "$BACKUP" ]; then
    echo "  backup kept: $BACKUP"
else
    cp -a "$TARBALL" "$BACKUP" && echo "  backup: $BACKUP"
fi
echo "  repacking with xz (takes a bit)..."
tar -cJf "$WORK/new-tarball.xz" -C "$WORK" "$TOP" \
    || { echo "ERROR: repack failed"; exit 1; }
mv "$WORK/new-tarball.xz" "$TARBALL"
trap - EXIT
rm -rf "$WORK"

echo "  done: $(du -h "$TARBALL" | cut -f1) $TARBALL"
echo "  verify:"
set +o pipefail
tar -tf "$TARBALL" 2>/dev/null | grep -E "/(sudo|lspci|lsusb|iw|git)$|/sudoers$" | head
set -o pipefail
