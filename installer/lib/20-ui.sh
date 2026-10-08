# the text menu, install shell or reboot and nothing else
main_screen() {
	men1=$(whiptail --title "$title" --menu "Choose an option" 14 53 3 \
		"1" "Install Silen" \
		"2" "Shell" \
		"3" "Reboot" \
		3>&1 1>&2 2>&3 || true)

	if [[ "$men1" = "1" ]]; then
		partitioning
	elif [[ "$men1" = "2" ]]; then
		sh || true
		main_screen
	elif [[ "$men1" = "3" ]]; then
		sync 2>/dev/null || true
		reboot -f 2>/dev/null || whiptail --msgbox --title "$title" "reboot failed run reboot -f or force off your machine" 8 60 || true
		main_screen
	else
		main_screen
	fi
}
