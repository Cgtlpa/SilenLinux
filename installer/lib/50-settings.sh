# asks for hostname users passwords and the rest
ask-install-settings() {
	hostnm="silen"
	hostnm=$(whiptail --title "$title" --inputbox "Set the hostname" 8 40 "$hostnm" 3>&1 1>&2 2>&3 || true)
	[[ -z "$hostnm" ]] && hostnm="silen"
	hostnm="$(printf '%s' "$hostnm" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
	[[ -z "$hostnm" ]] && hostnm="silen"

	rootpass=""
	while :; do
		if ! rootpass=$(whiptail --title "$title" --passwordbox "Set the root password" 8 40 3>&1 1>&2 2>&3); then
			return 1
		fi
		[[ -n "$rootpass" ]] || { whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true; continue; }
		case "$rootpass" in
			*:*|*$'\n'* )
				whiptail --msgbox --title "$title" "password can't contain : or newline, try again" 8 50 || true
				rootpass=""
				continue
				;;
		esac
		break
	done

	newuser=""
	userpass=""
	if whiptail --title "$title" --yesno "Create a user account?" 8 50; then
		while :; do
			newuser=$(whiptail --title "$title" --inputbox "Username for the new account if (empty = skip):" 8 50 3>&1 1>&2 2>&3 || true)
			[[ -z "$newuser" ]] && break
			if [[ "$newuser" = "root" ]]; then
				whiptail --msgbox --title "$title" "root already exists choose another username" 8 40 || true
				newuser=""
				continue
			fi
			case "$newuser" in
				[a-z_]*)
					case "$newuser" in
						*[!a-z0-9_-]*)
							whiptail --msgbox --title "$title" "only lowercase letters, digits, _ and - allowed" 8 50 || true
							newuser=""
							continue
							;;
					esac
					if [[ "${#newuser}" -gt 32 ]]; then
						whiptail --msgbox --title "$title" "username too long max 32" 8 40 || true
						newuser=""
						continue
					fi
					;;
				*)
					whiptail --msgbox --title "$title" "must start with a lowercase letter or dash" 8 50 || true
					newuser=""
					continue
					;;
			esac
			break
		done || true
		while [[ -n "$newuser" ]]; do
			if ! userpass=$(whiptail --title "$title" --passwordbox "Password for $newuser:" 8 40 3>&1 1>&2 2>&3); then
				newuser=""
				userpass=""
				break
			fi
			[[ -n "$userpass" ]] || { whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true; continue; }
			case "$userpass" in
				*:*|*$'\n'* )
					whiptail --msgbox --title "$title" "password can't contain : or newline, try again" 8 50 || true
					userpass=""
					continue
					;;
			esac
			break
		done || true
	fi

	zone=$(whiptail --title "$title - timezone" --menu "Select timezone" 22 60 15 \
		"UTC" "Coordinated Universal Time" \
		"Europe/Berlin" "Central European Time" \
		"Europe/London" "British Time" \
		"Europe/Paris" "Central European Time" \
		"Europe/Moscow" "Moscow Time" \
		"America/New_York" "US Eastern" \
		"America/Chicago" "US Central" \
		"America/Denver" "US Mountain" \
		"America/Los_Angeles" "US Pacific" \
		"America/Sao_Paulo" "Brasilia Time" \
		"Asia/Tokyo" "Japan" \
		"Asia/Shanghai" "China" \
		"Asia/Kolkata" "India" \
		"Asia/Dubai" "Gulf Time" \
		"Australia/Sydney" "Australian Eastern" \
		3>&1 1>&2 2>&3 || true)
	[[ -z "$zone" ]] && zone="UTC"

	keymap=$(whiptail --title "$title - keyboard layout" --menu "Select keyboard layout" 22 60 15 \
		"us" "US English" \
		"de" "German" \
		"gb" "British" \
		"fr" "French" \
		"es" "Spanish" \
		"it" "Italian" \
		"pt" "Portuguese" \
		"nl" "Dutch" \
		"se" "Swedish" \
		"no" "Norwegian" \
		"dk" "Danish" \
		"fi" "Finnish" \
		"pl" "Polish" \
		"ru" "Russian" \
		"tr" "Turkish" \
		3>&1 1>&2 2>&3 || true)
	[[ -z "$keymap" ]] && keymap="us"

	locale=$(whiptail --title "$title - locale" --menu "Select locale" 14 50 6 \
		"en_US.UTF-8" "US English" \
		"de_DE.UTF-8" "German" \
		"en_GB.UTF-8" "British" \
		"fr_FR.UTF-8" "French" \
		"es_ES.UTF-8" "Spanish" \
		3>&1 1>&2 2>&3 || true)
	[[ -z "$locale" ]] && locale="en_US.UTF-8"

	fstype=$(whiptail --title "$title - filesystem" --menu "Select filesystem for the system partition" 15 60 3 \
		"ext4" "Stable journaling filesystem (recommended)" \
		"btrfs" "Modern copy-on-write with snapshots" \
		"vfat" "FAT32 (no permissions, not recommended)" \
		3>&1 1>&2 2>&3 || true)
	[[ -z "$fstype" ]] && fstype="ext4"

	want_swap=$(whiptail --title "$title - swapfile" --menu "Select swapfile size" 15 50 5 \
		"none" "No swapfile" \
		"1G" "1 gigabyte" \
		"2G" "2 gigabytes" \
		"4G" "4 gigabytes" \
		"8G" "8 gigabytes" \
		3>&1 1>&2 2>&3 || true)
	[[ -z "$want_swap" ]] && want_swap="none"
	[[ "$want_swap" = "none" ]] && want_swap=""

	_swap="${want_swap:-none}"
	if whiptail --title "$title" --yesno "Install with these settings?\n\nhostname: $hostnm\nuser: ${newuser:-none}\ntimezone: $zone\nkeyboard: $keymap\nlocale: $locale\nfilesystem: $fstype\nswapfile: $_swap" 17 60; then
		return 0
	fi
	ask-install-settings || return 1
}
