main_screen() {
	men1=$(whiptail --title "$title" --menu "Choose an option" 15 53 4 \
		"1" "Install Silen" \
		"2" "Shell" \
		"3" "Reboot" \
		"4" "Power off" \
		3>&1 1>&2 2>&3 || true)

	if [[ "$men1" = "1" ]]; then
		partitioning
	elif [[ "$men1" = "2" ]]; then
		sh || true
		main_screen
	elif [[ "$men1" = "3" ]]; then
		sync 2>/dev/null || true
		reboot -f 2>/dev/null || whiptail --msgbox --title "$title" "Reboot failed. Press Ctrl+Alt+Del or hold the power button." 8 60 || true
		main_screen
	elif [[ "$men1" = "4" ]]; then
		sync 2>/dev/null || true
		poweroff -f 2>/dev/null || whiptail --msgbox --title "$title" "Power off failed. Hold the power button." 8 60 || true
		main_screen
	else
		main_screen
	fi
}
