#!/bin/sh
set -e

title="Silen installer"
root="/silen"

cleanup() {
    umount $root/proc 2>/dev/null
    umount $root/sys 2>/dev/null
    umount $root/dev 2>/dev/null
    umount $root/run 2>/dev/null
    umount $root/boot 2>/dev/null
    umount $root 2>/dev/null
}

trap cleanup EXIT

[ "$(id -u)" = "0" ] || {
    whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
    exit 1
}

whiptail --msgbox --title "$title" "Silen linux installer (this script is still in early development errors may occur)" 10 40

if whiptail --yesno --title "$title" "Would you like to connect to the internet? (not needed if you have a ethernet connection" 8 50; then
    nmtui
fi

main_screen() {
    men1=$(whiptail --title "$title" --menu "Choose an option:" 10 49 3 \
        "1" "Install Silen" \
        "2" "Shell" \
        "3" "Reboot" \
        3>&1 1>&2 2>&3 || true)

    if [ "$men1" = "1" ]; then
        partitioning
    elif [ "$men1" = "2" ]; then
        sh
        main_screen
    elif [ "$men1" = "3" ]; then
        reboot
    else
        main_screen
    fi
}



partitioning() {
    disks=""
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme0n[0-9] /dev/mmcblk[0-9]; do
        if [ -b "$d" ]; then
            disks="$disks $d $d"
        fi
    done
    if [ -z "$disks" ]; then
        whiptail --msgbox --title "$title" "no disks found" 8 40
        main_screen
        return
    fi
    disk=$(whiptail --title "$title" --menu "Select the disk to install on:" 14 50 6 $disks 3>&1 1>&2 2>&3 || true)
    if [ -z "$disk" ]; then
        main_screen
        return
    fi
    if ! whiptail --title "$title" --yesno "This will wipe $disk are you sure?" 8 40; then
        partitioning
        return
    fi
    for cmd in sfdisk mkfs.vfat mkfs.ext4 blkid; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            whiptail --msgbox --title "$title" "$cmd not found on the install medium" 8 40
            return
        fi
    done
    if ! sfdisk "$disk" <<EOF
label: gpt
, 512M, U
, , L
EOF
    then
        whiptail --msgbox --title "$title" "couldn't write partition table to $disk" 8 40
        return
    fi
    if [ -b "${disk}p1" ]; then
        bootp="${disk}p1"
        rootp="${disk}p2"
    else
        bootp="${disk}1"
        rootp="${disk}2"
    fi
    if [ ! -b "$bootp" ] || [ ! -b "$rootp" ]; then
        whiptail --msgbox --title "$title" "partitioning failed, no partitions on $disk" 8 40
        partitioning
        return
    fi
    if ! mkfs.vfat "$bootp" || ! mkfs.ext4 "$rootp"; then
        whiptail --msgbox --title "$title" "couldn't format the partitions" 8 40
        return
    fi
    install-base
}

install-base() {
    mkdir -p $root
    if ! mount "$rootp" $root; then
        whiptail --msgbox --title "$title" "failed to mount $rootp" 8 40
        return
    fi
    mkdir -p $root/boot
    if ! mount "$bootp" $root/boot; then
        cleanup
        whiptail --msgbox --title "$title" "failed to mount $bootp" 8 40
        return
    fi

    stage3=""
    for s in /mnt/stage3-*.tar.*; do
        [ -f "$s" ] && stage3="$s" && break
    done || true
    if [ -z "$stage3" ]; then
        whiptail --msgbox --title "$title" "no Silen tarball found on the install medium" 8 40
        cleanup
        return
    fi
    tar -xpf "$stage3" -C $root --numeric-owner --xattrs-include='*.*'

    mkdir -p $root/proc $root/sys $root/dev $root/run $root/etc $root/usr/share/zoneinfo
    mount -t proc proc $root/proc
    mount -t sysfs sysfs $root/sys
    mount --rbind /dev $root/dev
    mount --rbind /run $root/run

    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf $root/etc/resolv.conf
    else
        echo "nameserver 1.1.1.1" > $root/etc/resolv.conf
    fi
    hostnm=$(hostname 2>/dev/null || true)
    [ -z "$hostnm" ] && hostnm="silen"
    hostnm=$(whiptail --title "$title" --inputbox "Set the hostname:" 8 40 "$hostnm" 3>&1 1>&2 2>&3 || true)
    [ -z "$hostnm" ] && hostnm="silen"
    echo "$hostnm" > $root/etc/hostname

    while :; do
        pass=$(whiptail --title "$title" --passwordbox "Set the root password:" 8 40 3>&1 1>&2 2>&3 || true)
        if [ -n "$pass" ] && echo "root:$pass" | chroot $root /bin/busybox chpasswd; then
            break
        fi
        whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40
    done

    bootuuid=$(blkid -s UUID -o value "$bootp" || true)
    rootuuid=$(blkid -s UUID -o value "$rootp" || true)
    if [ -z "$bootuuid" ] || [ -z "$rootuuid" ]; then
        whiptail --msgbox --title "$title" "couldn't read the partition UUIDs" 8 40
        cleanup
        return
    fi
    cat > $root/etc/fstab <<EOF
UUID=$rootuuid / ext4 defaults 0 1
UUID=$bootuuid /boot vfat defaults 0 2
EOF

    system-settings
    chroot $root /bin/bash -c "ldconfig"

    install-modules
    install-spk
    setup-grub

    cleanup
    sync
    whiptail --msgbox --title "$title" "Silen is installed, reboot when ready" 8 40
    main_screen
}

system-settings() {
    while :; do
        zone=$(whiptail --title "$title" --menu "Select timezone:" 14 50 6 \
            "UTC" "UTC" \
            "Europe/Berlin" "Central European Time" \
            "Europe/London" "British Time" \
            "America/New_York" "US Eastern" \
            "Asia/Tokyo" "Japan" \
            3>&1 1>&2 2>&3 || true)
        [ -z "$zone" ] && zone="UTC"
        if [ -e "$root/usr/share/zoneinfo/$zone" ]; then
            break
        fi
        whiptail --msgbox --title "$title" "timezone data for $zone not found" 8 40
    done
    ln -sf /usr/share/zoneinfo/$zone $root/etc/localtime

    keymap=$(whiptail --title "$title" --menu "Select keyboard layout:" 14 50 6 \
        "us" "US English" \
        "de" "German" \
        "gb" "British" \
        "fr" "French" \
        "es" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$keymap" ] && keymap="us"
    mkdir -p $root/etc/conf.d
    echo "keymap=\"$keymap\"" > $root/etc/conf.d/keymaps

    locale=$(whiptail --title "$title" --menu "Select locale:" 14 50 6 \
        "en_US.UTF-8" "US English" \
        "de_DE.UTF-8" "German" \
        "en_GB.UTF-8" "British" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$locale" ] && locale="en_US.UTF-8"
    echo "$locale UTF-8" > $root/etc/locale.gen
    if ! chroot $root /bin/bash -c "locale-gen" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't generate locales, check locale.gen later" 8 40
    fi
    mkdir -p $root/etc/env.d
    echo "LANG=\"$locale\"" > $root/etc/env.d/02locale

    if whiptail --title "$title" --yesno "Create a 1G swapfile?" 8 40; then
        chroot $root /bin/bash -c "fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile" 2>/dev/null || \
            whiptail --msgbox --title "$title" "couldn't create the swapfile" 8 40
    fi
}

install-modules() {
    mkdir -p $root/lib/modules
    if [ -d /mnt/modules ] && [ -n "$(ls /mnt/modules 2>/dev/null)" ]; then
        cp -a /mnt/modules/. $root/lib/modules/ 2>/dev/null || true
    elif [ -d /lib/modules ]; then
        cp -a /lib/modules/. $root/lib/modules/ 2>/dev/null || true
    fi
    kver=$(ls $root/lib/modules 2>/dev/null | head -n1)
    if [ -n "$kver" ] && chroot $root /bin/bash -c "command -v depmod" >/dev/null 2>&1; then
        chroot $root /bin/bash -c "depmod -a $kver" 2>/dev/null || true
    fi
}

install-spk() {
    spk_src=""
    for f in /mnt/spk.tar.*; do
        [ -f "$f" ] && spk_src="$f" && break
    done || true
    if [ -n "$spk_src" ]; then
        tar -xpf "$spk_src" -C $root/usr/bin
        return
    fi
    if [ -f /usr/bin/spk ]; then
        cp /usr/bin/spk $root/usr/bin/spk
        return
    fi
    if [ -d /mnt/spk ]; then
        cp -r /mnt/spk $root/usr/bin/spk
        return
    fi
    url=$(whiptail --title "$title" --inputbox "spk not found, enter a git url to clone it (leave empty to skip):" 8 46 3>&1 1>&2 2>&3 || true)
    if [ -n "$url" ]; then
        if ! git clone "$url" /tmp/spk 2>/dev/null; then
            whiptail --msgbox --title "$title" "couldn't clone spk" 8 40
            return
        fi
        cp -r /tmp/spk $root/usr/src/spk 2>/dev/null || true
        if ! chroot $root /bin/bash -c "cd /usr/src/spk && make install" 2>/dev/null; then
            whiptail --msgbox --title "$title" "couldn't build spk, keeping the source in /usr/src/spk" 8 40
        fi
    fi
}

setup-grub() {
    if [ -f /mnt/boot/vmlinuz ]; then
        cp /mnt/boot/vmlinuz $root/boot/vmlinuz
    else
        whiptail --msgbox --title "$title" "no kernel found on the install medium" 8 40
        return
    fi
    initramfs_name=""
    for i in /mnt/boot/initramfs.*; do
        [ -f "$i" ] && initramfs_name="$(basename "$i")" && cp "$i" $root/boot/ && break
    done || true
    if [ -z "$initramfs_name" ]; then
        whiptail --msgbox --title "$title" "no initramfs found on the install medium" 8 40
        return
    fi

    if [ -d /mnt/grub/usr/local ]; then
        mkdir -p $root/usr/local
        cp -a /mnt/grub/usr/local/. $root/usr/local/
    fi

    if chroot $root /bin/bash -c "PATH=/usr/local/sbin:/usr/local/bin:\$PATH /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" 2>/dev/null; then
        cat > $root/boot/grub/grub.cfg <<EOF
set default=0
set timeout=5

menuentry "Silen Linux" {
    echo "Booting Silen"
    linux /vmlinuz root=UUID=$rootuuid ro quiet loglevel=3
    initrd /$initramfs_name
}
EOF
        whiptail --msgbox --title "$title" "GRUB is installed, the system will boot into Silen after reboot" 8 40
    else
        whiptail --msgbox --title "$title" "grub-install failed, check the console for errors" 8 40
    fi
}

main_screen