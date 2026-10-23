#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-fontconfig-base stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
FC_VERSION="${FC_VERSION:-2.18.3-silen1}"

STAGE="$(mktemp -d /tmp/opencode/fontconfig-base.XXXXXX 2>/dev/null || echo /tmp/opencode/fontconfig-base.$$)"
mkdir -p "$STAGE" || exit 1

mkdir -p "$STAGE/etc/fonts" "$STAGE/etc/fonts/conf.d" "$STAGE/var/cache/fontconfig" || exit 1

# ---------------------------------------------------------------- /etc/fonts/fonts.conf
cat > "$STAGE/etc/fonts/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <cachedir>/var/cache/fontconfig</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>
  <include ignore_missing="yes">/etc/fonts/conf.d</include>
  <include ignore_missing="yes" prefix="xdg">fontconfig/conf.d</include>
  <include ignore_missing="yes" prefix="xdg">fontconfig/fonts.conf</include>
</fontconfig>
EOF
chmod 644 "$STAGE/etc/fonts/fonts.conf" || exit 1

# ---------------------------------------------------------------- Generic alias rules
cat > "$STAGE/etc/fonts/conf.d/49-silen-generics.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <!-- Fix hyphen-split name parsing: "sans-serif" -> "sans", "system-ui" -> "system" -->
  <match target="pattern">
    <test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="assign" binding="strong"><string>sans-serif</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans</string></test>
    <edit name="family" mode="assign" binding="strong"><string>sans-serif</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>serif</string></test>
    <edit name="family" mode="assign" binding="strong"><string>serif</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="assign" binding="strong"><string>mono</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>mono</string></test>
    <edit name="family" mode="assign" binding="strong"><string>mono</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>system-ui</string></test>
    <edit name="family" mode="assign" binding="strong"><string>system-ui</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>system</string></test>
    <edit name="family" mode="assign" binding="strong"><string>system-ui</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>emoji</string></test>
    <edit name="family" mode="assign" binding="strong"><string>emoji</string></edit>
  </match>
  <!-- Font family preferences -->
  <alias>
    <family>sans-serif</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer><family>Noto Serif</family><family>DejaVu Serif</family></prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer><family>JetBrains Mono</family><family>Noto Sans Mono</family><family>DejaVu Sans Mono</family></prefer>
  </alias>
  <alias>
    <family>system-ui</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>emoji</family>
    <prefer><family>Noto Color Emoji</family></prefer>
  </alias>
</fontconfig>
EOF
chmod 644 "$STAGE/etc/fonts/conf.d/49-silen-generics.conf" || exit 1

# ---------------------------------------------------------------- Common family aliases
cat > "$STAGE/etc/fonts/conf.d/30-silen-common-families.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias>
    <family>Helvetica</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Helvetica Neue</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Arial</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Roboto</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Segoe UI</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Cantarell</family>
    <prefer><family>Noto Sans</family><family>DejaVu Sans</family></prefer>
  </alias>
  <alias>
    <family>Font Awesome</family>
    <prefer><family>Noto Sans</family><family>Symbols Nerd Font Mono</family></prefer>
  </alias>
  <alias>
    <family>FontAwesome</family>
    <prefer><family>Noto Sans</family><family>Symbols Nerd Font Mono</family></prefer>
  </alias>
</fontconfig>
EOF
chmod 644 "$STAGE/etc/fonts/conf.d/30-silen-common-families.conf" || exit 1

# ---------------------------------------------------------------- Emoji alias
cat > "$STAGE/etc/fonts/conf.d/50-silen-emoji.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias>
    <family>emoji</family>
    <prefer><family>Noto Color Emoji</family></prefer>
  </alias>
  <match target="pattern">
    <test name="family"><string>emoji</string></test>
    <edit name="family" mode="assign" binding="strong"><string>emoji</string></edit>
  </match>
</fontconfig>
EOF
chmod 644 "$STAGE/etc/fonts/conf.d/50-silen-emoji.conf" || exit 1

# ---------------------------------------------------------------- Build package
tar -czpf "$PKGDIR/fontconfig-base/fontconfig-base.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/fontconfig-base/fontconfig-base.spk" | awk '{print $1}')"
printf '{"filename": "fontconfig-base.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": [], "category": "x11-libs", "description": "Fontconfig default configuration and font alias rules"}' "$_s" "$FC_VERSION" > "$PKGDIR/fontconfig-base/package.json"
echo "fontconfig-base $FC_VERSION $(du -h "$PKGDIR/fontconfig-base/fontconfig-base.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true