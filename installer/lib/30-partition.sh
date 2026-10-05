partitioning() {
	disks=()
	for d in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]*n[0-9]* /dev/mmcblk[0-9]*; do
		if [[ -b "$d" ]]; then
			case "$d" in
				*p[0-9]*) continue ;;
			esac
			disks+=("$d" "Disk: $d")
		fi
	done
	if [[ ${#disks[@]} -eq 0 ]]; then
		whiptail --msgbox --title "$title" "no disks found" 8 40 || true
		main_screen
		return
	fi
	disk=$(whiptail --title "$title" --menu "Select the disk to install on" 14 50 6 "${disks[@]}" 3>&1 1>&2 2>&3 || true)
	if [[ -z "$disk" ]]; then
		main_screen
		return
	fi
	if ! whiptail --title "$title" --yesno "wipe $disk are you sure" 8 40; then
		partitioning
		return
	fi
	if ! medium_has_tarball; then
		rescan_medium || true
	fi
	if ! medium_has_tarball; then
		_dbg_mnt="$(mount 2>/dev/null | grep ' /mnt ' || echo 'nothing mounted at /mnt')"
		_dbg_blk="$(blkid 2>/dev/null | head -n 20 || echo 'blkid unavailable')"
		whiptail --msgbox --title "$title" "No Silen tarball found at /mnt, so installing would fail AFTER wiping $disk.\n\nThe installer already rescanned all disks (including Ventoy ISO files) and found nothing.\n\nPressed OK for details. Current state:\n$_dbg_mnt\n$_dbg_blk\n\nFixes: reboot (slow USB/NVMe may need a retry), write the ISO with dd instead of Ventoy, or open Shell and mount the install medium at /mnt yourself, then rerun Install." 22 70 || true
		main_screen
		return
	fi

	if medium_on_disk "$disk"; then
		whiptail --msgbox --title "$title" "$disk holds the install medium directly or as the Ventoy partition backing the ISO - installing onto it wipes the ISO/tarball Pick a different disk" 9 70 || true
		partitioning
		return
	fi
	for cmd in sfdisk mkfs.vfat mkfs.ext4 blkid; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			whiptail --msgbox --title "$title" "$cmd not found on the install medium" 8 40 || true
			return
		fi
	done
	if ! ask-install-settings; then
		main_screen
		return
	fi

	for part in $(mount 2>/dev/null | awk -v d="$disk" '($1==d || $1 ~ ("^" d "[0-9][0-9]*$") || $1 ~ ("^" d "p[0-9][0-9]*$")) {print $1}' || true); do
		[[ -n "$part" ]] || continue
		umount "$part" 2>/dev/null || true
	done

	if medium_on_disk "$disk"; then
		whiptail --msgbox --title "$title" "$disk holds the install medium refusing to wipe" 8 60 || true
		main_screen
		return
	fi
	whiptail --infobox "Partitioning $disk writing GPT" 8 40 2>/dev/null || true
	if command -v wipefs >/dev/null 2>&1; then
		wipefs -a "$disk" 2>/dev/null || true
	fi
	if ! sfdisk --no-reread "$disk" <<EOF
label: gpt
, 512M, U
, , L
EOF
	then
		if ! sfdisk "$disk" <<EOF
label: gpt
, 512M, U
, , L
EOF
		then
			if mount 2>/dev/null | awk -v d="$disk" '($1==d || $1 ~ ("^" d "[0-9][0-9]*$") || $1 ~ ("^" d "p[0-9][0-9]*$")) {f=1} END {exit !f}'; then
				whiptail --msgbox --title "$title" "couldn't write partition table to $disk: it is still in use (something is mounted on it). Open the shell and check 'mount'." 10 60 || true
			else
				whiptail --msgbox --title "$title" "couldn't write partition table to $disk" 8 40 || true
			fi
			return
		fi
	fi

	partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || true
	if [[ -b "${disk}p1" ]]; then
		bootp="${disk}p1"
		rootp="${disk}p2"
	else
		bootp="${disk}1"
		rootp="${disk}2"
	fi
	_wait=0
	while [[ ! -b "$bootp" ]] || [[ ! -b "$rootp" ]]; do
		[[ "$_wait" -ge 50 ]] && break
		sleep 0.1 2>/dev/null || sleep 1 2>/dev/null || true
		_wait=$((_wait + 1))
		if [[ "$_wait" = "20" ]]; then
			blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || true
		fi
	done
	if [[ ! -b "$bootp" ]] || [[ ! -b "$rootp" ]]; then
		whiptail --msgbox --title "$title" "partitioning failed, no partitions on $disk" 8 40 || true
		partitioning
		return
	fi
	fstype="${fstype:-ext4}"
	whiptail --infobox "Formatting $bootp FAT32 and $rootp $fstype" 8 60 2>/dev/null || true
	if ! mkfs.vfat -F 32 -n SILENBOOT "$bootp" 2>/dev/null; then
		whiptail --msgbox --title "$title" "couldn't format $bootp as FAT32" 8 40 || true
		return
	fi
	if [[ "$fstype" = "btrfs" ]]; then
		if ! command -v mkfs.btrfs >/dev/null 2>&1; then
			whiptail --msgbox --title "$title" "mkfs.btrfs not found on the install medium" 8 40 || true
			return
		fi
		if ! mkfs.btrfs -f -L silenroot "$rootp" 2>/dev/null; then
			whiptail --msgbox --title "$title" "couldn't format the partitions" 8 40 || true
			return
		fi
	elif [[ "$fstype" = "vfat" ]]; then
		if ! mkfs.vfat -F 32 -n silenroot "$rootp" 2>/dev/null; then
			whiptail --msgbox --title "$title" "couldn't format the partitions" 8 40 || true
			return
		fi
	else
		if ! mkfs.ext4 -F -q -L silenroot -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "$rootp" 2>/dev/null; then
			if ! mkfs.ext4 -F -L silenroot -E nodiscard "$rootp"; then
				whiptail --msgbox --title "$title" "couldn't format the partitions" 8 40 || true
				return
			fi
		fi
	fi
	install-base
}
