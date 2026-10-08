# unpacks the base tarball onto the new root
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
			kernel-*.tar.*|headers-*.tar.*|network.tar.*|spk.tar.*|nvidia-kmods-*.tar.*) continue ;;
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
	chattr -i "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	grep -q '127\.0\.0\.53' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null && rm -f "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	if [[ -s /etc/resolv.conf ]] && grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
		cp -L /etc/resolv.conf "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
		sed -i '/127\.0\.0\.53/d' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	if ! grep -q '^nameserver' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null; then
		printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	chmod 644 "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
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
	install-nvidia-auto
	whiptail --infobox "Installing the system this might take a while...\n(creating users and finishing setup)" 8 60 2>/dev/null || true
	create-user
	install-branding
	mkdir -p "$ROOT_PATH"/usr/share/silen 2>/dev/null || true
	cat > "$ROOT_PATH"/usr/share/silen/spk-help.txt <<'EOF'
spk - Silen package manager (spark)

  sudo spk get <package> [package...]   install one or more packages
  sudo spk rm <package> [package...]    remove packages and their files
  sudo spk update                       update every installed package
  sudo spk update <package> [...]       update (or install) specific packages
  spk find <pattern>                   search installed packages
  spk list                              list installed packages with versions

System packages (desktops, drivers, firmware, dbus, iwd) install into /.
Leaf apps install isolated with shims in /usr/local/bin.
Per-user installs: spk get <package> --user (shims in ~/.local/bin).
Custom repo: SPK_BASE_URL=https://... spk get <package>
Full docs: spk --help
Wi-Fi: iwctl, diagnostics: silen-wifi-check
DNS: /etc/resolv.conf (nameserver 1.1.1.1 fallback, iwd updates it)
Wi-Fi diagnostics: silen-wifi-check | GPU/NVIDIA diagnostics: silen-nvidia-check
Network out of the box: wired uses dhcpcd, Wi-Fi uses iwd (iwctl). No network
at all until you plug in or connect, then DNS just works.
NVIDIA: display works out of the box via nouveau (in-tree + firmware).
For proprietary (nvidia-smi, CUDA): sudo spk get nvidia-drivers, then reboot.
That needs kernel headers at /lib/modules/$(uname -r)/build - this ISO ships
them when headers-<kver>.tar.zst was built (scripts/make-headers-bundle.sh).
Without headers the postinstall stops with a rerun hint and nothing breaks.
Diagnose any time with: silen-nvidia-check
EOF
	chmod 644 "$ROOT_PATH"/usr/share/silen/spk-help.txt 2>/dev/null || true
	setup-root-shell
	fix-user-session
	if [[ -n "${_elogind_hint:-}" ]]; then
		whiptail --msgbox --title "$title" "Note: elogind is not in this image. If you later see 'user.<name> failed to start' or session errors, just run as root after reboot:\n\n  spk get elogind\n  rc-update add elogind boot\n  reboot\n\nLogin still works without it." 13 65 || true
	fi
	setup-quiet-boot
	cleanup-rootfs
	if [[ -L "$ROOT_PATH"/etc/resolv.conf ]]; then
		rm -f "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	chattr -i "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	grep -q '127\.0\.0\.53' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null && rm -f "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	# second dns pass in case the first one didnt stick
	if [[ -s /etc/resolv.conf ]] && grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
		cp -L /etc/resolv.conf "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
		sed -i '/127\.0\.0\.53/d' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	if ! grep -q '^nameserver' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null; then
		printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	fi
	chmod 644 "$ROOT_PATH"/etc/resolv.conf 2>/dev/null || true
	if ! grep -q '^nameserver' "$ROOT_PATH"/etc/resolv.conf 2>/dev/null; then
		whiptail --msgbox --title "$title" "warning: no nameserver in the new system (live DNS was empty). After reboot, connect with iwctl, then check /etc/resolv.conf - the boot hook restores 1.1.1.1/9.9.9.9 when it is missing." 10 65 || true
	fi
	if ! setup-grub; then
		sync 2>/dev/null || true
		cleanup
		whiptail --msgbox --title "$title" "Install finished but GRUB setup failed - system may not boot. See /tmp/grub-install.log" 8 60 || true
		main_screen
		return
	fi

	whiptail --msgbox --title "$title" "Wi-Fi: use iwctl in the installed Silen Linux (help: silen-wifi-check).\n\nspk usage (as root, use sudo):\n  sudo spk update              update all packages\n  sudo spk update <package>    update one package\n  sudo spk get <package>       install\n  sudo spk rm <package>        remove\n  spk find <name> / spk list   search / list\n\nGuide saved to /usr/share/silen/spk-help.txt" 14 70 || true
	_nv_note=""
	if find "$ROOT_PATH"/lib/modules -iname 'nvidia.ko*' 2>/dev/null | grep -q .; then
		_nv_note="\nNVIDIA driver installed - verify after reboot with nvidia-smi.\n"
	fi
	sync 2>/dev/null || true
	cleanup
	whiptail --msgbox --title "$title" "Silen is installed. Reboot to use it.\n\nAfter reboot (as root):\n  sudo spk update               update all\n  sudo spk update <package>    update one\n  sudo spk get <package>       install (try: sudo spk get fastfetch)\n  sudo spk rm <package>        remove\n  spk find <name> / spk list   search / list\n\nFull guide: /usr/share/silen/spk-help.txt\nWi-Fi: iwctl, DNS: /etc/resolv.conf$_nv_note" 16 70 || true
	main_screen
}
