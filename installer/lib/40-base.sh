install-base() {
	mkdir -p "$ROOT_PATH"
	if ! mount "$rootp" "$ROOT_PATH"; then
		whiptail --msgbox --title "$title" "failed to mount $rootp" 8 40 || true
		return
	fi
	mkdir -p "$ROOT_PATH"/boot
	if ! mount "$bootp" "$ROOT_PATH"/boot; then
		cleanup
		whiptail --msgbox --title "$title" "failed to mount $bootp" 8 40 || true
		return
	fi

	stage3=""
	for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz /mnt/*.tar.zst; do
		[[ -f "$s" ]] || continue
		case "$(basename "$s")" in
			kernel-*.tar.*|network.tar.*|spk.tar.*) continue ;;
		esac
		stage3="$s" && break
	done || true
	if [[ -z "$stage3" ]]; then
		whiptail --msgbox --title "$title" "no Silen tarball found on the install medium" 8 40 || true
		cleanup
		return
	fi
	whiptail --infobox "Installing the system files, this might take a while...\n(extracting $(basename "$stage3"))" 8 60 2>/dev/null || true
	if [[ "$(tar -tf "$stage3" 2>/dev/null | sed 's|^\./||' | awk -F/ 'NF>1 {print $1}' | sort -u | wc -l)" = "1" ]]; then
		if ! tar -xpf "$stage3" -C "$ROOT_PATH" --strip-components=1 --no-same-owner --numeric-owner --xattrs-include='*.*'; then
			whiptail --msgbox --title "$title" "failed to unpack the system tarball" 8 50 || true
			cleanup
			return
		fi
	else
		if ! tar -xpf "$stage3" -C "$ROOT_PATH" --no-same-owner --numeric-owner --xattrs-include='*.*'; then
			whiptail --msgbox --title "$title" "failed to unpack the system tarball" 8 50 || true
			cleanup
			return
		fi
	fi
	whiptail --infobox "Installing this might take a while...\n" 8 60 2>/dev/null || true
	fix-permissions
	fix-sudo-emerge

	if ! mkdir -p "$ROOT_PATH"/proc "$ROOT_PATH"/sys "$ROOT_PATH"/dev "$ROOT_PATH"/run "$ROOT_PATH"/etc "$ROOT_PATH"/usr/share/zoneinfo; then
		whiptail --msgbox --title "$title" "failed to prepare $ROOT_PATH (disk full?)" 8 40 || true
		cleanup
		return
	fi
	mount -t proc proc "$ROOT_PATH"/proc 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount proc in target - install continues but GRUB may fail" 8 60 || true
	mount -t sysfs sysfs "$ROOT_PATH"/sys 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount sys in target - install continues but GRUB may fail" 8 60 || true
	mount --rbind /dev "$ROOT_PATH"/dev 2>/dev/null || whiptail --msgbox --title "$title" "couldn't bind /dev in target - install continues but GRUB may fail" 8 60 || true
	mount --rbind /run "$ROOT_PATH"/run 2>/dev/null || true

	if [[ -L "$ROOT_PATH"/etc/resolv.conf ]]; then
		rm -f "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	if [[ -s /etc/resolv.conf ]]; then
		cp /etc/resolv.conf "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	if [[ ! -s "$ROOT_PATH"/etc/resolv.conf ]]; then
		printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	echo "$hostnm" > "$ROOT_PATH"/etc/hostname || { whiptail --msgbox --title "$title" "failed to write hostname (disk full?)" 8 40 || true; cleanup; return; }
	if [[ -f "$ROOT_PATH"/etc/conf.d/hostname ]]; then
		if grep -q '^hostname=' "$ROOT_PATH"/etc/conf.d/hostname 2>/dev/null; then
			sed -i "s/^hostname=.*/hostname=\"$hostnm\"/" "$ROOT_PATH"/etc/conf.d/hostname 2>/dev/null || true
		else
			printf 'hostname="%s"\n' "$hostnm" >> "$ROOT_PATH"/etc/conf.d/hostname
		fi
	fi

	chpasswd_bin=""
	for c in /usr/bin/chpasswd /usr/sbin/chpasswd /bin/chpasswd /sbin/chpasswd; do
		[[ -x "$ROOT_PATH$c" ]] && chpasswd_bin="$c" && break
	done
	[[ -z "$chpasswd_bin" ]] && chpasswd_bin="/usr/bin/chpasswd"
	if ! printf 'root:%s\n' "$rootpass" | chroot "$ROOT_PATH" "$chpasswd_bin" 2>/dev/null; then
		whiptail --msgbox --title "$title" "couldn't set the root password - log in after reboot and run passwd" 8 60 || true
	fi
	rootpass=""

	bootuuid=$(blkid -s UUID -o value "$bootp" || true)
	rootuuid=$(blkid -s UUID -o value "$rootp" || true)
	if [[ -z "$bootuuid" ]] || [[ -z "$rootuuid" ]]; then
		whiptail --msgbox --title "$title" "couldn't read the partition UUIDs" 8 40 || true
		cleanup
		return
	fi
	fstype="${fstype:-ext4}"
	fspass="0 1"
	[[ "$fstype" = "ext4" ]] || fspass="0 0"
	cat > "$ROOT_PATH"/etc/fstab <<EOF
UUID=$rootuuid / $fstype defaults $fspass
UUID=$bootuuid /boot vfat defaults 0 2
EOF

	apply-settings
	if [[ -n "$made_swapfile" ]]; then
		echo "/swapfile none swap sw 0 0" >> "$ROOT_PATH"/etc/fstab
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "ldconfig" 2>/dev/null; then
		whiptail --msgbox --title "$title" "couldn't run ldconfig in the new system; shared libraries may not load until it is run" 8 60 || true
	fi

	whiptail --infobox "Installing the system this might take a while...\n(copying kernel and drivers)" 8 60 2>/dev/null || true
	install-modules
	whiptail --infobox "Installing the system this might take a while...\n(installing packages and network)" 8 60 2>/dev/null || true
	install-spk
	install-network
	whiptail --infobox "Installing the system this might take a while...\n(creating users and finishing setup)" 8 60 2>/dev/null || true
	create-user
	install-branding
	setup-root-shell
	fix-user-session
	if [[ -n "${_elogind_hint:-}" ]]; then
		whiptail --msgbox --title "$title" "Note: elogind is not in this image. If you later see 'user.<name> failed to start' or session errors, just run as root after reboot:\n\n  spk get elogind\n  rc-update add elogind boot\n  reboot\n\nLogin still works without it." 13 65 || true
	fi
	setup-quiet-boot
	cleanup-rootfs
	if ! setup-grub; then
		sync 2>/dev/null || true
		cleanup
		whiptail --msgbox --title "$title" "Install finished but GRUB setup failed - system may not boot. See /tmp/grub-install.log" 8 60 || true
		main_screen
		return
	fi

	whiptail --msgbox --title "$title" "To get Wi-Fi working, use iwctl in the installed Silen Linux.\n\nTo refresh the package database and pull missing dependencies, run: sudo emerge --oneshot sec-keys/openpgp-keys-gentoo-release && sudo emerge --sync" 10 65 || true
	sync 2>/dev/null || true
	cleanup
	whiptail --msgbox --title "$title" "Silen is installed, reboot in main menu" 8 40 || true
	main_screen
}
