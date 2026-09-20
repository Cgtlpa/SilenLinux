#!/bin/bash
set -e

title="Silen installer"
root="/silen"

cleanup() {
    for m in "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/boot" "$root"; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
        fi
    done
}

medium_has_tarball_at() {
    _d="$1"
    for f in "$_d"/stage3-*.tar.* "$_d"/tarball-*.tar.* "$_d"/tarball-*.xz "$_d"/*.tar.xz; do
        [ -f "$f" ] && return 0
    done
    return 1
}
medium_has_tarball() {
    medium_has_tarball_at /mnt
}

ensure_loop_support() {
    modprobe -q loop 2>/dev/null || true
    for _i in 0 1 2 3 4 5 6 7; do
        [ -b "/dev/loop$_i" ] || mknod "/dev/loop$_i" b 7 "$_i" 2>/dev/null || true
    done
}

_install_mount_candidate() {
    _dev="$1"
    _mp="$2"
    mount "$_dev" "$_mp" 2>/dev/null && return 0
    mount -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    mount -t iso9660 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    mount -t exfat -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    mount -t vfat -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    mount -t ntfs3 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    mount -t ext4 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
    return 1
}

_install_mount_iso() {
    _iso="$1"
    _mp="$2"
    mount -o loop,ro "$_iso" "$_mp" 2>/dev/null && return 0
    mount -o ro,loop "$_iso" "$_mp" 2>/dev/null && return 0
    mount -o ro "$_iso" "$_mp" 2>/dev/null && return 0
    _loopdev="$(losetup -f 2>/dev/null)" || return 1
    losetup -r "$_loopdev" "$_iso" 2>/dev/null || return 1
    if mount -o ro "$_loopdev" "$_mp" 2>/dev/null; then
        return 0
    fi
    losetup -d "$_loopdev" 2>/dev/null || true
    return 1
}

medium_on_disk() {
    _disk="$1"
    if [ -f /run/silen-medium-dev ]; then
        _rec="$(cat /run/silen-medium-dev 2>/dev/null)"
        if [ -n "$_rec" ]; then
            case "$_rec" in
                "$_disk"*|"$_disk") return 0 ;;
            esac
        fi
    fi
    _mntsrc="$(mount 2>/dev/null | awk '$3 == "/mnt" {print $1}')"
    case "$_mntsrc" in
        "$_disk"*) return 0 ;;
    esac
    case "$_mntsrc" in
        /dev/loop*)
            _loopname="${_mntsrc#/dev/}"
            _backing=""
            [ -f "/sys/block/$_loopname/loop/backing_file" ] && _backing="$(cat "/sys/block/$_loopname/loop/backing_file" 2>/dev/null)" || true
            if [ -z "$_backing" ]; then
                _backing="$(losetup -a 2>/dev/null | grep "^$_mntsrc:" | sed -n 's/.*(\(.*\)).*/\1/p')"
            fi
            if [ -n "$_backing" ]; then
                _ventrysrc="$(mount 2>/dev/null | awk '$3 == "/run/ventoy" {print $1}')"
                case "$_ventrysrc" in
                    "$_disk"*) return 0 ;;
                esac
                if command -v df >/dev/null 2>&1; then
                    _backmnt="$(df "$_backing" 2>/dev/null | awk 'NR==2 {print $1}')"
                    case "$_backmnt" in
                        "$_disk"*) return 0 ;;
                    esac
                fi
                case "$_backing" in
                    "$_disk"*) return 0 ;;
                esac
            fi
            ;;
    esac
    _ventrysrc="$(mount 2>/dev/null | awk '$3 == "/run/ventoy" {print $1}')"
    case "$_ventrysrc" in
        "$_disk"*) return 0 ;;
    esac
    return 1
}

rescan_medium() {
    ensure_loop_support
    mkdir -p /mnt /run/ventoy /run/scan /iso /tmp 2>/dev/null || true
    _cands=""
    for _blk in /sys/block/*; do
        [ -d "$_blk" ] || continue
        _name="${_blk##*/}"
        case "$_name" in
            loop*|ram*|zram*|fd*) continue ;;
        esac
        _cands="$_cands /dev/$_name"
        for _part in "$_blk/$_name"?*; do
            [ -e "$_part" ] || continue
            _pn="${_part##*/}"
            case "$_pn" in
                loop*|ram*|zram*) continue ;;
            esac
            _cands="$_cands /dev/$_pn"
        done
    done || true
    for _dm in /dev/mapper/*; do
        [ -e "$_dm" ] || continue
        case " $_cands " in
            *" $_dm "*) ;;
            *) _cands="$_cands $_dm" ;;
        esac
    done || true
    for _d in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]*n[0-9]* /dev/mmcblk[0-9]* /dev/sr[0-9]*; do
        [ -b "$_d" ] || continue
        case " $_cands " in
            *" $_d "*) ;;
            *) _cands="$_cands $_d" ;;
        esac
        for _p in "$_d"?* "$_d"p?*; do
            [ -b "$_p" ] || continue
            case " $_cands " in
                *"$_p"*) ;;
                *) _cands="$_cands $_p" ;;
            esac
        done || true
    done || true
    for _dev in $_cands; do
        [ -b "$_dev" ] || continue
        umount /run/scan 2>/dev/null || true
        _install_mount_candidate "$_dev" /run/scan || continue
        if medium_has_tarball_at /run/scan; then
            umount /mnt 2>/dev/null || true
            if mount --move /run/scan /mnt 2>/dev/null; then
                :
            else
                umount /mnt 2>/dev/null || true
                _install_mount_candidate "$_dev" /mnt || { umount /run/scan 2>/dev/null || true; continue; }
                umount /run/scan 2>/dev/null || true
            fi
            echo "$_dev" > /run/silen-medium-dev 2>/dev/null || true
            return 0
        fi
        rm -f /tmp/.isolist_install 2>/dev/null || true
        touch /tmp/.isolist_install 2>/dev/null || true
        find /run/scan -maxdepth 4 -iname "*silen*.iso" 2>/dev/null | head -n 20 >> /tmp/.isolist_install || true
        find /run/scan -maxdepth 4 -iname "*.iso" 2>/dev/null | head -n 20 >> /tmp/.isolist_install || true
        _tried=""
        _found=""
        while IFS= read -r _iso; do
            [ -n "$_iso" ] || continue
            [ -f "$_iso" ] || continue
            case "$_tried" in
                *"|$_iso|"*) continue ;;
            esac
            _tried="$_tried|$_iso|"
            umount /iso 2>/dev/null || true
            _install_mount_iso "$_iso" /iso || continue
            if medium_has_tarball_at /iso; then
                umount /mnt 2>/dev/null || true
                if mount --move /run/scan /run/ventoy 2>/dev/null; then
                    :
                else
                    _install_mount_candidate "$_dev" /run/ventoy 2>/dev/null || mount -o bind /run/scan /run/ventoy 2>/dev/null || true
                fi
                if mount --move /iso /mnt 2>/dev/null; then
                    :
                else
                    umount /mnt 2>/dev/null || true
                    if ! _install_mount_iso "$_iso" /mnt; then
                        _rel="${_iso#/run/scan/}"
                        if [ "$_rel" != "$_iso" ] && [ -f "/run/ventoy/$_rel" ]; then
                            _install_mount_iso "/run/ventoy/$_rel" /mnt || continue
                        else
                            continue
                        fi
                    fi
                    umount /iso 2>/dev/null || true
                fi
                if mountpoint -q /run/scan 2>/dev/null && mountpoint -q /run/ventoy 2>/dev/null; then
                    umount /run/scan 2>/dev/null || true
                fi
                echo "$_dev" > /run/silen-medium-dev 2>/dev/null || true
                echo "$_iso" > /run/silen-medium-iso 2>/dev/null || true
                _found="1"
                break
            fi
            umount /iso 2>/dev/null || true
        done < /tmp/.isolist_install || true
        rm -f /tmp/.isolist_install 2>/dev/null || true
        umount /run/scan 2>/dev/null || true
        umount /iso 2>/dev/null || true
        [ -n "$_found" ] && return 0
    done || true
    umount /run/scan 2>/dev/null || true
    return 1
}

ensure_medium() {
    if medium_has_tarball; then
        return 0
    fi
    rescan_medium || true
    if medium_has_tarball; then
        return 0
    fi
    return 1
}

trap cleanup INT TERM

[ "$(id -u)" = "0" ] || {
    whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
    exit 1
}

whiptail --msgbox --title "$title" "Silen linux installer errors may occur" 10 40 || true


connect_internet() {
    if whiptail --title "$title" --yesno "Would you like to connect to the internet?\nNeeded for drivers wifi firmware and packages via spk" 10 55; then
        if command -v nmtui >/dev/null 2>&1; then
            nmtui 2>/dev/null || true
        fi
        if whiptail --title "$title" --yesno "Install wifi drivers now?\nUses spk for kernel modules and firmware" 10 55; then
            install_wifi_drivers
        fi
    fi
}

main_screen() {
    men1=$(whiptail --title "$title" --menu "Choose an option" 14 53 5 \
        "1" "Install Silen" \
        "2" "Configure internet nmtui and wifi drivers" \
        "3" "Wi-Fi status debug purposes" \
        "4" "Shell" \
        "5" "Reboot" \
        3>&1 1>&2 2>&3 || true)

    if [ "$men1" = "1" ]; then
        connect_internet
        partitioning
    elif [ "$men1" = "2" ]; then
        configure_internet
        main_screen
    elif [ "$men1" = "3" ]; then
        if command -v silen-wifi-check >/dev/null 2>&1; then
            silen-wifi-check /tmp/silen-wifi.log >/dev/null 2>&1 || true
            whiptail --textbox /tmp/silen-wifi.log 24 78 2>/dev/null || true
        else
            whiptail --msgbox --title "$title" "silen-wifi-check not found on this medium" 8 40 || true
        fi
        main_screen
    elif [ "$men1" = "4" ]; then
        sh || true
        main_screen
    elif [ "$men1" = "5" ]; then
        sync 2>/dev/null || true
        reboot -f 2>/dev/null || whiptail --msgbox --title "$title" "reboot failed run reboot -f from the shell or power the machine off" 8 60 || true
        main_screen
    else
        main_screen
    fi
}

configure_internet() {
    if ! command -v nmtui >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "nmtui not found on this medium might be a ventoy issue" 8 45 || true
        main_screen
        return
    fi

    nmtui 2>/dev/null || true

    if whiptail --title "$title" --yesno "Install Wi-Fi drivers now? requires network access\nThis will use spk to install kernel modules and firmware for your wifi card" 10 55; then
        install_wifi_drivers
    fi
    main_screen
}

install_wifi_drivers() {
    if ! command -v spk >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "spk not found cannot install drivers" 8 40 || true
        return
    fi

    wifi_choice=$(whiptail --title "$title" --menu "Select Wi-Fi driver package to install" 18 60 8 \
        "linux-firmware" "All firmware (Intel, AMD, Realtek, MediaTek, etc.)" \
        "rtl8822ce" "Realtek RTL8822CE rtw88_8822ce" \
        "iwlwifi" "Intel WiFi iwlwifi iwlmvm" \
        "mt7921" "MediaTek MT7921 MT7922 mt7921e" \
        "ath11k" "Qualcomm Atheros WiFi 6 6E ath11k" \
        "brcmfmac" "Broadcom FullMAC brcmfmac" \
        "rtw89" "Realtek WiFi 6 6E 7 rtw89" \
        "custom" "Enter custom package name" \
        3>&1 1>&2 2>&3 || true)

    [ -z "$wifi_choice" ] && return

    if [ "$wifi_choice" = "custom" ]; then
        wifi_choice=$(whiptail --title "$title" --inputbox "Enter spk package name from spk_pkgs" 8 50 3>&1 1>&2 2>&3 || true)
        [ -z "$wifi_choice" ] && return
    fi

    whiptail --infobox --title "$title" "Installing $wifi_choice via spk This may take a while" 8 50 2>/dev/null || true

    if spk get "$wifi_choice" 2>/tmp/spk-wifi.log; then
        whiptail --msgbox --title "$title" "Wi-Fi driver installed successfully\nRun nmtui again to connect" 8 55 || true
        if command -v modprobe >/dev/null 2>&1; then
            for _m in cfg80211 mac80211 rfkill; do modprobe -q "$_m" 2>/dev/null || true; done
        fi
        rfkill unblock all 2>/dev/null || true
        nmcli radio wifi on 2>/dev/null || true
        nmcli device wifi rescan 2>/dev/null || true
    else
        whiptail --textbox /tmp/spk-wifi.log 20 70 2>/dev/null || true
    fi
    main_screen
}


partitioning() {
    disks=()
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]*n[0-9]* /dev/mmcblk[0-9]*; do
        if [ -b "$d" ]; then
            disks+=("$d" "Disk: $d")
        fi
    done
    if [ ${#disks[@]} -eq 0 ]; then
        whiptail --msgbox --title "$title" "no disks found" 8 40 || true
        main_screen
        return
    fi
    disk=$(whiptail --title "$title" --menu "Select the disk to install on" 14 50 6 "${disks[@]}" 3>&1 1>&2 2>&3 || true)
    if [ -z "$disk" ]; then
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
    ask-install-settings

    for part in $(mount 2>/dev/null | awk -v d="$disk" 'index($1,d)==1 {print $1}' || true); do
        [ -n "$part" ] || continue
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
            if mount 2>/dev/null | awk -v d="$disk" 'index($1,d)==1 {f=1} END {exit !f}'; then
                whiptail --msgbox --title "$title" "couldn't write partition table to $disk: it is still in use (something is mounted on it). Open the shell and check 'mount'." 10 60 || true
            else
                whiptail --msgbox --title "$title" "couldn't write partition table to $disk" 8 40 || true
            fi
            return
        fi
    fi

    partprobe "$disk" 2>/dev/null || blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || true
    if [ -b "${disk}p1" ]; then
        bootp="${disk}p1"
        rootp="${disk}p2"
    else
        bootp="${disk}1"
        rootp="${disk}2"
    fi
    _wait=0
    while [ ! -b "$bootp" ] || [ ! -b "$rootp" ]; do
        [ "$_wait" -ge 50 ] && break
        sleep 0.1 2>/dev/null || sleep 1 2>/dev/null || true
        _wait=$((_wait + 1))
        if [ "$_wait" = "20" ]; then
            blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || true
        fi
    done
    if [ ! -b "$bootp" ] || [ ! -b "$rootp" ]; then
        whiptail --msgbox --title "$title" "partitioning failed, no partitions on $disk" 8 40 || true
        partitioning
        return
    fi
    whiptail --infobox "Formatting $bootp FAT32 and $rootp ext4" 8 60 2>/dev/null || true
    if ! mkfs.vfat -F 32 -n SILENBOOT "$bootp" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't format $bootp as FAT32" 8 40 || true
        return
    fi
    if ! mkfs.ext4 -F -q -L silenroot -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "$rootp" 2>/dev/null; then
        if ! mkfs.ext4 -F -L silenroot -E nodiscard "$rootp"; then
            whiptail --msgbox --title "$title" "couldn't format the partitions" 8 40 || true
            return
        fi
    fi
    install-base
}

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
    for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz; do
        [ -f "$s" ] && stage3="$s" && break
    done || true
    if [ -z "$stage3" ]; then
        whiptail --msgbox --title "$title" "no Silen tarball found on the install medium" 8 40 || true
        cleanup
        return
    fi
    whiptail --infobox "Installing the system files, this might take a while...\n(extracting $(basename "$stage3"))" 8 60 2>/dev/null || true
    if [ "$(tar -tf "$stage3" 2>/dev/null | awk -F/ 'NF>1 {print $1}' | sort -u | wc -l)" = "1" ]; then
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
    whiptail --infobox "Installing the system files, this might take a while...\n(fixing permissions)" 8 60 2>/dev/null || true
    fix-permissions

    mkdir -p "$root"/proc "$root"/sys "$root"/dev "$root"/run "$root"/etc "$root"/usr/share/zoneinfo
    mount -t proc proc "$root"/proc
    mount -t sysfs sysfs "$root"/sys
    mount --rbind /dev "$root"/dev
    mount --rbind /run "$root"/run

    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$root"/etc/resolv.conf
    else
        echo "nameserver 1.1.1.1" > "$root"/etc/resolv.conf
    fi
    echo "$hostnm" > "$root"/etc/hostname
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

    whiptail --infobox "Installing the system files, this might take a while...\n(copying kernel and drivers)" 8 60 2>/dev/null || true
    install-modules
    whiptail --infobox "Installing the system files, this might take a while...\n(installing packages and network)" 8 60 2>/dev/null || true
    install-spk
    install-network
    whiptail --infobox "Installing the system files, this might take a while...\n(configuring Wi-Fi)" 8 60 2>/dev/null || true
    install-wifi
    whiptail --infobox "Installing the system files, this might take a while...\n(installing GPU drivers)" 8 60 2>/dev/null || true
    install-drivers
    whiptail --infobox "Installing the system files, this might take a while...\n(installing Desktop Environment)" 8 60 2>/dev/null || true
    install-desktop
    whiptail --infobox "Installing the system files, this might take a while...\n(creating users and finishing setup)" 8 60 2>/dev/null || true
    create-user
    install-branding
    fix-user-session
    if [ -n "${_elogind_hint:-}" ]; then
        whiptail --msgbox --title "$title" "Note: elogind is not in this image. If you later see 'user.<name> failed to start' or session errors, just run as root after reboot:\n\n  spk get elogind\n  rc-update add elogind boot\n  reboot\n\nLogin still works without it." 13 65 || true
    fi
    setup-quiet-boot
    setup-grub

    sync 2>/dev/null || true
    cleanup
    whiptail --msgbox --title "$title" "Silen is installed, reboot when ready" 8 40 || true
    main_screen
}

ask-install-settings() {
    hostnm=$(hostname 2>/dev/null || true)
    case "$hostnm" in
        ""|archlinux|"(none)"|localhost) hostnm="silen" ;;
    esac
    hostnm=$(whiptail --title "$title" --inputbox "Set the hostname" 8 40 "$hostnm" 3>&1 1>&2 2>&3 || true)
    [ -z "$hostnm" ] && hostnm="silen"

    rootpass=""
    while :; do
        rootpass=$(whiptail --title "$title" --passwordbox "Set the root password" 8 40 3>&1 1>&2 2>&3 || true)
        [ -n "$rootpass" ] && break
        whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true
    done

    newuser=""
    userpass=""
    if whiptail --title "$title" --yesno "Create a user account (in addition to root)?" 8 50; then
        while :; do
            newuser=$(whiptail --title "$title" --inputbox "Username for the new account (empty = skip):" 8 50 3>&1 1>&2 2>&3 || true)
            [ -z "$newuser" ] && break
            if [ "$newuser" = "root" ]; then
                whiptail --msgbox --title "$title" "root already exists, pick another name" 8 40 || true
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
                    if [ "${#newuser}" -gt 32 ]; then
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
        while [ -n "$newuser" ]; do
            userpass=$(whiptail --title "$title" --passwordbox "Password for $newuser:" 8 40 3>&1 1>&2 2>&3 || true)
            [ -n "$userpass" ] && break
            whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true
        done || true
    fi

    zone=$(whiptail --title "$title" --menu "Select timezone" 14 50 6 \
        "UTC" "UTC" \
        "Europe/Berlin" "Central European Time" \
        "Europe/London" "British Time" \
        "America/New_York" "US Eastern" \
        "Asia/Tokyo" "Japan" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$zone" ] && zone="UTC"

    keymap=$(whiptail --title "$title" --menu "Select keyboard layout" 14 50 6 \
        "us" "US English" \
        "de" "German" \
        "gb" "British" \
        "fr" "French" \
        "es" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$keymap" ] && keymap="us"

    locale=$(whiptail --title "$title" --menu "Select locale" 14 50 6 \
        "en_US.UTF-8" "US English" \
        "de_DE.UTF-8" "German" \
        "en_GB.UTF-8" "British" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$locale" ] && locale="en_US.UTF-8"

    want_wifi=""
    if whiptail --title "$title" --yesno "Configure Wi-Fi now requires network access" 8 50; then
        want_wifi="1"
    fi

    want_de=""
    de_choice=""
    dm_choice=""
    if whiptail --title "$title" --yesno "Install a Desktop Environment and Login Manager" 8 50; then
        want_de="1"
        de_choice=$(whiptail --title "$title" --menu "Select Desktop Environment" 14 50 6 \
            "kde" "KDE Plasma" \
            "gnome" "GNOME" \
            "xfce" "XFCE" \
            "i3" "i3wm" \
            "sway" "Sway (Wayland)" \
            "none" "No DE (window manager only)" \
            3>&1 1>&2 2>&3 || true)
        [ -z "$de_choice" ] && de_choice="none"
        if [ "$de_choice" != "none" ] && [ "$de_choice" != "sway" ]; then
            dm_choice=$(whiptail --title "$title" --menu "Select Login Manager" 14 50 6 \
                "sddm" "SDDM (recommended for KDE)" \
                "gdm" "GDM (recommended for GNOME)" \
                "lightdm" "LightDM" \
                3>&1 1>&2 2>&3 || true)
            [ -z "$dm_choice" ] && dm_choice="sddm"
        elif [ "$de_choice" = "sway" ]; then
            dm_choice="gdm"
        fi
    fi

    driver_choice=""
    if whiptail --title "$title" --yesno "Install GPU drivers" 8 40; then
        driver_choice=$(whiptail --title "$title" --menu "Select GPU driver" 14 50 6 \
            "nvidia" "NVIDIA (proprietary)" \
            "nvidia-legacy" "NVIDIA Legacy (470xx/390xx)" \
            "amd" "AMD (mesa/amdgpu)" \
            "intel" "Intel (mesa/i915)" \
            "vmware" "VMware (mesa/vmwgfx)" \
            "none" "Skip GPU drivers" \
            3>&1 1>&2 2>&3 || true)
        [ -z "$driver_choice" ] && driver_choice="none"
    fi

    want_swap=""
    if whiptail --title "$title" --yesno "Create a 1G swapfile" 8 40; then
        want_swap="1"
    fi
}


fix-permissions() {
    for _s in bin/su usr/bin/su \
               bin/passwd usr/bin/passwd \
               usr/bin/chage usr/bin/chfn usr/bin/chsh \
               usr/bin/gpasswd usr/bin/newgrp \
               bin/mount usr/bin/mount bin/umount usr/bin/umount \
               usr/bin/sudo bin/sudo usr/bin/sudoedit bin/sudoedit; do
        if [ -e "$root/$_s" ] && [ ! -L "$root/$_s" ]; then
            chown root:root "$root/$_s" 2>/dev/null || true
            chmod 4755 "$root/$_s" 2>/dev/null || true
        fi
    done || true
    for _u in bin/unix_chkpwd usr/bin/unix_chkpwd sbin/unix_chkpwd usr/sbin/unix_chkpwd; do
        if [ -e "$root/$_u" ] && [ ! -L "$root/$_u" ]; then
            chown root:shadow "$root/$_u" 2>/dev/null || chown root:root "$root/$_u" 2>/dev/null || true
            chmod 4755 "$root/$_u" 2>/dev/null || chmod 2711 "$root/$_u" 2>/dev/null || true
        fi
    done || true
    if [ -f "$root/etc/shadow" ]; then
        chown root:shadow "$root/etc/shadow" 2>/dev/null || chown root:root "$root/etc/shadow" 2>/dev/null || true
        chmod 640 "$root/etc/shadow" 2>/dev/null || chmod 600 "$root/etc/shadow" 2>/dev/null || true
    fi
    if [ -f "$root/etc/gshadow" ]; then
        chown root:shadow "$root/etc/gshadow" 2>/dev/null || chown root:root "$root/etc/gshadow" 2>/dev/null || true
        chmod 640 "$root/etc/gshadow" 2>/dev/null || chmod 600 "$root/etc/gshadow" 2>/dev/null || true
    fi
    if [ -f "$root/etc/passwd" ]; then
        chmod 644 "$root/etc/passwd" 2>/dev/null || true
    fi
    if [ -f "$root/etc/group" ]; then
        chmod 644 "$root/etc/group" 2>/dev/null || true
    fi
    if ! chroot "$root" /bin/bash -c "getent group wheel" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "groupadd -r wheel" >/dev/null 2>&1 || true
    fi
}


fix-user-session() {
    mkdir -p "$root/run/user" "$root/run/openrc" "$root/run/dbus" 2>/dev/null || true
    chmod 755 "$root/run/user" 2>/dev/null || true
    mkdir -p "$root/usr/lib/tmpfiles.d" "$root/etc/tmpfiles.d" 2>/dev/null || true
    printf 'd /run/user 0755 root root -\n' > "$root/usr/lib/tmpfiles.d/silen-run-user.conf" 2>/dev/null || true
    if [ -f "$root/etc/rc.conf" ]; then
        if grep -q '^[[:space:]]*rc_autostart_user=' "$root/etc/rc.conf" 2>/dev/null; then
            sed -i 's/^[[:space:]]*rc_autostart_user=.*/rc_autostart_user="YES"/' "$root/etc/rc.conf" 2>/dev/null || true
        fi
    fi
    if chroot "$root" /bin/bash -c "command -v elogind >/dev/null 2>&1 || test -f /etc/init.d/elogind" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "rc-update add elogind boot" >/dev/null 2>&1 || \
        chroot "$root" /bin/bash -c "rc-update add elogind default" >/dev/null 2>&1 || true
    else
        _elogind_hint="1"
    fi
}

apply-settings() {
    ln -sf /usr/share/zoneinfo/$zone "$root"/etc/localtime

    mkdir -p "$root"/etc/conf.d
    echo "keymap=\"$keymap\"" > "$root"/etc/conf.d/keymaps

    echo "$locale UTF-8" > "$root"/etc/locale.gen
    if ! chroot "$root" /bin/bash -c "locale-gen" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't generate locales, check locale.gen later" 8 40 || true
    fi
    mkdir -p "$root"/etc/env.d
    echo "LANG=\"$locale\"" > "$root"/etc/env.d/02locale

    made_swapfile=""
    if [ -n "${want_swap:-}" ]; then
        if chroot "$root" /bin/bash -c "fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile" 2>/dev/null; then
            made_swapfile="1"
        else
            whiptail --msgbox --title "$title" "couldn't create the swapfile" 8 40 || true
        fi
    fi

    printf 'Welcome to Silen Linux\n' > "$root"/etc/motd 2>/dev/null || true

    cat > "$root"/etc/profile.d/silen-hostname.sh <<'EOF'
if [ -f /etc/hostname ]; then
    HOSTNAME=$(cat /etc/hostname 2>/dev/null)
    export HOSTNAME
fi
EOF
    chmod 644 "$root"/etc/profile.d/silen-hostname.sh 2>/dev/null || true

    cat > "$root"/etc/bash.bashrc <<'EOF'
[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
EOF
    chmod 644 "$root"/etc/bash.bashrc 2>/dev/null || true
}

create-user() {
    [ -n "${newuser:-}" ] || return 0
    if ! chroot "$root" /bin/bash -c "command -v useradd" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser (no useradd in the new system)" 8 60 || true
        return 0
    fi
    usergroups=""
    for g in wheel sudo audio video network plugdev; do
        if chroot "$root" /bin/bash -c "getent group $g" >/dev/null 2>&1; then
            if [ -z "$usergroups" ]; then
                usergroups="$g"
            else
                usergroups="$usergroups,$g"
            fi
        fi
    done || true
    if [ -n "$usergroups" ]; then
        _uflags="-m -s /bin/bash -G $usergroups"
    else
        _uflags="-m -s /bin/bash"
    fi
    if ! chroot "$root" /bin/bash -c "useradd $_uflags $newuser" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser - add it by hand after reboot with useradd" 8 60 || true
        return 0
    fi
    if ! printf '%s:%s\n' "$newuser" "$userpass" | chroot "$root" /bin/bash -c "chpasswd" 2>/dev/null; then
        whiptail --msgbox --title "$title" "user $newuser created but the password couldn't be set - run passwd $newuser after reboot" 8 60 || true
    fi
    userpass=""
    if ! chroot "$root" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "usermod -aG wheel $newuser" >/dev/null 2>&1 || true
    fi
    if ! chroot "$root" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "user $newuser is not in the wheel group, so 'su -' will refuse even the right password. After reboot run as root: usermod -aG wheel $newuser" 9 70 || true
    fi
    if mkdir -p "$root"/home/$newuser/.local/bin \
             "$root"/home/$newuser/.local/share/spk/apps \
             "$root"/home/$newuser/.local/share/spk/packages \
             "$root"/home/$newuser/.cache/spk 2>/dev/null; then
        chroot "$root" /bin/bash -c "chown -R $newuser:$newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || \
        chroot "$root" /bin/bash -c "chown -R $newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || true
    fi
    chroot "$root" /bin/bash -c "chown $newuser:$(id -gn $newuser 2>/dev/null || echo \$newuser) /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || \
    chroot "$root" /bin/bash -c "chown $newuser /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || true
}

install-modules() {
	mkdir -p "$root"/lib/modules
	kernel_tar=""
	for f in /mnt/kernel-*.tar.*; do
		[ -f "$f" ] && kernel_tar="$f" && break
	done || true
	if [ -n "$kernel_tar" ]; then
		kname="$(basename "$kernel_tar")"
		bundle_kver="${kname#kernel-}"
		bundle_kver="${bundle_kver%%.tar.*}"
		if ! tar -xpf "$kernel_tar" -C "$root" --no-same-owner --numeric-owner; then
			whiptail --msgbox --title "$title" "couldn't unpack the kernel/modules from the install medium. The system may not boot." 10 60 || true
		fi
	elif [ -d /mnt/modules ] && [ -n "$(ls /mnt/modules 2>/dev/null)" ]; then
		cp -a /mnt/modules/. "$root"/lib/modules/ 2>/dev/null || true
	elif [ -d /lib/modules ]; then
		cp -a /lib/modules/. "$root"/lib/modules/ 2>/dev/null || true
	fi
	if [ -n "${bundle_kver:-}" ] && [ -d "$root/lib/modules/$bundle_kver" ]; then
		kver="$bundle_kver"
	else
		kver="$(ls "$root"/lib/modules 2>/dev/null | head -n1)"
	fi
if [ -n "$kver" ] && chroot "$root" /bin/bash -c "command -v depmod" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "depmod -a $kver" 2>/dev/null || true
	fi
	if [ -d /mnt/firmware ] && [ -n "$(ls /mnt/firmware 2>/dev/null)" ]; then
		mkdir -p "$root"/lib/firmware
		cp -a /mnt/firmware/. "$root"/lib/firmware/ 2>/dev/null || true
	fi
	if [ -d /lib/firmware ]; then
		mkdir -p "$root"/lib/firmware
		find /lib/firmware -mindepth 1 | while IFS= read -r _src; do
			_rel="${_src#/lib/firmware/}"
			[ -n "$_rel" ] || continue
			if [ -e "$root/lib/firmware/$_rel" ]; then
				continue
			fi
			if [ -d "$_src" ]; then
				mkdir -p "$root/lib/firmware/$_rel" 2>/dev/null || true
			else
				mkdir -p "$root/lib/firmware/$(dirname "$_rel")" 2>/dev/null || true
				cp -a "$_src" "$root/lib/firmware/$_rel" 2>/dev/null || true
			fi
		done || true
	fi
	mkdir -p "$root"/etc/modprobe.d 2>/dev/null || true
	cat > "$root"/etc/modprobe.d/silen-rtw88.conf <<'EOF'
options rtw88_pci disable_aspm=Y
options rtw88_core disable_lps_deep=Y
EOF
	if [ -f /etc/modules ]; then
		mkdir -p "$root"/etc/modules-load.d 2>/dev/null || true
		grep -E '^(cfg80211|mac80211|rfkill|iwlwifi|iwlmvm|ipw2100|ipw2200|ath9k|ath10k|ath11k|ath12k|ath6kl|carl9170|ar5523|wil6210|zd1211|mt7|mt76|rtw88|rtw89|rtl8|brcmfmac|brcmsmac|b43|wl12xx|wl18xx|wlcore|wl1251|mwifiex|mwl8k|libertas|usb8xxx|p54|at76c50x|adm8211|rsi|wfx|wilc|rt2|rt3)' /etc/modules 2>/dev/null | sort -u > "$root/etc/modules-load.d/silen-wifi.conf" 2>/dev/null || true
		if [ -s "$root/etc/modules-load.d/silen-wifi.conf" ] && [ -f "$root/etc/conf.d/modules" ]; then
			_wifi_mods="$(tr '\n' ' ' < "$root/etc/modules-load.d/silen-wifi.conf" 2>/dev/null)"
			if [ -n "$_wifi_mods" ] && ! grep -q '^modules=' "$root/etc/conf.d/modules" 2>/dev/null; then
				printf 'modules="%s"\n' "$_wifi_mods" >> "$root/etc/conf.d/modules" 2>/dev/null || true
			fi
		fi
	fi
}

install-spk() {
    spk_src=""
    for f in /mnt/spk.tar.*; do
        [ -f "$f" ] && spk_src="$f" && break
    done || true
    if [ -n "$spk_src" ]; then
        tar -xpf "$spk_src" -C "$root"/usr/bin
        return
    fi
    if [ -f /usr/bin/spk ]; then
        cp /usr/bin/spk "$root"/usr/bin/spk
        return
    fi
    if [ -f /mnt/spk ]; then
        cp /mnt/spk "$root"/usr/bin/spk
        return
    fi
    if [ -d /mnt/spk ]; then
        cp -r /mnt/spk "$root"/usr/bin/spk 2>/dev/null && return
    fi
    url=$(whiptail --title "$title" --inputbox "spk not found, enter a git url to clone it (leave empty to skip):" 8 46 3>&1 1>&2 2>&3 || true)
    if [ -n "$url" ]; then
        if ! git clone "$url" /tmp/spk 2>/dev/null; then
            whiptail --msgbox --title "$title" "couldn't clone spk" 8 40 || true
            return
        fi
        cp -r /tmp/spk "$root"/usr/src/spk 2>/dev/null || true
        if ! chroot "$root" /bin/bash -c "cd /usr/src/spk && make install" 2>/dev/null; then
            whiptail --msgbox --title "$title" "couldn't build spk, keeping the source in /usr/src/spk" 8 40 || true
        fi
    fi
}

install-network() {
    net_tar=""
    for f in /mnt/network.tar.*; do
        [ -f "$f" ] && net_tar="$f" && break
    done || true
    if [ -n "$net_tar" ]; then
        if ! tar -xpf "$net_tar" -C "$root" --skip-old-files --no-same-owner --numeric-owner 2>/dev/null; then
            if ! tar -xpf "$net_tar" -C "$root" -k --no-same-owner --numeric-owner 2>/dev/null; then
                tar -xpf "$net_tar" -C "$root" --no-same-owner --numeric-owner 2>/dev/null || \
                    whiptail --msgbox --title "$title" "couldn't unpack the network bundle, trying the live files instead" 8 60 || true
            fi
        fi
    fi
    if [ -z "$net_tar" ] || [ ! -x "$root"/usr/bin/NetworkManager ]; then
        install-network-from-live
    fi
    install-network-config
}

install-network-from-live() {
    net_missing=""
    mkdir -p "$root"/usr/bin "$root"/usr/lib "$root"/usr/lib64
    for _b in NetworkManager nmtui nmtui-connect nmtui-edit nmtui-hostname \
            nmcli nm-online dbus-daemon dbus-uuidgen wpa_supplicant wpa_cli; do
        _src=""
        if [ -e "/usr/bin/$_b" ] || [ -L "/usr/bin/$_b" ]; then _src="/usr/bin/$_b"; fi
        if [ -z "$_src" ] && { [ -e "/usr/sbin/$_b" ] || [ -L "/usr/sbin/$_b" ]; }; then
            _src="/usr/sbin/$_b"
        fi
        if [ -z "$_src" ]; then
            net_missing="$net_missing $_b"
            continue
        fi
        cp -a "$_src" "$root"/usr/bin/ 2>/dev/null || net_missing="$net_missing $_b"
    done || true
    for _b in rfkill iw; do
        _src=""
        if [ -e "/usr/bin/$_b" ] || [ -L "/usr/bin/$_b" ]; then _src="/usr/bin/$_b"; fi
        if [ -z "$_src" ] && { [ -e "/usr/sbin/$_b" ] || [ -L "/usr/sbin/$_b" ]; }; then
            _src="/usr/sbin/$_b"
        fi
        [ -z "$_src" ] && continue
        cp -a "$_src" "$root"/usr/bin/ 2>/dev/null || true
    done || true
    for _lib in /usr/lib64/*; do
        [ -e "$_lib" ] || [ -L "$_lib" ] || continue
        [ -f "$_lib" ] || [ -L "$_lib" ] || continue
        _bn="$(basename "$_lib")"
        if [ -e "$root/usr/lib64/$_bn" ] || [ -e "$root/usr/lib/$_bn" ]; then
            continue
        fi
        cp -a "$_lib" "$root"/usr/lib64/ 2>/dev/null || true
    done || true
    if [ -d /usr/lib/NetworkManager ]; then
        mkdir -p "$root"/usr/lib/NetworkManager
        cp -a /usr/lib/NetworkManager/. "$root"/usr/lib/NetworkManager/ 2>/dev/null || true
    fi
    for _h in /usr/lib/nm-dispatcher /usr/lib/nm-priv-helper \
            /usr/lib/nm-daemon-helper /usr/lib/nm-dhcp-helper \
            /usr/lib/nm-libnm-helper; do
        [ -e "$_h" ] || [ -L "$_h" ] || continue
        [ -e "$root/usr/lib/${_h##*/}" ] && continue
        cp -a "$_h" "$root"/usr/lib/ 2>/dev/null || true
    done || true
}

install-network-config() {
    mkdir -p "$root"/etc/NetworkManager/system-connections \
             "$root"/etc/NetworkManager/conf.d \
             "$root"/etc/NetworkManager/dispatcher.d \
             "$root"/usr/share/dbus-1/system.d \
             "$root"/usr/share/dbus-1/system-services \
             "$root"/run/dbus "$root"/run/NetworkManager "$root"/run/wpa_supplicant \
             "$root"/run/user \
             "$root"/var/lib/NetworkManager "$root"/var/lib/dbus \
             "$root"/etc/init.d
    chmod 700 "$root"/etc/NetworkManager/system-connections 2>/dev/null || true
    chmod 755 "$root"/run/user 2>/dev/null || true
    mkdir -p "$root/usr/lib/tmpfiles.d" 2>/dev/null || true
    printf 'd /run/dbus 0755 root root -\nd /run/NetworkManager 0755 root root -\nd /run/wpa_supplicant 0755 root root -\n' > "$root/usr/lib/tmpfiles.d/silen-network.conf" 2>/dev/null || true
    if [ ! -f "$root"/etc/NetworkManager/NetworkManager.conf ]; then
        if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
            cp /etc/NetworkManager/NetworkManager.conf "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        else
            cat > "$root"/etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal
dns=default
auth-polkit=false
wifi.backend=wpa_supplicant

[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.powersave=2
EOF
        fi
    else
        if ! grep -q '^\[device\]' "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            printf '\n[device]\nwifi.scan-rand-mac-address=no\n' >> "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        fi
        if ! grep -q '^auth-polkit=' "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            if grep -q '^\[main\]' "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                sed -i '/^\[main\]/a auth-polkit=false\nwifi.backend=wpa_supplicant' "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null || \
                    printf '\nauth-polkit=false\nwifi.backend=wpa_supplicant\n' >> "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            else
                printf '\n[main]\nauth-polkit=false\nwifi.backend=wpa_supplicant\n' >> "$root"/etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
            fi
        fi
    fi
    for _dbc in org.freedesktop.NetworkManager.conf wpa_supplicant.conf nm-dispatcher.conf; do
        if [ ! -f "$root"/usr/share/dbus-1/system.d/$_dbc ] && [ -f /usr/share/dbus-1/system.d/$_dbc ]; then
            cp /usr/share/dbus-1/system.d/$_dbc "$root"/usr/share/dbus-1/system.d/ 2>/dev/null || true
        fi
    done || true
    if [ ! -f "$root"/usr/share/dbus-1/system.conf ] && [ -f /usr/share/dbus-1/system.conf ]; then
        cp /usr/share/dbus-1/system.conf "$root"/usr/share/dbus-1/system.conf 2>/dev/null || true
    fi
    if [ -f "$root/usr/share/dbus-1/system.conf" ]; then
        if ! grep -q '<fork/>' "$root/usr/share/dbus-1/system.conf" 2>/dev/null; then
            sed -i 's|<busconfig>|<busconfig>\n\n  <fork/>|' \
                "$root/usr/share/dbus-1/system.conf" 2>/dev/null || true
        fi
        if ! grep -q '<pidfile>' "$root/usr/share/dbus-1/system.conf" 2>/dev/null; then
            sed -i 's|<fork/>|<fork/>\n\n  <pidfile>/run/dbus/pid</pidfile>|' \
                "$root/usr/share/dbus-1/system.conf" 2>/dev/null || true
        fi
    fi
    if [ ! -e "$root"/usr/lib/dbus-daemon-launch-helper ]; then
        if [ -e /usr/lib/dbus-daemon-launch-helper ]; then
            cp -a /usr/lib/dbus-daemon-launch-helper "$root"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
        elif [ -e /usr/libexec/dbus-daemon-launch-helper ]; then
            cp -a /usr/libexec/dbus-daemon-launch-helper "$root"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
        fi
    fi
    if [ -e "$root"/usr/lib/dbus-daemon-launch-helper ]; then
        chown root:root "$root"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
        chmod 4755 "$root"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
    fi
    if [ -e "$root"/usr/lib/dbus-daemon-launch-helper ] && [ ! -e "$root"/usr/libexec/dbus-daemon-launch-helper ]; then
        mkdir -p "$root"/usr/libexec 2>/dev/null || true
        cp -a "$root"/usr/lib/dbus-daemon-launch-helper "$root"/usr/libexec/dbus-daemon-launch-helper 2>/dev/null || true
    fi
    if [ -f /usr/bin/silen-wifi-check ]; then
        mkdir -p "$root"/usr/local/bin 2>/dev/null || true
        cp /usr/bin/silen-wifi-check "$root"/usr/local/bin/silen-wifi-check 2>/dev/null || true
        chmod 0755 "$root"/usr/local/bin/silen-wifi-check 2>/dev/null || true
    fi
    if [ ! -f "$root"/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service ] && \
       [ -f /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service ]; then
        cp /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service \
            "$root"/usr/share/dbus-1/system-services/ 2>/dev/null || true
    fi
    chroot "$root" /bin/bash -c "ldconfig" 2>/dev/null || true
    _mid=""
    if [ -x "$root/usr/bin/dbus-uuidgen" ]; then
        _mid="$(chroot "$root" /usr/bin/dbus-uuidgen --get 2>/dev/null || true)"
    fi
    [ -z "$_mid" ] && _mid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || true)"
    if [ -n "$_mid" ]; then
        echo "$_mid" > "$root"/etc/machine-id 2>/dev/null || true
        cp "$root"/etc/machine-id "$root"/var/lib/dbus/machine-id 2>/dev/null || true
    fi
    cat > "$root"/etc/init.d/dbus <<'EOF'
#!/sbin/openrc-run
command=/usr/bin/dbus-daemon
command_args="--system --fork"
pidfile=/run/dbus/pid
name="D-Bus system daemon"

depend() {
	need localmount
	after bootmisc
}

start_pre() {
	mkdir -p /run/dbus
	if [ ! -s /etc/machine-id ] && [ -x /usr/bin/dbus-uuidgen ]; then
		/usr/bin/dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || /usr/bin/dbus-uuidgen --ensure 2>/dev/null || true
	fi
	if [ ! -s /var/lib/dbus/machine-id ] && [ -s /etc/machine-id ]; then
		cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
	fi
}
EOF
    _nm_cmd=/usr/bin/NetworkManager
    [ -x "$root"/usr/bin/NetworkManager ] || _nm_cmd=/usr/sbin/NetworkManager
    cat > "$root"/etc/init.d/NetworkManager <<EOF
#!/sbin/openrc-run
command=$_nm_cmd
command_args="--pid-file=/run/NetworkManager.pid"
pidfile=/run/NetworkManager.pid
name="NetworkManager"

depend() {
	need dbus localmount
	after bootmisc modules
	provide net
}

start_pre() {
	mkdir -p /run/NetworkManager /var/lib/NetworkManager /run/wpa_supplicant 2>/dev/null || true
	if command -v rfkill >/dev/null 2>&1; then
		rfkill unblock all >/dev/null 2>&1 || true
	fi
}
EOF
    cat > "$root"/etc/init.d/wpa_supplicant <<'EOF'
#!/sbin/openrc-run
command=/usr/bin/wpa_supplicant
command_args="-B -P /run/wpa_supplicant.pid -u -s -O /run/wpa_supplicant"
pidfile=/run/wpa_supplicant.pid
name="wpa_supplicant"

depend() {
	need dbus localmount
	after bootmisc modules
	before NetworkManager
}

start_pre() {
	mkdir -p /run/wpa_supplicant 2>/dev/null || true
}
EOF
    chmod 755 "$root"/etc/init.d/dbus "$root"/etc/init.d/NetworkManager "$root"/etc/init.d/wpa_supplicant
    mkdir -p "$root"/etc/local.d 2>/dev/null || true
    cat > "$root"/etc/local.d/wifi-unblock.start <<'EOF'
#!/bin/sh
if command -v rfkill >/dev/null 2>&1; then
	rfkill unblock all >/dev/null 2>&1 || true
fi
if command -v nmcli >/dev/null 2>&1; then
	nmcli radio wifi on >/dev/null 2>&1 || true
	nmcli networking on >/dev/null 2>&1 || true
	nmcli device wifi rescan >/dev/null 2>&1 || true
fi
EOF
    chmod 0755 "$root"/etc/local.d/wifi-unblock.start 2>/dev/null || true
    _net_broken=""
    for _bin in /usr/bin/dbus-daemon /usr/bin/NetworkManager /usr/bin/wpa_supplicant /usr/bin/nmcli /usr/bin/nmtui; do
        if [ -x "$root$_bin" ] && ! chroot "$root" "${_bin#/usr/bin/}" --version >/dev/null 2>&1; then
            if [ "$_bin" = "/usr/bin/wpa_supplicant" ] && ! chroot "$root" /usr/bin/wpa_supplicant -v >/dev/null 2>&1; then
                _net_broken="$_net_broken ${_bin##*/}"
            elif [ "$_bin" != "/usr/bin/wpa_supplicant" ]; then
                _net_broken="$_net_broken ${_bin##*/}"
            fi
        fi
    done || true
    if [ -n "$_net_broken" ]; then
        whiptail --msgbox --title "$title" "Network tools copied but fail to run in the new system missing libraries $_net_broken Wi-Fi may not work after reboot run silen-wifi-check then" 10 65 || true
    fi
    _rc_ok="1"
    chroot "$root" /bin/bash -c "rc-update add dbus default" >/dev/null 2>&1 || _rc_ok=""
    chroot "$root" /bin/bash -c "rc-update add wpa_supplicant default" >/dev/null 2>&1 || _rc_ok=""
    chroot "$root" /bin/bash -c "rc-update add NetworkManager default" >/dev/null 2>&1 || _rc_ok=""
    if [ -z "$_rc_ok" ]; then
        whiptail --msgbox --title "$title" "NetworkManager was copied but couldn't be enabled; after reboot run: rc-update add dbus default; rc-update add wpa_supplicant default; rc-update add NetworkManager default" 9 70 || true
    fi
    if [ -n "${net_missing:-}" ]; then
        whiptail --msgbox --title "$title" "NetworkManager was installed, but these live tools were missing and got skipped:$net_missing" 8 60 || true
    fi
    if [ ! -x "$root"/usr/bin/NetworkManager ] || [ ! -x "$root"/usr/bin/nmtui ]; then
        whiptail --msgbox --title "$title" "NetworkManager/nmtui couldn't be installed (not on the medium and not in the live system); Wi-Fi will need manual setup after reboot" 9 70 || true
    fi
}

install-wifi() {
    [ -n "${want_wifi:-}" ] || return 0
    if [ ! -x "$root"/usr/bin/nmtui ] && [ ! -x "$root"/usr/bin/nmcli ]; then
        whiptail --msgbox --title "$title" "NetworkManager not available, skipping Wi-Fi setup" 8 50 || true
        return 0
    fi
    whiptail --msgbox --title "$title" "Wi-Fi will be configured on first boot via nmtui. After reboot, run 'nmtui' as root to connect." 8 60 || true
    chroot "$root" /bin/bash -c "rc-update add dbus default" >/dev/null 2>&1 || true
    chroot "$root" /bin/bash -c "rc-update add wpa_supplicant default" >/dev/null 2>&1 || true
    chroot "$root" /bin/bash -c "rc-update add NetworkManager default" >/dev/null 2>&1 || true

    whiptail --infobox --title "$title" "Installing Wi-Fi drivers linux-firmware" 8 50 2>/dev/null || true
    chroot "$root" /bin/bash -c "spk get linux-firmware" 2>"$root/tmp/spk-wifi-install.log" || \
        whiptail --msgbox --title "$title" "Failed to install linux-firmware via spk. Check /tmp/spk-wifi-install.log after reboot." 8 60 || true

    for pkg in rtl8822ce iwlwifi mt7921 ath11k brcmfmac rtw89; do
        chroot "$root" /bin/bash -c "spk get $pkg" 2>>"$root/tmp/spk-wifi-install.log" || true
    done
}

install-drivers() {
    case "${driver_choice:-none}" in
        nvidia)
            chroot "$root" /bin/bash -c "spk get nvidia-drivers" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install nvidia-drivers via spk Run spk get nvidia-drivers after boot" 8 70 || true
            mkdir -p "$root"/etc/modprobe.d
            cat > "$root"/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia NVreg_UsePageAttributeTable=1
options nvidia_drm modeset=1
EOF
            printf 'nvidia\nnvidia_drm\nnvidia_modeset\nnvidia_uvm\n' > "$root"/etc/modules-load.d/nvidia.conf 2>/dev/null || true
            ;;
        nvidia-legacy)
            chroot "$root" /bin/bash -c "spk get nvidia-legacy-drivers" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install nvidia-legacy-drivers via spk Run spk get nvidia-legacy-drivers after boot" 8 70 || true
            mkdir -p "$root"/etc/modprobe.d
            cat > "$root"/etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia NVreg_UsePageAttributeTable=1
options nvidia_drm modeset=1
EOF
            printf 'nvidia\nnvidia_drm\nnvidia_modeset\nnvidia_uvm\n' > "$root"/etc/modules-load.d/nvidia.conf 2>/dev/null || true
            ;;
        amd)
            chroot "$root" /bin/bash -c "spk get mesa xf86-video-amdgpu" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install AMD drivers via spk" 8 70 || true
            mkdir -p "$root/etc/modules-load.d" 2>/dev/null || true
            printf 'amdgpu\n' > "$root"/etc/modules-load.d/amdgpu.conf 2>/dev/null || true
            ;;
        intel)
            chroot "$root" /bin/bash -c "spk get mesa xf86-video-intel" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install Intel drivers via spk" 8 70 || true
            mkdir -p "$root/etc/modules-load.d" 2>/dev/null || true
            printf 'i915\n' > "$root"/etc/modules-load.d/intel.conf 2>/dev/null || true
            ;;
        vmware)
            chroot "$root" /bin/bash -c "spk get mesa xf86-video-vmware" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install VMware drivers via spk" 8 70 || true
            mkdir -p "$root/etc/modules-load.d" 2>/dev/null || true
            printf 'vmwgfx\n' > "$root"/etc/modules-load.d/vmwgfx.conf 2>/dev/null || true
            ;;
    esac
}


install-gpu-drivers-choice() {
    whiptail --msgbox --title "$title" "After install, choose your GPU drivers.\nCheck spk_pkgs for exact package names." 8 60 || true
    gpu_choice=$(whiptail --title "$title" --menu "Select GPU driver" 14 50 6 \
        "nvidia" "NVIDIA (spk: nvidia-drivers)" \
        "nvidia-legacy" "NVIDIA Legacy (spk: nvidia-legacy-drivers)" \
        "amd" "AMD (spk: mesa, xf86-video-amdgpu)" \
        "intel" "Intel (spk: mesa, xf86-video-intel)" \
        "none" "Skip" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$gpu_choice" ] && return
    case "$gpu_choice" in
        nvidia)
            chroot "$root" /bin/bash -c "spk get nvidia-drivers" 2>/dev/null || true
            ;;
        nvidia-legacy)
            chroot "$root" /bin/bash -c "spk get nvidia-legacy-drivers" 2>/dev/null || true
            ;;
        amd)
            chroot "$root" /bin/bash -c "spk get mesa xf86-video-amdgpu" 2>/dev/null || true
            ;;
        intel)
            chroot "$root" /bin/bash -c "spk get mesa xf86-video-intel" 2>/dev/null || true
            ;;
        none)
            return
            ;;
    esac
    whiptail --msgbox --title "$title" "GPU drivers installed Reboot to use them" 8 40 || true
}

install-desktop() {
    [ -n "${want_de:-}" ] || return 0
    [ "${de_choice:-none}" = "none" ] && return 0

    case "${de_choice}" in
        kde)
            chroot "$root" /bin/bash -c "spk get plasma-desktop konsole dolphin kate kwrite" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install KDE Plasma via spk" 8 76 || true
            ;;
        gnome)
            chroot "$root" /bin/bash -c "spk get gnome gnome-terminal nautilus" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install GNOME via spk" 8 70 || true
            ;;
        xfce)
            chroot "$root" /bin/bash -c "spk get xfce4 xfce4-terminal thunar" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install XFCE via spk" 8 70 || true
            ;;
        i3)
            chroot "$root" /bin/bash -c "spk get i3 i3status dmenu rxvt-unicode" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install i3 via spk" 8 70 || true
            ;;
        sway)
            chroot "$root" /bin/bash -c "spk get sway waybar wofi foot" 2>/dev/null || \
                whiptail --msgbox --title "$title" "Failed to install Sway via spk" 8 70 || true
            ;;
    esac

    case "${dm_choice:-}" in
        sddm)
            if chroot "$root" /bin/bash -c "spk get sddm" 2>/dev/null; then
                chroot "$root" /bin/bash -c "rc-update add sddm default" 2>/dev/null || true
            else
                whiptail --msgbox --title "$title" "Failed to install SDDM via spk" 8 70 || true
            fi
            if [ -n "${newuser:-}" ]; then
                mkdir -p "$root"/etc/sddm.conf.d
                _sddm_session="plasma"
                case "${de_choice:-none}" in
                    i3) _sddm_session="i3" ;;
                    sway) _sddm_session="sway" ;;
                    xfce) _sddm_session="xfce" ;;
                    gnome) _sddm_session="gnome" ;;
                esac
                cat > "$root"/etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$newuser
Session=$_sddm_session
EOF
            fi
            ;;
        gdm)
            if chroot "$root" /bin/bash -c "spk get gdm" 2>/dev/null; then
                chroot "$root" /bin/bash -c "rc-update add gdm default" 2>/dev/null || true
            else
                whiptail --msgbox --title "$title" "Failed to install GDM via spk" 8 70 || true
            fi
            ;;
        lightdm)
            if chroot "$root" /bin/bash -c "spk get lightdm lightdm-gtk-greeter" 2>/dev/null; then
                chroot "$root" /bin/bash -c "rc-update add lightdm default" 2>/dev/null || true
            else
                whiptail --msgbox --title "$title" "Failed to install LightDM via spk" 8 70 || true
            fi
            ;;
    esac

    if chroot "$root" /bin/bash -c "command -v elogind >/dev/null 2>&1 || test -f /etc/init.d/elogind" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "rc-update add elogind boot" >/dev/null 2>&1 || \
        chroot "$root" /bin/bash -c "rc-update add elogind default" >/dev/null 2>&1 || true
    fi
}

install-branding() {

    logo_src=""
    for f in /mnt/branding/fastfetch_logo.txt /mnt/fastfetch_logo.txt; do
        [ -f "$f" ] && logo_src="$f" && break
    done || true
    [ -n "$logo_src" ] || return 0

    mkdir -p "$root"/usr/share/silen
    cp "$logo_src" "$root"/usr/share/silen/fastfetch_logo.txt 2>/dev/null || return 0
    if [ -f /mnt/branding/info.txt ]; then
        cp /mnt/branding/info.txt "$root"/usr/share/silen/info.txt 2>/dev/null || true
    fi

    mkdir -p "$root"/etc/fastfetch "$root"/etc/xdg/fastfetch "$root"/etc/skel/.config/fastfetch "$root"/root/.config/fastfetch
    cat > "$root"/etc/fastfetch/config.jsonc <<'EOF'
{
    "logo": {
        "type": "file",
        "source": "/usr/share/silen/fastfetch_logo.txt",
        "padding": {
            "top": 0,
            "left": 1,
            "right": 3
        }
    },
    "modules": [
        "title",
        "separator",
        "os",
        "host",
        "kernel",
        "uptime",
        "shell",
        "cpu",
        "memory",
        "disk",
        "break",
        "colors"
    ]
}
EOF
    cp "$root"/etc/fastfetch/config.jsonc "$root"/etc/xdg/fastfetch/config.jsonc 2>/dev/null || true
    cp "$root"/etc/fastfetch/config.jsonc "$root"/etc/skel/.config/fastfetch/config.jsonc 2>/dev/null || true
    cp "$root"/etc/fastfetch/config.jsonc "$root"/root/.config/fastfetch/config.jsonc 2>/dev/null || true

    if [ -n "${newuser:-}" ] && [ -d "$root/home/$newuser" ]; then
        mkdir -p "$root"/home/$newuser/.config/fastfetch 2>/dev/null || true
        cp "$root"/etc/fastfetch/config.jsonc "$root"/home/$newuser/.config/fastfetch/config.jsonc 2>/dev/null || true
        chroot "$root" /bin/bash -c "chown -R $newuser /home/$newuser/.config" >/dev/null 2>&1 || \
        chown -R --reference="$root/home/$newuser" "$root/home/$newuser/.config" 2>/dev/null || true
    fi
}

setup-quiet-boot() {
    if [ -f "$root"/etc/inittab ]; then
        sed -i 's#/sbin/openrc \(sysinit\|boot\|shutdown\|single\|nonetwork\|default\|reboot\)#/sbin/openrc --quiet \1#g' \
            "$root"/etc/inittab 2>/dev/null || true
        sed -i 's|/sbin/agetty --noclear|/sbin/agetty|g' "$root"/etc/inittab 2>/dev/null || true
    fi
    if [ -f "$root"/etc/rc.conf ]; then
        if grep -q '^[[:space:]]*rc_logger=' "$root"/etc/rc.conf 2>/dev/null; then
            sed -i 's|^[[:space:]]*rc_logger=.*|rc_logger="YES"|' "$root"/etc/rc.conf 2>/dev/null || true
        elif grep -q 'rc_logger=' "$root"/etc/rc.conf 2>/dev/null; then
            sed -i 's|.*rc_logger=.*|rc_logger="YES"|' "$root"/etc/rc.conf 2>/dev/null || true
        else
            printf '\n# log boot messages to /var/log/rc.log while the console stays quiet\nrc_logger="YES"\n' >> "$root"/etc/rc.conf 2>/dev/null || true
        fi
    fi
}

setup-grub() {
    if [ -f /mnt/boot/vmlinuz ]; then
        if ! cp /mnt/boot/vmlinuz "$root"/boot/vmlinuz 2>/dev/null; then
            whiptail --msgbox --title "$title" "couldn't copy the kernel" 8 40 || true
            return
        fi
    else
        whiptail --msgbox --title "$title" "no kernel found on the install medium" 8 40 || true
        return
    fi
    initramfs_name=""
    for i in /mnt/boot/initramfs.*; do
        [ -f "$i" ] && initramfs_name="$(basename "$i")" && cp "$i" "$root"/boot/ && break
    done || true
    if [ -z "$initramfs_name" ]; then
        whiptail --msgbox --title "$title" "no initramfs found in the install ISO" 8 40 || true
        return
    fi

    if [ ! -d /sys/firmware/efi ]; then
        whiptail --msgbox --title "$title" "this machine booted in legacy mode, but Silen can currently only install an EFI bootloader. Boot the iso in UEFI mode and try again." 10 60 || true
        return
    fi

    if [ -d /mnt/grub/usr/local ]; then
        mkdir -p "$root"/usr/local
        cp -a /mnt/grub/usr/local/. "$root"/usr/local/ 2>/dev/null || { whiptail --msgbox --title "$title" "couldn't copy bundled GRUB" 8 40 || true; }
    fi

    mkdir -p "$root/tmp" 2>/dev/null || true
    if chroot "$root" /bin/bash -c "PATH=/usr/local/sbin:/usr/local/bin:\$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" >"$root/tmp/grub-install.log" 2>&1 || chroot "$root" /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" >>"$root/tmp/grub-install.log" 2>&1; then
        cp "$root/tmp/grub-install.log" /tmp/grub-install.log 2>/dev/null || true
        if [ ! -f "$root"/boot/grub/fonts/unicode.pf2 ]; then
            for _pf2 in /mnt/grub/usr/local/share/grub/unicode.pf2 \
                         /usr/local/share/grub/unicode.pf2 \
                         /usr/share/grub/unicode.pf2; do
                if [ -f "$_pf2" ]; then
                    mkdir -p "$root"/boot/grub/fonts 2>/dev/null || true
                    cp "$_pf2" "$root"/boot/grub/fonts/unicode.pf2 2>/dev/null || true
                    break
                fi
            done || true
        fi
        cat > "$root"/boot/grub/grub.cfg <<EOF
set default=0
set timeout=5

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
terminal_output gfxterm
set gfxpayload=keep
search --no-floppy --fs-uuid --set=root $bootuuid

menuentry "Silen Linux" {
    linux /vmlinuz root=UUID=$rootuuid ro quiet loglevel=0
    initrd /$initramfs_name
}
EOF
        whiptail --msgbox --title "$title" "GRUB is installed" 8 40 || true
    else
        whiptail --msgbox --title "$title" "grub-install failed, see /tmp/grub-install.log for errors" 8 40 || true
    fi
}

main_screen
