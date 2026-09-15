#!/bin/sh
set -e

title="Silen installer"
root="/silen"

whiptail --msgbox --title "$title" "Silen linux installer (this script is still in early development errors may accur)" 10 40

if whiptail --yesno --title "$title" "Would you like to connect to the internet?" 8 40; then
    nmtui
fi

main_screen() {
    men1=$(whiptail --title "$title" --menu "Choose an option:" 10 49 3 \
        "1" "Install Silen" \
        "2" "Shell" \
        "3" "Reboot" \
        3>&1 1>&2 2>&3)

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

last-screen() {
    if whiptail --title "$title" --yesno "Would u like to reboot?" 8 40; then
        reboot
fi
}

partitioning() {
    disks=""
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme0n[0-9]; do
        if [ -b "$d" ]; then
            disks="$disks $d $d"
        fi
    done
    if [ -z "$disks" ]; then
        whiptail --msgbox --title "$title" "no disks found" 8 40
        main_screen
        return
    fi
    disk=$(whiptail --title "$title" --menu "Select the disk to install on:" 14 50 6 $disks 3>&1 1>&2 2>&3)
    if [ -z "$disk" ]; then
        main_screen
        return
    fi
    if whiptail --title "$title" --yesno "This will wipe $disk are you sure?" 8 40; then
        fdisk "$disk" <<EOF
o
n
p
1

+512M
t
1
ef
a
1
n
p
2


w
EOF
        if [ -b "${disk}p1" ]; then
            bootp="${disk}p1"
            rootp="${disk}p2"
        else
            bootp="${disk}1"
            rootp="${disk}2"
        fi
        mkfs.vfat "$bootp"
        mkfs.ext4 "$rootp"
        install-base
    else
        partitioning
    fi
}

install-base() {
    mkdir -p $root
    mount "$rootp" $root
    mkdir -p $root/boot
    mount "$bootp" $root/boot

    for s in /mnt/stage3-*.tar.*; do
        [ -f "$s" ] && stage3="$s" && break
    done
    if [ -z "$stage3" ]; then
        whiptail --msgbox --title "$title" "no stage3 tarball found on the install medium" 8 40
        return
    fi
    tar -xpf "$stage3" -C $root --numeric-owner --xattrs-include='*.*'

    mount -t proc proc $root/proc
    mount -t sysfs sysfs $root/sys
    mount --rbind /dev $root/dev
    mount --rbind /run $root/run

    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf $root/etc/resolv.conf
    else
        echo "nameserver 1.1.1.1" > $root/etc/resolv.conf
    fi
    hostnm=$(hostname 2>/dev/null)
    [ -z "$hostnm" ] && hostnm="silen"
    hostnm=$(whiptail --title "$title" --inputbox "Set the hostname:" 8 40 "$hostnm" 3>&1 1>&2 2>&3)
    [ -z "$hostnm" ] && hostnm="silen"
    echo "$hostnm" > $root/etc/hostname

    pass=$(whiptail --title "$title" --passwordbox "Set the root password:" 8 40 3>&1 1>&2 2>&3)
    echo "root:$pass" | chroot $root /usr/sbin/chpasswd

    bootuuid=$(blkid -s UUID -o value "$bootp")
    rootuuid=$(blkid -s UUID -o value "$rootp")
    cat > $root/etc/fstab <<EOF
UUID=$rootuuid / ext4 defaults 0 1
UUID=$bootuuid /boot vfat defaults 0 2
EOF

    system-settings
    chroot $root /bin/bash -c "ldconfig"

    install-modules
    install-spk
    setup-grub

    whiptail --msgbox --title "$title" "Silen is installed, reboot when ready" 8 40
    main_screen
}

system-settings() {
    zone=$(whiptail --title "$title" --menu "Select timezone:" 14 50 6 \
        "UTC" "UTC" \
        "Europe/Berlin" "Central European Time" \
        "Europe/London" "British Time" \
        "America/New_York" "US Eastern" \
        "Asia/Tokyo" "Japan" \
        3>&1 1>&2 2>&3)
    [ -z "$zone" ] && zone="UTC"
    ln -sf /usr/share/zoneinfo/$zone $root/etc/localtime

    keymap=$(whiptail --title "$title" --menu "Select keyboard layout:" 14 50 6 \
        "us" "US English" \
        "de" "German" \
        "gb" "British" \
        "fr" "French" \
        "es" "Spanish" \
        3>&1 1>&2 2>&3)
    [ -z "$keymap" ] && keymap="us"
    mkdir -p $root/etc/conf.d
    echo "keymap=\"$keymap\"" > $root/etc/conf.d/keymaps

    locale=$(whiptail --title "$title" --menu "Select locale:" 14 50 6 \
        "en_US.UTF-8" "US English" \
        "de_DE.UTF-8" "German" \
        "en_GB.UTF-8" "British" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        3>&1 1>&2 2>&3)
    [ -z "$locale" ] && locale="en_US.UTF-8"
    echo "$locale UTF-8" > $root/etc/locale.gen
    chroot $root /bin/bash -c "locale-gen"
    mkdir -p $root/etc/env.d
    echo "LANG=\"$locale\"" > $root/etc/env.d/02locale

    if whiptail --title "$title" --yesno "Create a 1G swapfile?" 8 40; then
        chroot $root /bin/bash -c "fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile"
        echo "/swapfile none swap sw 0 0" >> $root/etc/fstab
    fi
}

install-modules() {
    mkdir -p $root/lib/modules
    if [ -d /mnt/modules ] && [ -n "$(ls /mnt/modules 2>/dev/null)" ]; then
        cp -a /mnt/modules/. $root/lib/modules/
    elif [ -d /lib/modules ]; then
        cp -a /lib/modules/. $root/lib/modules/
    fi
    kver=$(ls $root/lib/modules 2>/dev/null | head -n1)
    if [ -n "$kver" ] && chroot $root /bin/bash -c "command -v depmod" > /dev/null 2>&1; then
        chroot $root /bin/bash -c "depmod -a $kver"
    fi
}

install-spk() {
    if [ -f /mnt/spk.tar.* ]; then
        for f in /mnt/spk.tar.*; do
            tar -xpf "$f" -C $root/usr/bin
            break
        done
    elif [ -f /usr/bin/spk ]; then
        cp /usr/bin/spk $root/usr/bin/spk
    elif [ -d /mnt/spk ]; then
        cp -r /mnt/spk $root/usr/bin/spk
    else
        url=$(whiptail --title "$title" --inputbox "spk not found, enter a git url to clone it:" 8 46 3>&1 1>&2 2>&3)
        if [ -n "$url" ]; then
            chroot $root /bin/bash -c "git clone $url /usr/src/spk && cd /usr/src/spk && make install"
        fi
    fi
}

setup-grub() {
    cp /mnt/boot/vmlinuz $root/boot/vmlinuz
    for i in /mnt/boot/initramfs.*; do
        [ -f "$i" ] && cp "$i" $root/boot/ && break
    done
    if chroot $root /bin/bash -c "command -v grub-install" > /dev/null 2>&1; then
        chroot $root /bin/bash -c "grub-install $disk && grub-mkconfig -o /boot/grub/grub.cfg"
    else
        whiptail --msgbox --title "$title" "grub isnt installed yet, install it with spk later" 8 40
    fi
}

main_screen
