#!/bin/bash

# UI functions for the installer using custom text-based UI (no whiptail)

# Source the UI library
. "$(dirname "$0")/ui.sh"

main_screen() {
	# Unattended mode: skip the menu and go straight to install.
	if [[ "${SILEN_AUTO:-}" = "1" ]]; then
		men1="1"
	else
		ui_menu "$title" "Choose an option" \
			"Install Silen" "Start the installation process" \
			"Shell" "Open a root shell" \
			"Reboot" "Restart the system" \
			"Power off" "Shut down the system"
		men1=$?
	fi

	if [[ "$men1" = "1" ]]; then
		# Check internet connectivity before starting installation
		if ! ensure_internet; then
			ui_msg "$title" "Internet connection is required for installation.\nPlease configure networking and try again." "error"
			main_screen
			return
		fi
		partitioning
	elif [[ "$men1" = "2" ]]; then
		sh || true
		main_screen
	elif [[ "$men1" = "3" ]]; then
		sync 2>/dev/null || true
		reboot -f 2>/dev/null || { ui_msg "$title" "Reboot failed. Press Ctrl+Alt+Del or hold the power button." "error"; main_screen; }
	elif [[ "$men1" = "4" ]]; then
		sync 2>/dev/null || true
		poweroff -f 2>/dev/null || { ui_msg "$title" "Power off failed. Hold the power button." "error"; main_screen; }
	else
		main_screen
	fi
}

# Progress/info box replacement for whiptail --infobox
show_infobox() {
	local msg="$1"
	ui_info "$title" "$msg"
}

# Message box replacement for whiptail --msgbox
show_msgbox() {
	local msg="$1"
	local type="${2:-info}"
	ui_msg "$title" "$msg" "$type"
}

# Yes/No confirmation
show_confirm() {
	local msg="$1"
	ui_confirm "$title" "$msg"
}

# Input box replacement
show_input() {
	local prompt="$1" default="${2:-}"
	ui_input "$title" "$prompt" "$default"
}

# Password box replacement
show_password() {
	local prompt="$1"
	ui_password "$title" "$prompt"
}