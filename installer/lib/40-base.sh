#!/bin/bash

# install-base: bootstrap minimal system and install packages via Cres

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

	# Extract minimal base tarball (contains core system, Cres, and essential tools)
	local base_tarball=""
	for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz /mnt/*.tar.zst; do
		[[ -f "$s" ]] || continue
		case "$(basename "$s")" in
			kernel-*.tar.*|headers-*.tar.*|network.tar.*|spk.tar.*|nvidia-kmods-*.tar.*) continue ;;
		esac
		base_tarball="$s" && break
	done || true
	
	if [[ -z "$base_tarball" ]]; then
		whiptail --msgbox --title "$title" "no base tarball found on the install medium" 8 40 || true
		cleanup
		return
	fi
	
	whiptail --infobox "Installing base system...\n(extracting $(basename "$base_tarball"))" 8 60 2>/dev/null || true
	if [[ "$(tar -tf "$base_tarball" 2>/dev/null | sed 's|^\./||' | awk -F/ 'NF>1 {print $1}' | sort -u | wc -l)" = "1" ]]; then
		if ! tar -xpf "$base_tarball" -C "$ROOT_PATH" --strip-components=1 --no-same-owner --numeric-owner --xattrs-include='*.*'; then
			whiptail --msgbox --title "$title" "failed to unpack the base system" 8 50 || true
			cleanup
			return
		fi
	else
		if ! tar -xpf "$base_tarball" -C "$ROOT_PATH" --no-same-owner --numeric-owner --xattrs-include='*.*'; then
			whiptail --msgbox --title "$title" "failed to unpack the base system" 8 50 || true
			cleanup
			return
		fi
	fi
	rm -rf "$ROOT_PATH"/etc/portage/gnupg 2>/dev/null || true

	if ! mkdir -p "$ROOT_PATH"/proc "$ROOT_PATH"/sys "$ROOT_PATH"/dev "$ROOT_PATH"/run "$ROOT_PATH"/etc "$ROOT_PATH"/usr/share/zoneinfo; then
		whiptail --msgbox --title "$title" "failed to prepare $ROOT_PATH (disk full?)" 8 40 || true
		cleanup
		return
	fi
	mount -t proc proc "$ROOT_PATH"/proc 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount proc in target" 8 60 || true
	mount -t sysfs sysfs "$ROOT_PATH"/sys 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount sys in target" 8 60 || true
	mount --rbind /dev "$ROOT_PATH"/dev 2>/dev/null || whiptail --msgbox --title "$title" "couldn't bind /dev in target" 8 60 || true
	mount --rbind /run "$ROOT_PATH"/run 2>/dev/null || true

	# Copy DNS config
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

	echo "$hostnm" > "$ROOT_PATH"/etc/hostname || { whiptail --msgbox --title "$title" "failed to write hostname" 8 40 || true; cleanup; return; }
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
		whiptail --msgbox --title "$title" "couldn't set the root password" 8 60 || true
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
		whiptail --msgbox --title "$title" "couldn't run ldconfig in the new system" 8 60 || true
	fi

	# Install kernel and modules
	whiptail --infobox "Installing kernel and drivers..." 8 60 2>/dev/null || true
	install-modules
	
	# Install network stack
	whiptail --infobox "Installing network stack..." 8 60 2>/dev/null || true
	install-network
	install-nvidia-auto
	
	# Create user
	whiptail --infobox "Creating user and finishing setup..." 8 60 2>/dev/null || true
	create-user
	install-branding
	install-target-scripts
	install-extras

	# Install packages via Cres (online)
	whiptail --infobox "Downloading and installing packages via Cres...\nThis may take several minutes." 8 60 2>/dev/null || true
	install-packages-via-cres

	# Final setup
	mkdir -p "$ROOT_PATH"/usr/share/silen 2>/dev/null || true
	cat > "$ROOT_PATH"/usr/share/silen/cres-help.txt <<'EOF'
cres - Silen package manager

  sudo cres get <package> [package...]   install one or more packages
  sudo cres rm <package> [package...]    remove packages and their files
  sudo cres update                       update every installed package
  cres search <pattern>                  search the remote package index
  cres list                              list installed packages with versions
  cres info <package>                    show package details

System packages (desktops, drivers, firmware, dbus, iwd) install into /.
Leaf apps install isolated with shims in /usr/local/bin.

Wi-Fi: iwctl, diagnostics: silen-wifi-check
DNS: /etc/resolv.conf (nameserver 1.1.1.1 fallback, iwd updates it)
Wi-Fi diagnostics: silen-wifi-check | GPU/NVIDIA diagnostics: silen-nvidia-check
Network out of the box: wired uses dhcpcd, Wi-Fi uses iwd (iwctl). No network
at all until you plug in or connect, then DNS just works.
NVIDIA: display works out of the box via nouveau (in-tree + firmware).
For proprietary (nvidia-smi, CUDA) use the NVIDIA ISO variant.
EOF
	chmod 644 "$ROOT_PATH"/usr/share/silen/cres-help.txt 2>/dev/null || true
	setup-root-shell
	fix-user-session
	if [[ -n "${_elogind_hint:-}" ]]; then
		whiptail --msgbox --title "$title" "Note: elogind is not in this image. If you later see 'user.<name> failed to start' or session errors, just run as root after reboot:\n\n  cres get elogind\n  rc-update add elogind boot\n  reboot\n\nLogin still works without it." 13 65 || true
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

	# Show post-installation tutorial
	if [[ "${SILEN_AUTO:-}" != "1" ]]; then
		show_tutorial
	fi
	
	if [[ "${SILEN_AUTO:-}" = "1" ]]; then
		poweroff -f 2>/dev/null || true
		exit 0
	fi
	main_screen
}

# install-packages-via-cres: use Cres to install the Silen desktop environment
install-packages-via-cres() {
	# Ensure Cres is available in the target
	if [[ ! -x "$ROOT_PATH/usr/bin/cres" ]]; then
		whiptail --msgbox --title "$title" "Cres not found in target system. Cannot install packages online." 8 60 || true
		return 1
	fi

	# Copy Cres config and repository index
	mkdir -p "$ROOT_PATH/etc/cres" 2>/dev/null || true
	if [[ -f /etc/cres/config.lua ]]; then
		cp /etc/cres/config.lua "$ROOT_PATH/etc/cres/config.lua" 2>/dev/null || true
	fi
	if [[ -f /usr/share/cres/index.json ]]; then
		mkdir -p "$ROOT_PATH/usr/share/cres" 2>/dev/null || true
		cp /usr/share/cres/index.json "$ROOT_PATH/usr/share/cres/index.json" 2>/dev/null || true
	fi

	# Sync package index
	whiptail --infobox "Syncing package index..." 8 60 2>/dev/null || true
	if ! chroot "$ROOT_PATH" /usr/bin/cres sync --system 2>/dev/null; then
		whiptail --msgbox --title "$title" "Failed to sync package index. Check network connection." 8 60 || true
		return 1
	fi

	# Core system packages to install
	local packages=(
		"linux-6.18"
		"linux-firmware"
		"instantwm"
		"kitty"
		"rofi"
		"foot"
		"seatd"
		"dbus"
		"iwd"
		"elogind"
		"sddm"
		"dm-openrc"
		"gtk-libs"
		"wl-libs"
		"mesa"
		"xorg-libs"
		"xorg-server"
		"xwayland"
		"dejavu"
		"noto-fonts"
		"nerd-symbols"
		"cursor-theme"
		"libinput"
		"swaylock"
		"yazi"
		"bottom"
		"nano"
		"fastfetch"
		"silen-audio"
		"pipewire"
		"wireplumber"
		"lua-libs"
		"libpulse"
		"libasyncns"
		"alsa-lib"
		"vulkan-loader"
		"instantmenu"
		"instantmenu-extras"
		"instantcli"
		"cxx-libs"
		"xkb-data"
		"xinit"
		"xorg-drivers"
		"firefox"
	)

	# Install packages one by one with progress
	local total=${#packages[@]}
	local current=0
	local failed=()
	
	for pkg in "${packages[@]}"; do
		current=$((current + 1))
		whiptail --infobox "Installing packages via Cres ($current/$total)\n\n$pkg" 8 60 2>/dev/null || true
		if ! chroot "$ROOT_PATH" /usr/bin/cres get "$pkg" --yes 2>&1 | tail -20 > /tmp/cres-install.log; then
			failed+=("$pkg")
		fi
	done

	if [[ ${#failed[@]} -gt 0 ]]; then
		local fail_list=$(printf '  %s\n' "${failed[@]}")
		whiptail --msgbox --title "$title" "Some packages failed to install:\n$fail_list\n\nYou can install them manually after reboot with:\n  sudo cres get <package>" 15 70 || true
	fi

	# Update all packages
	whiptail --infobox "Updating all packages..." 8 60 2>/dev/null || true
	chroot "$ROOT_PATH" /usr/bin/cres update --yes 2>&1 | tail -20 > /tmp/cres-update.log || true
}

# Source the tutorial
. "$(dirname "$0")/tutorial.sh"