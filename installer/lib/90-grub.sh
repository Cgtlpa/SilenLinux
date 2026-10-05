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
	for i in /mnt/boot/initramfs.*; do
		[[ -f "$i" ]] || continue
		if cp "$i" "$ROOT_PATH"/boot/ 2>/dev/null; then
			initramfs_name="$(basename "$i")"
			break
		fi
	done || true
	if [[ -z "$initramfs_name" ]]; then
		whiptail --msgbox --title "$title" "no initramfs found in the install ISO" 8 40 || true
		return 1
	fi

	if [[ ! -d /sys/firmware/efi ]]; then
		whiptail --msgbox --title "$title" "this machine booted in legacy mode, but Silen can currently only install an EFI bootloader. Boot the iso in UEFI mode and try again." 10 60 || true
		return 1
	fi

	if [[ -d /mnt/grub/usr/local ]]; then
		mkdir -p "$ROOT_PATH"/usr/local
		cp -a /mnt/grub/usr/local/. "$ROOT_PATH"/usr/local/ 2>/dev/null || { whiptail --msgbox --title "$title" "couldn't copy bundled GRUB" 8 40 || true; }
	fi

	mkdir -p "$ROOT_PATH/tmp" 2>/dev/null || true
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
# console fallback: if gfxterm dies the menu is still usable (never black).
terminal_output gfxterm console
# No 'set gfxpayload' here on purpose: 'text' is rejected on UEFI
# ('invalid video mode specification', blind mode) and the GRUB
# default (keep GOP for the kernel) is correct — see comment in setup-grub.
search --no-floppy --fs-uuid --set=root $bootuuid

menuentry "Silen Linux" {
    linux /vmlinuz root=UUID=$rootuuid ro rootwait loglevel=4 console=ttyS0 console=tty0
    initrd /$initramfs_name
}

menuentry "Silen Linux (quiet)" {
    linux /vmlinuz root=UUID=$rootuuid ro quiet loglevel=3
    initrd /$initramfs_name
}

menuentry "Silen Linux (fallback, nomodeset)" {
    linux /vmlinuz root=UUID=$rootuuid ro rootwait nomodeset loglevel=4 console=ttyS0 console=tty0
    initrd /$initramfs_name
}
EOF
		whiptail --msgbox --title "$title" "GRUB is installed" 8 40 || true
	else
		cp "$ROOT_PATH/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
		whiptail --msgbox --title "$title" "grub-install failed, see /tmp/grub-install.log for errors" 8 40 || true
		return 1
	fi
}
