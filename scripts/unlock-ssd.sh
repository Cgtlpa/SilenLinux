#!/bin/bash
# removes the do-not-touch mark again, --temp only unlocks for this boot
set -e
if [[ "$(id -u)" != "0" ]]; then
	exec sudo "$0" "$@"
fi
_mark=".silen-lock"
_temp=0
_d=""
for _a in "$@"; do
	if [[ "$_a" = "--temp" ]]; then
		_temp=1
		continue
	fi
	if [[ -b "$_a" ]]; then
		_d="$_a"
	fi
done
_allow_live() {
	local _b="${1##*/}"
	mkdir -p /tmp /run 2>/dev/null || true
	touch "/tmp/.silen-unlock-$_b" 2>/dev/null || true
	touch "/run/silen-unlock-$_b" 2>/dev/null || true
	echo "unlocked for this session: $1"
}
_unlock_part() {
	local _p="$1"
	local _t=""
	_t="$(mktemp -d /tmp/.silen-unlock.XXXXXX 2>/dev/null || echo /tmp/.silen-unlock.$$)"
	mkdir -p "$_t" 2>/dev/null || true
	if mount -o rw "$_p" "$_t" 2>/dev/null; then
		rm -f "$_t/$_mark" 2>/dev/null || true
		sync 2>/dev/null || true
		umount "$_t" 2>/dev/null || true
		rmdir "$_t" 2>/dev/null || true
		return 0
	fi
	rmdir "$_t" 2>/dev/null || true
	return 1
}
if [[ -n "$_d" ]]; then
	# unlocking one disk, --temp skips touching the disk itself
	if [[ "$_temp" = "1" ]]; then
		_allow_live "$_d"
		exit 0
	fi
	for _p in "${_d}"[0-9]* "${_d}"p[0-9]*; do
		[[ -b "$_p" ]] || continue
		_unlock_part "$_p" || true
	done || true
	_allow_live "$_d"
	exit 0
fi
if [[ "$_temp" = "1" ]]; then
	mkdir -p /tmp /run 2>/dev/null || true
	touch /tmp/.silen-unlock-all 2>/dev/null || true
	touch /run/silen-unlock-all 2>/dev/null || true
	echo "unlocked all for this session"
	exit 0
fi
rm -f "/boot/efi/$_mark" "/boot/$_mark" 2>/dev/null || true
sync 2>/dev/null || true
echo "unlocked /boot/efi /boot"
exit 0
