#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! mkspk-dbus-config stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND)" >&2' ERR

PKGDIR="${PKGDIR:-spk-pkgs/packages}"
DBUS_VERSION="${DBUS_VERSION:-1.16.2-silen1}"

STAGE="$(mktemp -d /tmp/opencode/dbus-config.XXXXXX 2>/dev/null || echo /tmp/opencode/dbus-config.$$)"
mkdir -p "$STAGE" || exit 1

mkdir -p "$STAGE/usr/share/dbus-1" "$STAGE/usr/lib/spk" "$STAGE/var/lib/dbus" || exit 1

# ---------------------------------------------------------------- /usr/share/dbus-1/session.conf
# Standard D-Bus session bus config - missing from the dbus spk package.
# Without this, dbus-launch/dbus-run-session cannot start a session bus.
cat > "$STAGE/usr/share/dbus-1/session.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <!-- The session/bus configuration file for the session bus -->
  <type>session</type>
  <auth>EXTERNAL</auth>
  <listen>unix:path=/var/run/dbus/system_bus_socket</listen>
  <standard_system_servicedirs/>
  <standard_session_servicedirs/>
  <policy context="default">
    <allow user="*"/>
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow send_type="method_call"/>
    <allow send_type="signal"/>
    <allow send_type="method_return"/>
    <allow send_type="error"/>
    <allow own="*"/>
    <allow autocreate="*"/>
  </policy>
</busconfig>
EOF
chmod 644 "$STAGE/usr/share/dbus-1/session.conf" || exit 1

# ---------------------------------------------------------------- postinstall hook
cat > "$STAGE/usr/lib/spk/postinstall" <<'EOF'
#!/bin/sh
# dbus-config postinstall: ensure D-Bus session bus can start
R="${SPK_ROOT:-/}"
[ "$R" = "/" ] && R=""

# Ensure machine-id exists for D-Bus
if [ -z "$R" ]; then
    [ -f /etc/machine-id ] || dbus-uuidgen --ensure >/dev/null 2>&1 || true
    [ -f /var/lib/dbus/machine-id ] || { mkdir -p /var/lib/dbus; cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true; }
else
    [ -f "${R}etc/machine-id" ] || chroot "$R" dbus-uuidgen --ensure >/dev/null 2>&1 || true
    [ -f "${R}var/lib/dbus/machine-id" ] || { mkdir -p "${R}var/lib/dbus"; cp "${R}etc/machine-id" "${R}var/lib/dbus/machine-id" 2>/dev/null || true; }
fi

# Run ldconfig if needed
if [ -z "$R" ]; then
    command -v ldconfig >/dev/null 2>&1 && ldconfig >/dev/null 2>&1 || true
else
    command -v ldconfig >/dev/null 2>&1 && ldconfig -r "$R" >/dev/null 2>&1 || true
fi

exit 0
EOF
chmod 755 "$STAGE/usr/lib/spk/postinstall" || exit 1

# ---------------------------------------------------------------- Build package
tar -czpf "$PKGDIR/dbus-config/dbus-config.spk" -C "$STAGE" . || { echo "  ERROR tar failed"; rm -rf "$STAGE"; exit 1; }
_s="$(sha256sum "$PKGDIR/dbus-config/dbus-config.spk" | awk '{print $1}')"
printf '{"filename": "dbus-config.spk", "parts": 1, "sha256": "%s", "system": true, "version": "%s", "depends": ["dbus"], "category": "system", "description": "D-Bus session bus configuration: session.conf and machine-id setup"}' "$_s" "$DBUS_VERSION" > "$PKGDIR/dbus-config/package.json"
echo "dbus-config $DBUS_VERSION $(du -h "$PKGDIR/dbus-config/dbus-config.spk" | cut -f1)"
rm -rf "$STAGE" 2>/dev/null || true