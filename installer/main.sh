#!/bin/sh
set -e

echo "Installer started"
title="Silen installer"

whiptail --msgbox --title "$title" "Silen linux installer (this script is still in early development errors may accur)" 10 40

main_screen() {
    echo "worked"
    partition=$(whiptail --title "$title" --menu "Choose an option:" 10 49 3 \
        "1" "Install Silen" \
        "2" "Shell" \
        "3" "Reboot" \
        3>&1 1>&2 2>&3)
}

if whiptail --yesno --title "$title" "Would you like to connect to the internet?" 8 40; then
    nmtui
    main_screen
else 
    main_screen
fi