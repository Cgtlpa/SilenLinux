#!/bin/bash

set -e

title="Silen Linux"
ROOT_PATH="/silen"

# ultraviolet whiptail theme
export NEWT_COLORS='
root=black,black
window=magenta,black
border=magenta,black
shadow=black,black
title=magenta,black
button=magenta,black
actbutton=white,magenta
checkbox=magenta,black
actcheckbox=white,magenta
entry=magenta,black
label=magenta,black
listbox=magenta,black
actlistbox=white,magenta
menu=magenta,black
actmenu=white,magenta
radiolist=magenta,black
actradiolist=white,magenta
checklist=magenta,black
actchecklist=white,magenta
textbox=magenta,black
acttextbox=white,magenta
helptag=magenta,black
roottext=magenta,black
'

if [[ ! -d /sys/firmware/efi ]]; then
	printf "Silen Linux installs in UEFI mode only.\nReboot and pick the UEFI entry for the USB drive.\nPowering off...\n"
	sleep 3

	poweroff -f
fi

_here="$(dirname "$0" 2>/dev/null || echo /installer)"
[[ -d "$_here/lib" ]] || _here="/installer"

for _l in 00-common 10-medium 20-ui 30-partition 40-base 50-settings 60-system 70-payloads 75-extras 90-grub; do
	_f="$_here/lib/$_l.sh"
	[[ -f "$_f" ]] || { echo "installer component missing: $_l.sh" >&2; exit 1; }
	. "$_f"
done

trap cleanup EXIT
trap on_int_term INT TERM

[[ "$(id -u)" = "0" ]] || {
	whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
	exit 1
}

whiptail --msgbox --title "$title" "Welcome to the Silen Linux installer!\n\nUEFI system detected. Choose Install to wipe a disk and install Silen." 11 60 2>/dev/null || true

main_screen
