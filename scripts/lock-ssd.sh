#!/bin/bash
# marks a disk as do-not-touch so the installer skips it
set -e
if [[ "$(id -u)" != "0" ]]; then
	exec sudo "$0" "$@"
fi
_mark=".silen-lock"
_lock_part() {
	local _p="$1"
	local _t=""
	_t="$(mktemp -d /tmp/.silen-lock.XXXXXX 2>/dev/null || echo /tmp/.silen-lock.$$)"
	mkdir -p "$_t" 2>/dev/null || true
	if mount -o rw "$_p" "$_t" 2>/dev/null; then
		touch "$_t/$_mark" 2>/dev/null || true
		sync 2>/dev/null || true
		umount "$_t" 2>/dev/null || true
		rmdir "$_t" 2>/dev/null || true
		return 0
	fi
	rmdir "$_t" 2>/dev/null || true
	return 1
}
if [[ $# -ge 1 && -b "$1" ]]; then
	# got a disk arg so lock all its partitions
	_d="$1"
	_hit=0
	for _p in "${_d}"[0-9]* "${_d}"p[0-9]*; do
		[[ -b "$_p" ]] || continue
		if _lock_part "$_p"; then
			echo "locked $_p"
			_hit=1
		fi
	done || true
	if [[ "$_hit" = "1" ]]; then
		exit 0
	fi
	echo "lock-ssd: no partitions locked on $_d" >&2
	exit 1
fi
_hit=0
if [[ -d "/boot/efi" ]]; then
	touch "/boot/efi/$_mark" 2>/dev/null || true
	if [[ -f "/boot/efi/$_mark" ]]; then
		echo "locked /boot/efi"
		_hit=1
	fi
fi
if [[ -d "/boot" ]]; then
	touch "/boot/$_mark" 2>/dev/null || true
	if [[ -f "/boot/$_mark" ]]; then
		echo "locked /boot"
		_hit=1
	fi
fi
if [[ "$_hit" = "1" ]]; then
	exit 0
fi
echo "lock-ssd: usage lock-ssd [/dev/sdX]" >&2
exit 1
