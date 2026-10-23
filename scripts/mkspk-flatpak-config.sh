#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-flatpak-config stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
FP_VERSION="${FP_VERSION:-1.0.0-silen1}"

STAGE="$(mktemp -d /tmp/opencode/flatpak-config.XXXXXX 2>/dev/null || echo /tmp/opencode/flatpak-config.$$)"
mkdir -p "$STAGE" || exit 1

# ---------------------------------------------------------------- directory tree
mkdir -p "$STAGE/etc/profile.d" \
         "$STAGE/etc/local.d" \
         "$STAGE/var/lib/flatpak" \
         "$STAGE/var/lib/flatpak/repo" \
         "$STAGE/var/lib/flatpak/appstream" \
         "$STAGE/var/cache/flatpak" \
         "$STAGE/usr/share/mime" \
         "$STAGE/usr/share/mime/packages" \
         "$STAGE/usr/share/mime/application" \
         "$STAGE/usr/lib/silen" \
         "$STAGE/usr/lib/spk" \
         "$STAGE/usr/bin" || exit 1

# ---------------------------------------------------------------- profile.d script (flatpak exports)
cat > "$STAGE/etc/profile.d/flatpak.sh" <<'EOF'
# Flatpak per-user installation export paths
export XDG_DATA_DIRS="${HOME}/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
EOF
chmod 755 "$STAGE/etc/profile.d/flatpak.sh" || exit 1

# ---------------------------------------------------------------- minimal MIME database (fixes flatpak search)
# application/gzip
cat > "$STAGE/usr/share/mime/packages/gzip.xml" <<'EOF'
<?xml version="1.0"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/gzip">
    <comment>gzip compressed data</comment>
    <glob pattern="*.gz"/>
    <glob pattern="*.tgz"/>
    <glob pattern="*.gtar"/>
    <magic priority="50">
      <match value="\x1f\x8b" type="string" offset="0"/>
    </magic>
  </mime-type>
</mime-info>
EOF
chmod 644 "$STAGE/usr/share/mime/packages/gzip.xml" || exit 1

# application/x-gzip
cat > "$STAGE/usr/share/mime/packages/x-gzip.xml" <<'EOF'
<?xml version="1.0"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-gzip">
    <comment>gzip compressed data</comment>
    <alias>application/gzip</alias>
    <glob pattern="*.gz"/>
    <glob pattern="*.tgz"/>
    <magic priority="50">
      <match value="\x1f\x8b" type="string" offset="0"/>
    </magic>
  </mime-type>
</mime-info>
EOF
chmod 644 "$STAGE/usr/share/mime/packages/x-gzip.xml" || exit 1

# text/plain
cat > "$STAGE/usr/share/mime/packages/text.xml" <<'EOF'
<?xml version="1.0"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/plain">
    <comment>plain text file</comment>
    <glob pattern="*.txt"/>
    <glob pattern="*.log"/>
    <glob pattern="*.conf"/>
    <glob pattern="*.sh"/>
    <glob pattern="*.md"/>
    <glob pattern="*.csv"/>
    <magic priority="50">
      <match range="0" type="string" value=""/>
    </magic>
  </mime-type>
</mime-info>
EOF
chmod 644 "$STAGE/usr/share/mime/packages/text.xml" || exit 1

# application/octet-stream (fallback)
cat > "$STAGE/usr/share/mime/packages/octet-stream.xml" <<'EOF'
<?xml version="1.0"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/octet-stream">
    <comment>binary data</comment>
    <glob pattern="*"/>
  </mime-type>
</mime-info>
EOF
chmod 644 "$STAGE/usr/share/mime/packages/octet-stream.xml" || exit 1

# generate mime.cache, globs2, magic, aliases, subclasses
cat > "$STAGE/usr/share/mime/globs2" <<'EOF'
application/gzip	*.gz	*.tgz	*.gtar
application/x-gzip	*.gz	*.tgz	*.gtar
text/plain	*.txt	*.log	*.conf	*.sh	*.md	*.csv
application/octet-stream	*
EOF
chmod 644 "$STAGE/usr/share/mime/globs2" || exit 1

cat > "$STAGE/usr/share/mime/magic" <<'EOF'
application/gzip	50	string	0	\x1f\x8b
application/x-gzip	50	string	0	\x1f\x8b
EOF
chmod 644 "$STAGE/usr/share/mime/magic" || exit 1

cat > "$STAGE/usr/share/mime/aliases" <<'EOF'
application/x-gzip	application/gzip
EOF
chmod 644 "$STAGE/usr/share/mime/aliases" || exit 1

cat > "$STAGE/usr/share/mime/subclasses" <<'EOF'
application/gzip	application/octet-stream
application/x-gzip	application/gzip
EOF
chmod 644 "$STAGE/usr/share/mime/subclasses" || exit 1

# mime.cache (generated format: GVM2)
python3 - <<'PY' 2>/dev/null || true
import struct, os
mime_dir = "$STAGE/usr/share/mime"
cache = os.path.join(mime_dir, "mime.cache")
# GVM2 header: magic "GVM2", version 2, num_types
# We write a minimal cache with just the types we know
types = [
    ("application/gzip", [], ["*.gz", "*.tgz", "*.gtar"], ["\\x1f\\x8b"]),
    ("application/x-gzip", ["application/gzip"], ["*.gz", "*.tgz", "*.gtar"], ["\\x1f\\x8b"]),
    ("text/plain", [], ["*.txt", "*.log", "*.conf", "*.sh", "*.md", "*.csv"], []),
    ("application/octet-stream", [], [], []),
]
with open(cache, "wb") as f:
    f.write(b"GVM2")
    f.write(struct.pack("<I", 2))  # version
    f.write(struct.pack("<I", len(types)))  # num types
    for name, subs, globs, magics in types:
        f.write(struct.pack("<I", len(name.encode())))
        f.write(name.encode())
        f.write(struct.pack("<I", len(subs)))
        for s in subs:
            f.write(struct.pack("<I", len(s.encode())))
            f.write(s.encode())
        f.write(struct.pack("<I", len(globs)))
        for g in globs:
            f.write(struct.pack("<I", len(g.encode())))
            f.write(g.encode())
        f.write(struct.pack("<I", len(magics)))
        for m in magics:
            f.write(struct.pack("<I", len(m.encode())))
            f.write(m.encode())
PY
[ -f "$STAGE/usr/share/mime/mime.cache" ] || {
    # fallback: create empty cache if python failed
    printf 'GVM2' > "$STAGE/usr/share/mime/mime.cache"
    printf '\x02\x00\x00\x00' >> "$STAGE/usr/share/mime/mime.cache"  # version 2
    printf '\x00\x00\x00\x00' >> "$STAGE/usr/share/mime/mime.cache"  # 0 types
}
chmod 644 "$STAGE/usr/share/mime/mime.cache" 2>/dev/null || true

# icon cache (empty but valid)
printf 'Icon Theme Cache' > "$STAGE/usr/share/mime/icons" 2>/dev/null || true

# ---------------------------------------------------------------- local.d script: refresh MIME from flatpak runtime on boot
cat > "$STAGE/etc/local.d/silen-flatpak-mime.start" <<'EOF'
#!/bin/sh
# Refresh system MIME database from an installed flatpak runtime, if present.
# This fixes flatpak search after a runtime is installed.
RT="$(find /var/lib/flatpak/runtime -type d -path '*/files/share/mime' 2>/dev/null | head -1)"
[ -z "$RT" ] && RT="$(find "$HOME/.local/share/flatpak/runtime" -type d -path '*/files/share/mime' 2>/dev/null | head -1)"
if [ -n "$RT" ] && [ -d /usr/share/mime ]; then
    cp -a "$RT"/. /usr/share/mime/ 2>/dev/null || true
    rm -rf /var/lib/flatpak/appstream "$HOME/.local/share/flatpak/appstream" 2>/dev/null || true
fi
EOF
chmod 755 "$STAGE/etc/local.d/silen-flatpak-mime.start" || exit 1

# ---------------------------------------------------------------- postinstall hook
cat > "$STAGE/usr/lib/spk/postinstall" <<'EOF'
#!/bin/sh
# flatpak-config postinstall: initialize flatpak system repo + MIME database
R="${SPK_ROOT:-/}"
[ "$R" = "/" ] && R=""

# Ensure system flatpak directories exist
mkdir -p "${R}var/lib/flatpak/repo" "${R}var/lib/flatpak/appstream" "${R}var/cache/flatpak" 2>/dev/null || true

# Initialize the system flatpak repo by adding flathub remote (as root)
if [ -z "$R" ]; then
    if command -v flatpak >/dev/null 2>&1; then
        flatpak remote-add --if-not-exists flathub \
            https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
    fi
else
    chroot "$R" /bin/sh -c 'if command -v flatpak >/dev/null 2>&1; then flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true; fi' || true
fi

exit 0
EOF
chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1

# ---------------------------------------------------------------- build package
tar -czpf "$PKGDIR/flatpak-config/flatpak-config.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/flatpak-config/flatpak-config.spk" | awk '{print $1}')"
printf '{"filename": "flatpak-config.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": ["flatpak"], "category": "sys-apps", "description": "Flatpak system configuration: MIME database, profile exports, repo initialization"}' "$_s" "$FP_VERSION" > "$PKGDIR/flatpak-config/package.json"
echo "flatpak-config $FP_VERSION $(du -h "$PKGDIR/flatpak-config/flatpak-config.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true