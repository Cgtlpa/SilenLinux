# writes grub.cfg and installs the efi bootloader
setup-grub() {
	if [[ -f /mnt/boot/vmlinuz ]]; then
		if ! cp /mnt/boot/vmlinuz "$ROOT_PATH"/boot/vmlinuz 2>/dev/null; then
			whiptail --msgbox --title "$title" "couldn't copy the kernel" 8 40 || true
			return 1
		fi
	else
		whiptail --msgbox --title "$title" "no kernel found on the install medium" 8 40 || true
		return 1
	fi
	initramfs_name=""
	_cp_err=""
	_need=0
	for i in /mnt/boot/initramfs.*; do
		[[ -f "$i" ]] || continue
		_need="$(stat -c%s "$i" 2>/dev/null || echo 0)"
		_try=0
		while [[ $_try -lt 3 ]]; do
			_try=$((_try + 1))
			if cp "$i" "$ROOT_PATH"/boot/ 2>/dev/null; then
				initramfs_name="$(basename "$i")"
				break
			fi
			sleep 1 2>/dev/null || true
		done || true
		if [[ -n "$initramfs_name" ]]; then
			break
		fi
		_cp_err="1"
	done || true
	if [[ -z "$initramfs_name" ]]; then
		for i in /mnt/initramfs.*; do
			[[ -f "$i" ]] || continue
			_need="$(stat -c%s "$i" 2>/dev/null || echo 0)"
			_try=0
			while [[ $_try -lt 3 ]]; do
				_try=$((_try + 1))
				if cp "$i" "$ROOT_PATH"/boot/ 2>/dev/null; then
					initramfs_name="$(basename "$i")"
					break
				fi
				sleep 1 2>/dev/null || true
			done || true
			if [[ -n "$initramfs_name" ]]; then
				break
			fi
			_cp_err="1"
		done || true
	fi
	if [[ -z "$initramfs_name" ]]; then
		_ls="$(ls /mnt/boot 2>/dev/null | head -n 8 | tr '\n' ' ' || echo "unlistable")"
		if [[ -n "$_cp_err" ]]; then
			if touch "$ROOT_PATH/boot/.writetest" 2>/dev/null; then
				rm -f "$ROOT_PATH/boot/.writetest" 2>/dev/null || true
				_need_mb=0
				_have_kb=0
				if [[ $_need =~ ^[0-9]+$ ]]; then
					_need_mb=$((_need / 1024 / 1024))
				fi
				_have_kb="$(df -k "$ROOT_PATH/boot" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
				[[ $_have_kb =~ ^[0-9]+$ ]] || _have_kb=0
				if [[ "$_need_mb" -gt 0 ]] && [[ $((_have_kb / 1024)) -lt "$_need_mb" ]]; then
					whiptail --msgbox --title "$title" "initramfs needs ${_need_mb}M but the new boot partition only has $((_have_kb / 1024))M free - repartition with a bigger ESP and retry. (/mnt/boot: $_ls)" 9 65 || true
				else
					whiptail --msgbox --title "$title" "found an initramfs on the medium but couldn't read it - bad USB write? Reflash and retry. (/mnt/boot: $_ls)" 9 65 || true
				fi
			else
				whiptail --msgbox --title "$title" "can't write to the new boot partition - repartition and retry. (/mnt/boot: $_ls)" 8 65 || true
			fi
		else
			whiptail --msgbox --title "$title" "no initramfs found in the install ISO. (/mnt/boot: $_ls)" 8 60 || true
		fi
		return 1
	fi

	# efi install, refuses to do legacy boot
	if [[ ! -d /sys/firmware/efi ]]; then
		whiptail --msgbox --title "$title" "this machine booted in legacy mode, but Silen can currently only install an EFI bootloader. Boot the iso in UEFI mode and try again." 10 60 || true
		return 1
	fi

	if [[ -d /mnt/grub/usr/local ]]; then
		mkdir -p "$ROOT_PATH"/usr/local
		cp -a /mnt/grub/usr/local/. "$ROOT_PATH"/usr/local/ 2>/dev/null || { whiptail --msgbox --title "$title" "couldn't copy bundled GRUB" 8 40 || true; }
	fi

	mkdir -p "$ROOT_PATH/tmp" 2>/dev/null || true
	mkdir -p "$ROOT_PATH"/sys/firmware/efi/efivars 2>/dev/null || true
	mount -t efivarfs efivarfs "$ROOT_PATH"/sys/firmware/efi/efivars 2>/dev/null || true
	if chroot "$ROOT_PATH" /bin/bash -c "PATH=/usr/local/sbin:/usr/local/bin:\$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" >"$ROOT_PATH/tmp/grub-install.log" 2>&1 || chroot "$ROOT_PATH" /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" >>"$ROOT_PATH/tmp/grub-install.log" 2>&1; then
		cp "$ROOT_PATH/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
		if [[ ! -f "$ROOT_PATH"/boot/grub/fonts/unicode.pf2 ]]; then
			for _pf2 in /mnt/grub/usr/local/share/grub/unicode.pf2 \
						/usr/local/share/grub/unicode.pf2 \
						/usr/share/grub/unicode.pf2; do
				if [[ -f "$_pf2" ]]; then
					mkdir -p "$ROOT_PATH"/boot/grub/fonts 2>/dev/null || true
					cp "$_pf2" "$ROOT_PATH"/boot/grub/fonts/unicode.pf2 2>/dev/null || true
					break
				fi
			done || true
		fi
		cat > "$ROOT_PATH"/boot/grub/grub.cfg <<EOF
set default=0
set timeout=10

insmod part_gpt
insmod part_msdos
insmod fat
insmod ext2
insmod search_fs_uuid
insmod all_video
insmod gfxterm
insmod efi_gop
insmod efi_uga
if loadfont \$prefix/fonts/unicode.pf2; then
    set gfxmode=auto
fi
# console fallback so the menu still works if gfxterm dies. no gfxpayload, uefi hates it.
terminal_output gfxterm console
search --no-floppy --fs-uuid --set=root $bootuuid

menuentry "Silen Linux" {
    linux /vmlinuz root=UUID=$rootuuid ro rootwait loglevel=4 console=ttyS0 console=tty0
    initrd /$initramfs_name
}
EOF
		_silen_disk=""
		_silen_part=""
		case "$bootp" in
			*p[0-9]*)
				_silen_disk="${bootp%p[0-9]*}"
				_silen_part="${bootp##*p}"
				;;
			*)
				_silen_disk="$(echo "$bootp" | sed 's/[0-9][0-9]*$//')"
				_silen_part="$(echo "$bootp" | grep -o '[0-9][0-9]*$' || true)"
				;;
		esac
		chroot "$ROOT_PATH" /bin/bash -c "PATH=/usr/local/sbin:/usr/local/bin:\$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --bootloader-id=Silen" >>"$ROOT_PATH/tmp/grub-install.log" 2>&1 || chroot "$ROOT_PATH" /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --bootloader-id=Silen" >>"$ROOT_PATH/tmp/grub-install.log" 2>&1 || true
		cp "$ROOT_PATH/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
		if command -v efibootmgr >/dev/null 2>&1 && [[ -n "$_silen_disk" ]] && [[ -n "$_silen_part" ]] && [[ -b "$_silen_disk" ]]; then
			_silen_bootnum="$(efibootmgr 2>/dev/null | grep -i 'silen' | head -n1 | sed 's/^Boot\([0-9A-Fa-f]*\).*/\1/' || true)"
			if [[ -z "$_silen_bootnum" ]]; then
				if [[ -f "$ROOT_PATH/boot/EFI/Silen/grubx64.efi" ]]; then
					efibootmgr --create --disk "$_silen_disk" --part "$_silen_part" --label "Silen Linux" --loader '\EFI\Silen\grubx64.efi' >/dev/null 2>&1 || true
				elif [[ -f "$ROOT_PATH/boot/EFI/BOOT/BOOTX64.EFI" ]]; then
					efibootmgr --create --disk "$_silen_disk" --part "$_silen_part" --label "Silen Linux" --loader '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1 || true
				fi
				_silen_bootnum="$(efibootmgr 2>/dev/null | grep -i 'silen' | head -n1 | sed 's/^Boot\([0-9A-Fa-f]*\).*/\1/' || true)"
			fi
			if [[ -n "$_silen_bootnum" ]]; then
				_silen_order="$(efibootmgr 2>/dev/null | grep '^BootOrder:' | head -n1 | sed 's/^BootOrder: *//' || true)"
				_silen_rest="$(echo "$_silen_order" | tr ',' '\n' | grep -v -i "^$_silen_bootnum$" | tr '\n' ',' | sed 's/,$//' | sed 's/^,//' || true)"
				if [[ -n "$_silen_rest" ]]; then
					efibootmgr -o "$_silen_bootnum,$_silen_rest" >/dev/null 2>&1 || true
				else
					efibootmgr -o "$_silen_bootnum" >/dev/null 2>&1 || true
				fi
			fi
		else
			echo "efibootmgr missing in live env, boot order left unchanged" >>"$ROOT_PATH/tmp/grub-install.log" 2>&1 || true
			cp "$ROOT_PATH/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
		fi
		if [[ -f /mnt/nvidia-auto ]] && [[ -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf ]]; then
			if ! grep -q 'nvidia-drm.modeset=1' "$ROOT_PATH"/boot/grub/grub.cfg 2>/dev/null; then
				sed -i '/nomodeset/b; s|^\([[:space:]]*linux .*\)|\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1|' "$ROOT_PATH"/boot/grub/grub.cfg 2>/dev/null || true
			fi
		fi
		whiptail --msgbox --title "$title" "GRUB is installed" 8 40 || true
	else
		cp "$ROOT_PATH/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
		whiptail --msgbox --title "$title" "grub-install failed, see /tmp/grub-install.log for errors" 8 40 || true
		return 1
	fi
}
