#!/bin/bash

out="${1:-/dev/stdout}"

{
echo "===== silen-wifi-check ====="
echo "kernel ---"
uname -r 2>/dev/null
echo "wifi modules loaded ---"
if command -v lsmod >/dev/null 2>&1; then
	lsmod 2>/dev/null | grep -iE "iwl|cfg80211|mac80211|ath|rtw|rtl8|rtl_|rtlwifi|mt76|mt79|brcm|b43|mwifiex|libertas|rsi|wfx|wilc|wl12|wl18|wlcore|mwl8k|p54|at76|rt2|rt6|zd12|carl9170|ar5523|rfkill" || echo "no wifi modules loaded"
else
	echo "lsmod unavailable"
fi
echo "interfaces ---"
ip link 2>/dev/null || echo "ip unavailable"
echo "rfkill ---"
if command -v rfkill >/dev/null 2>&1; then
	rfkill list 2>/dev/null || echo "rfkill list failed"
else
	echo "rfkill tool missing"
fi
echo "pci network controllers ---"
if command -v lspci >/dev/null 2>&1; then
	lspci 2>/dev/null | grep -iE "network|wireless|wlan|wifi|bluetooth" || echo "none shown"
	for d in /sys/bus/pci/devices/*; do
		[ -f "$d/class" ] || continue
		case "$(cat "$d/class" 2>/dev/null)" in
			0x0280*) _drv="$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"; echo "$(basename "$d"): class 0280 vendor=$(cat "$d/vendor" 2>/dev/null) device=$(cat "$d/device" 2>/dev/null) driver=${_drv:-none}" ;;
		esac
	done
else
	echo "lspci unavailable"
fi
echo "usb devices ---"
if command -v lsusb >/dev/null 2>&1; then
	lsusb 2>/dev/null | head -n 25
else
	echo "lsusb unavailable"
fi
echo "kernel wifi/firmware messages ---"
_dmsg="$(dmesg 2>/dev/null | grep -iE "firmware|wlan|wifi|iwl|cfg80211|regulatory|rtw|mt76|mt79|ath1|brcmfmac|b43|mwifiex|80211|iwd|probe|failed|error|blocked|rfkill" | tail -n 50)"; if [ -n "$_dmsg" ]; then printf "%s\n" "$_dmsg"; else echo "dmesg unavailable or no matches"; fi
echo "iwd daemon ---"
for _iwd in /usr/libexec/iwd /usr/sbin/iwd /usr/bin/iwd; do
	[ -x "$_iwd" ] || continue
	echo "daemon: $_iwd ($("$_iwd" --version 2>/dev/null || echo version-unknown))"
	break
done
if command -v pgrep >/dev/null 2>&1; then
	pgrep -a iwd 2>/dev/null || echo "iwd not running"
else
	ps 2>/dev/null | grep -i "[i]wd" || echo "iwd not running"
fi
echo "iwd config ---"
cat /etc/iwd/main.conf 2>/dev/null || echo "/etc/iwd/main.conf missing"
echo "known networks ---"
ls /var/lib/iwd 2>/dev/null || echo "/var/lib/iwd empty/missing"
echo "iwctl devices ---"
if command -v iwctl >/dev/null 2>&1; then
	iwctl device list 2>/dev/null || echo "iwctl device list failed (is iwd running?)"
	echo "iwctl station ---"
	_dev="$(iwctl device list 2>/dev/null | awk '$2 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ {print $1; exit}')"
	if [ -n "$_dev" ]; then
		iwctl station "$_dev" show 2>/dev/null || echo "station show failed"
		echo "iwctl scan (cached, no rescan) ---"
		iwctl station "$_dev" get-networks 2>/dev/null | head -n 25 || echo "scan list unavailable"
	else
		echo "no station device found"
	fi
else
	echo "iwctl unavailable"
fi
echo "dbus activation helper ---"
{ ls -l /usr/lib/dbus-daemon-launch-helper 2>/dev/null || true; ls -l /usr/libexec/dbus-daemon-launch-helper 2>/dev/null || true; } | grep -q . || echo "no helper found"
echo "iwd dbus policy ---"
ls /usr/share/dbus-1/system.d/iwd-dbus.conf 2>/dev/null || echo "iwd-dbus.conf missing"
echo "===== end ====="
} > "$out" 2>&1
[ "$out" != "/dev/stdout" ] && echo "wrote $out"
