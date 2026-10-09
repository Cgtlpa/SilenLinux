silen_disk_size() {
	local _d="$1"
	local _b="${_d##*/}"
	local _s=""
	if command -v lsblk >/dev/null 2>&1; then
		_s="$(lsblk -dn -o SIZE "$_d" 2>/dev/null | tr -d ' ' || true)"
	fi
	if [[ -z "$_s" && -f "/sys/block/$_b/size" ]]; then
		local _sec="$(cat "/sys/block/$_b/size" 2>/dev/null || true)"
		if [[ -n "$_sec" ]]; then
			_s="$(awk -v s="$_sec" 'BEGIN { b=s*512; if (b>=1073741824) printf "%.0fG", b/1073741824; else if (b>=1048576) printf "%.0fM", b/1048576; else printf "%dK", b/1024 }' 2>/dev/null || true)"
		fi
	fi
	if [[ -z "$_s" ]]; then
		_s="unknown-size"
	fi
	printf '%s' "$_s"
}
silen_disk_model() {
	local _d="$1"
	local _b="${_d##*/}"
	local _m=""
	if [[ -f "/sys/block/$_b/device/model" ]]; then
		_m="$(cat "/sys/block/$_b/device/model" 2>/dev/null | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' || true)"
	fi
	if [[ -z "$_m" ]] && command -v lsblk >/dev/null 2>&1; then
		_m="$(lsblk -dn -o MODEL "$_d" 2>/dev/null | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' || true)"
	fi
	if [[ -z "$_m" ]]; then
		_m="unknown-model"
	fi
	printf '%s' "$_m"
}
silen_disk_serial() {
	local _d="$1"
	local _b="${_d##*/}"
	local _n=""
	if [[ -f "/sys/block/$_b/device/serial" ]]; then
		_n="$(cat "/sys/block/$_b/device/serial" 2>/dev/null | tr -d ' ' || true)"
	fi
	if [[ -z "$_n" ]] && command -v lsblk >/dev/null 2>&1; then
		_n="$(lsblk -dn -o SERIAL "$_d" 2>/dev/null | tr -d ' ' || true)"
	fi
	if [[ -z "$_n" ]]; then
		_n="no-serial"
	fi
	printf '%s' "$_n"
}
silen_disk_label() {
	local _d="$1"
	printf '%s %s %s %s' "$_d" "$(silen_disk_size "$_d")" "$(silen_disk_model "$_d")" "$(silen_disk_serial "$_d")"
}
silen_disk_unlocked() {
	local _d="$1"
	local _b="${_d##*/}"
	if [[ "${SILEN_ALLOW_LOCKED:-0}" = "1" ]]; then
		return 0
	fi
	if [[ -f "/tmp/.silen-unlock-$_b" ]]; then
		return 0
	fi
	if [[ -f "/run/silen-unlock-$_b" ]]; then
		return 0
	fi
	if [[ -f "/tmp/.silen-unlock-all" ]]; then
		return 0
	fi
	if [[ -f "/run/silen-unlock-all" ]]; then
		return 0
	fi
	return 1
}
silen_disk_locked() {
	local _d="$1"
	if silen_disk_unlocked "$_d"; then
		return 1
	fi
	local _t=""
	_t="$(mktemp -d /tmp/.silen-probe.XXXXXX 2>/dev/null || echo /tmp/.silen-probe.$$)"
	mkdir -p "$_t" 2>/dev/null || true
	local _p=""
	for _p in "${_d}"[0-9]* "${_d}"p[0-9]*; do
		[[ -b "$_p" ]] || continue
		if mount -o ro "$_p" "$_t" 2>/dev/null; then
			if [[ -f "$_t/.silen-lock" ]]; then
				umount "$_t" 2>/dev/null || true
				rmdir "$_t" 2>/dev/null || true
				return 0
			fi
			umount "$_t" 2>/dev/null || true
		fi
	done || true
	rmdir "$_t" 2>/dev/null || true
	return 1
}
# disk list and safety checks live here
partitioning() {
	disks=()
	for d in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]*n[0-9]* /dev/mmcblk[0-9]*; do
		if [[ -b "$d" ]]; then
			case "$d" in
				*p[0-9]*) continue ;;
			esac
			disks+=("$d" "$(silen_disk_label "$d")")
		fi
	done
	if [[ ${#disks[@]} -eq 0 ]]; then
		whiptail --msgbox --title "$title" "no disks found" 8 40 || true
		main_screen
		return
	fi
	disk=$(whiptail --title "$title" --menu "Select the disk to install on" 20 70 6 "${disks[@]}" 3>&1 1>&2 2>&3 || true)
	if [[ -z "$disk" ]]; then
		main_screen
		return
	fi
	_lbl="$(silen_disk_label "$disk")"
	if silen_disk_locked "$disk"; then
		whiptail --msgbox --title "$title" "$_lbl is locked by .silen-lock. Refusing to wipe. Pick a different disk, or run unlock-ssd $disk in Shell to allow it." 10 70 || true
		partitioning
		return
	fi
	if ! whiptail --title "$title" --yesno "wipe $_lbl are you sure" 8 70; then
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
	setup-live-wifi

	for part in $(mount 2>/dev/null | awk -v d="$disk" '($1==d || $1 ~ ("^" d "[0-9][0-9]*$") || $1 ~ ("^" d "p[0-9][0-9]*$")) {print $1}' || true); do
		[[ -n "$part" ]] || continue
		umount "$part" 2>/dev/null || true
	done

	if medium_on_disk "$disk"; then
		whiptail --msgbox --title "$title" "$disk holds the install medium refusing to wipe" 8 60 || true
		main_screen
		return
	fi
	if silen_disk_locked "$disk"; then
		whiptail --msgbox --title "$title" "$_lbl is locked by .silen-lock. Refusing to wipe. Run unlock-ssd $disk in Shell to allow it." 9 70 || true
		main_screen
		return
	fi
	whiptail --infobox "Partitioning $_lbl writing GPT" 8 70 2>/dev/null || true
	if command -v wipefs >/dev/null 2>&1; then
		wipefs -a "$disk" 2>/dev/null || true
	fi
	# writes the gpt table, esp first then root
	if ! sfdisk --no-reread "$disk" <<EOF
label: gpt
, 1G, U
, , L
EOF
	then
		if ! sfdisk "$disk" <<EOF
label: gpt
, 1G, U
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
