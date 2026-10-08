#!/bin/bash
# old text installer, kept around as reference, the live iso uses the gui one
set -e

title="Silen Linux"
ROOT_PATH="/silen"

if [[ ! -d /sys/firmware/efi ]]; then
	printf "Powering off system...\n"
	sleep 0.1

	poweroff -f
fi

_here="$(dirname "$0" 2>/dev/null || echo /installer)"
[[ -d "$_here/lib" ]] || _here="/installer"

for _l in 00-common 10-medium 20-ui 30-partition 40-base 50-settings 60-system 70-payloads 90-grub; do
	# libs load in order, dont reshuffle them
	_f="$_here/lib/$_l.sh"
	[[ -f "$_f" ]] || { echo "Wtf is that? installer lib missing: $_l.sh" >&2; exit 1; }
	. "$_f"
done

trap cleanup EXIT
# always clean up the mounts even if the user bails out
trap on_int_term INT TERM

[[ "$(id -u)" = "0" ]] || {
	whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
	exit 1
}

whiptail --msgbox --title "$title" "welcome to the Silen Linux installer!" 10 40 2>/dev/null || true

main_screen
