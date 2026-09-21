install-base() {
    mkdir -p "$root"
    if ! mount "$rootp" "$root"; then
        whiptail --msgbox --title "$title" "failed to mount $rootp" 8 40 || true
        return
    fi
    mkdir -p "$root"/boot
    if ! mount "$bootp" "$root"/boot; then
        cleanup
        whiptail --msgbox --title "$title" "failed to mount $bootp" 8 40 || true
        return
    fi

    stage3=""
    for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz /mnt/*.tar.zst; do
        [ -f "$s" ] || continue
        case "$(basename "$s")" in
            kernel-*.tar.*|network.tar.*|spk.tar.*) continue ;;
        esac
        stage3="$s" && break
    done || true
    if [ -z "$stage3" ]; then
        whiptail --msgbox --title "$title" "no Silen tarball found on the install medium" 8 40 || true
        cleanup
        return
    fi
    whiptail --infobox "Installing the system files, this might take a while...\n(extracting $(basename "$stage3"))" 8 60 2>/dev/null || true
    if [ "$(tar -tf "$stage3" 2>/dev/null | sed 's|^\./||' | awk -F/ 'NF>1 {print $1}' | sort -u | wc -l)" = "1" ]; then
        if ! tar -xpf "$stage3" -C "$root" --strip-components=1 --no-same-owner --numeric-owner --xattrs-include='*.*'; then
            whiptail --msgbox --title "$title" "failed to unpack the system tarball" 8 50 || true
            cleanup
            return
        fi
    else
        if ! tar -xpf "$stage3" -C "$root" --no-same-owner --numeric-owner --xattrs-include='*.*'; then
            whiptail --msgbox --title "$title" "failed to unpack the system tarball" 8 50 || true
            cleanup
            return
        fi
    fi
    whiptail --infobox "Installing this might take a while...\n" 8 60 2>/dev/null || true
    fix-permissions

    if ! mkdir -p "$root"/proc "$root"/sys "$root"/dev "$root"/run "$root"/etc "$root"/usr/share/zoneinfo; then
        whiptail --msgbox --title "$title" "failed to prepare $root (disk full?)" 8 40 || true
        cleanup
        return
    fi
    mount -t proc proc "$root"/proc 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount proc in target - install continues but GRUB may fail" 8 60 || true
    mount -t sysfs sysfs "$root"/sys 2>/dev/null || whiptail --msgbox --title "$title" "couldn't mount sys in target - install continues but GRUB may fail" 8 60 || true
    mount --rbind /dev "$root"/dev 2>/dev/null || whiptail --msgbox --title "$title" "couldn't bind /dev in target - install continues but GRUB may fail" 8 60 || true
    mount --rbind /run "$root"/run 2>/dev/null || true

    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$root"/etc/resolv.conf 2>/dev/null || echo "nameserver 1.1.1.1" > "$root"/etc/resolv.conf
    else
        echo "nameserver 1.1.1.1" > "$root"/etc/resolv.conf
    fi
    echo "$hostnm" > "$root"/etc/hostname || { whiptail --msgbox --title "$title" "failed to write hostname (disk full?)" 8 40 || true; cleanup; return; }
    if [ -f "$root"/etc/conf.d/hostname ]; then
        if grep -q '^hostname=' "$root"/etc/conf.d/hostname 2>/dev/null; then
            sed -i "s/^hostname=.*/hostname=\"$hostnm\"/" "$root"/etc/conf.d/hostname 2>/dev/null || true
        else
            printf 'hostname="%s"\n' "$hostnm" >> "$root"/etc/conf.d/hostname
        fi
    fi

    chpasswd_bin=""
    for c in /usr/bin/chpasswd /usr/sbin/chpasswd /bin/chpasswd /sbin/chpasswd; do
        [ -x "$root$c" ] && chpasswd_bin="$c" && break
    done
    [ -z "$chpasswd_bin" ] && chpasswd_bin="/usr/bin/chpasswd"
    if ! printf 'root:%s\n' "$rootpass" | chroot "$root" "$chpasswd_bin" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't set the root password - log in after reboot and run passwd" 8 60 || true
    fi
    rootpass=""

    bootuuid=$(blkid -s UUID -o value "$bootp" || true)
    rootuuid=$(blkid -s UUID -o value "$rootp" || true)
    if [ -z "$bootuuid" ] || [ -z "$rootuuid" ]; then
        whiptail --msgbox --title "$title" "couldn't read the partition UUIDs" 8 40 || true
        cleanup
        return
    fi
    cat > "$root"/etc/fstab <<EOF
UUID=$rootuuid / ext4 defaults 0 1
UUID=$bootuuid /boot vfat defaults 0 2
EOF

    apply-settings
    if [ -n "$made_swapfile" ]; then
        echo "/swapfile none swap sw 0 0" >> "$root"/etc/fstab
    fi
    if ! chroot "$root" /bin/bash -c "ldconfig" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't run ldconfig in the new system; shared libraries may not load until it is run" 8 60 || true
    fi

    whiptail --infobox "Installing the system this might take a while...\n(copying kernel and drivers)" 8 60 2>/dev/null || true
    install-modules
    whiptail --infobox "Installing the system this might take a while...\n(installing packages and network)" 8 60 2>/dev/null || true
    install-spk
    install-network
    whiptail --infobox "Installing the system this might take a while...\n(configuring Wi-Fi)" 8 60 2>/dev/null || true
    install-wifi
    whiptail --infobox "Installing the system this might take a while...\n(installing GPU drivers)" 8 60 2>/dev/null || true
    install-drivers
    whiptail --infobox "Installing the system this might take a while...\n(installing Desktop Environment)" 8 60 2>/dev/null || true
    install-desktop
    whiptail --infobox "Installing the system this might take a while...\n(creating users and finishing setup)" 8 60 2>/dev/null || true
    create-user
    install-branding
    fix-user-session
    if [ -n "${_elogind_hint:-}" ]; then
        whiptail --msgbox --title "$title" "Note: elogind is not in this image. If you later see 'user.<name> failed to start' or session errors, just run as root after reboot:\n\n  spk get elogind\n  rc-update add elogind boot\n  reboot\n\nLogin still works without it." 13 65 || true
    fi
    setup-quiet-boot
    if ! setup-grub; then
        sync 2>/dev/null || true
        cleanup
        whiptail --msgbox --title "$title" "Install finished but GRUB setup failed - system may not boot. See /tmp/grub-install.log" 8 60 || true
        main_screen
        return
    fi

    sync 2>/dev/null || true
    cleanup
    whiptail --msgbox --title "$title" "Silen is installed, reboot in main menu" 8 40 || true
    main_screen
}
