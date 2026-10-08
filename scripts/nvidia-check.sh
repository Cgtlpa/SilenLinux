#!/bin/bash
# dumps nvidia state into a file for bug reports
out="${1:-/dev/stdout}"

{
echo "===== silen-nvidia-check ====="
echo "kernel ---"
uname -r 2>/dev/null
echo "kernel headers ---"
# without headers the proprietary module cant compile, thats the usual failure
_kver="$(uname -r 2>/dev/null)"
if [ -d "/lib/modules/$_kver/build" ]; then
	echo "headers: /lib/modules/$_kver/build present"
else
	echo "headers: MISSING /lib/modules/$_kver/build (proprietary nvidia module cannot compile without them)"
fi
ls -d /usr/src/* 2>/dev/null || echo "no /usr/src entries"
echo "build tools ---"
for _t in gcc make ld; do
	if command -v "$_t" >/dev/null 2>&1; then
		echo "$_t: $(command -v "$_t")"
	else
		echo "$_t: missing"
	fi
done
echo "pci vga/3d controllers ---"
if command -v lspci >/dev/null 2>&1; then
	lspci 2>/dev/null | grep -iE "vga|3d|display" || echo "none shown"
	for d in /sys/bus/pci/devices/*; do
		[ -f "$d/class" ] || continue
		case "$(cat "$d/class" 2>/dev/null)" in
			0x0300*|0x0302*) _drv="$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"; echo "$(basename "$d"): vendor=$(cat "$d/vendor" 2>/dev/null) device=$(cat "$d/device" 2>/dev/null) driver=${_drv:-none}" ;;
		esac
	done
else
	echo "lspci unavailable"
fi
echo "loaded gpu modules ---"
if command -v lsmod >/dev/null 2>&1; then
	lsmod 2>/dev/null | grep -iE "^nvidia|^nouveau|nvidia_modeset|nvidia_uvm|nvidia_drm" || echo "no nvidia/nouveau modules loaded"
else
	echo "lsmod unavailable"
fi
echo "nvidia-smi ---"
if command -v nvidia-smi >/dev/null 2>&1; then
	nvidia-smi 2>&1 | head -n 25
else
	echo "nvidia-smi not on PATH"
fi
for _p in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /opt/spk/nvidia-drivers/bin/nvidia-smi; do
	[ -x "$_p" ] && echo "found: $_p"
done
echo "spk nvidia record ---"
for _r in /var/lib/spk/packages/nvidia-drivers/version "$HOME/.local/share/spk/packages/nvidia-drivers/version"; do
	[ -f "$_r" ] && echo "$_r: $(cat "$_r" 2>/dev/null)"
done
ls -d /var/lib/spk/packages/nvidia-drivers /opt/spk/nvidia-drivers /spk_pkgs/nvidia-drivers 2>/dev/null || echo "no nvidia spk records/dirs"
echo "modinfo nvidia ---"
if command -v modinfo >/dev/null 2>&1; then
	modinfo nvidia 2>&1 | head -n 12 || echo "modinfo nvidia failed (module not built for this kernel?)"
else
	echo "modinfo unavailable"
fi
echo "kernel nvidia/nouveau messages ---"
_dmsg="$(dmesg 2>/dev/null | grep -iE "nvidia|nouveau|NVRM|Xid" | tail -n 40)"; if [ -n "$_dmsg" ]; then printf "%s\n" "$_dmsg"; else echo "dmesg unavailable or no matches"; fi
echo "blacklists ---"
# a stray blacklist line is enough to keep the driver from loading
grep -rH . /etc/modprobe.d/ 2>/dev/null | grep -iE "nvidia|nouveau|blacklist" || echo "no nvidia/nouveau modprobe rules"
echo "===== end ====="
} > "$out" 2>&1
[ "$out" != "/dev/stdout" ] && echo "wrote $out"
