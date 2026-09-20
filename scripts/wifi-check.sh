#!/bin/bash

out="${1:-/dev/stdout}"

{
echo "===== silen-wifi-check ====="
echo "kernel ---"
uname -r 2>/dev/null
echo "wifi modules loaded ---"
if command -v lsmod >/dev/null 2>&1; then
	lsmod 2>/dev/null | grep -iE "iwl|cfg80211|mac80211|ath|rtw|rtl8|rtl_|mt76|mt79|brcm|b43|mwifiex|libertas|rsi|wfx|wilc|zd12|carl9170|ar5523|rfkill" || echo "no wifi modules loaded"
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
			0x0280*) echo "$(basename "$d"): class 0280 vendor=$(cat "$d/vendor" 2>/dev/null) device=$(cat "$d/device" 2>/dev/null) driver=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null || echo none)" ;;
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
dmesg 2>/dev/null | grep -iE "firmware|wlan|wifi|iwl|cfg80211|regulatory|rtw|mt76|mt79|ath1|brcmfmac|b43|mwifiex|80211|wpa_supplicant|NetworkManager|probe|failed|error|blocked|rfkill" | tail -n 50 || echo "dmesg unavailable"
echo "NetworkManager devices ---"
if command -v nmcli >/dev/null 2>&1; then
	nmcli -t device status 2>/dev/null || echo "nmcli device status failed is NetworkManager running"
	echo "NetworkManager wifi scan cached ---"
	nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null | head -n 25 || echo "wifi scan unavailable"
	echo "NM radio ---"
	nmcli radio all 2>/dev/null || true
else
	echo "nmcli unavailable"
fi
echo "wpa_supplicant ---"
ls /run/wpa_supplicant 2>/dev/null || echo "/run/wpa_supplicant empty/missing"
if command -v pgrep >/dev/null 2>&1; then
	pgrep -a wpa_supplicant 2>/dev/null || echo "wpa_supplicant not running"
else
	ps 2>/dev/null | grep -i "[w]pa_supplicant" || echo "wpa_supplicant not running"
fi
echo "dbus activation helper ---"
ls -l /usr/lib/dbus-daemon-launch-helper /usr/libexec/dbus-daemon-launch-helper 2>/dev/null || echo "no helper found"
echo "NM wifi plugin ---"
ls /usr/lib/NetworkManager/libnm-device-plugin-wifi.so 2>/dev/null || echo "wifi plugin missing"
echo "===== end ====="
} > "$out" 2>&1
[ "$out" != "/dev/stdout" ] && echo "wrote $out"
