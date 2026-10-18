#!/bin/bash

set -e

title="Silen Linux"
ROOT_PATH="/silen"

# Ultraviolet whiptail theme (magenta monochrome, inverted selection).
export NEWT_COLORS='
root=black,black
window=magenta,black
border=magenta,black
shadow=black,black
title=magenta,black
button=magenta,black
actbutton=black,magenta
checkbox=magenta,black
actcheckbox=black,magenta
entry=magenta,black
label=magenta,black
listbox=magenta,black
actlistbox=black,magenta
textbox=magenta,black
acttextbox=black,magenta
helptag=magenta,black
roottext=magenta,black
'

if [[ ! -d /sys/firmware/efi ]]; then
	printf "Powering off system...\n"
	sleep 0.1

	poweroff -f
fi

_here="$(dirname "$0" 2>/dev/null || echo /installer)"
[[ -d "$_here/lib" ]] || _here="/installer"

for _l in 00-common 10-medium 20-ui 30-partition 40-base 50-settings 60-system 70-payloads 75-extras 90-grub; do
	_f="$_here/lib/$_l.sh"
	[[ -f "$_f" ]] || { echo "Wtf is that? installer lib missing: $_l.sh" >&2; exit 1; }
	. "$_f"
done

trap cleanup EXIT
trap on_int_term INT TERM

[[ "$(id -u)" = "0" ]] || {
	whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
	exit 1
}

whiptail --msgbox --title "$title" "welcome to the Silen Linux installer!" 10 40 2>/dev/null || true

main_screen
