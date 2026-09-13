#!/bin/sh
set -e

echo "Installer started"
title="Silen installer"

whiptail --msgbox  --title "$title" "Silen linux installer (this script is still in early development errors may accur " 10 40

internet=$(whiptail --yesno --title "$title" "would you like to connect to the internet?" 8 40 3>&2 1>&2 2>&3)
main_installer() {
	echo "worked"
	partition=$(whiptail --title "$title" --menu 10 49 \
		"1" "Install Silen" \
		"2" "Shell"\
		"3" "Reboot" \
		3>&1 1>&2 2>&3)
}

if [ "$internet" = "yes" ]; then
echo "idk but it worked"

else 
	main_installer

fi
