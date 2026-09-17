#!/bin/sh
set -e

title="Silen installer"
root="/silen"

cleanup() {
    # rbind'd /dev and /run carry submounts (/dev/pts, /dev/shm, ...), so a
    # plain umount fails with EBUSY; try recursive first, then lazy
    for m in "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/boot" "$root"; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount -R "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || umount "$m" 2>/dev/null || true
        fi
    done
}

# the stage3/tarball the installer untars into the target disk; /mnt is where
# the live init mounts the install medium
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

# mount a partition/CD at the given mountpoint (ro fallbacks cover Ventoy
# virtual CDs and Ventoy exFAT/NTFS data partitions)
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

# true if the install medium (direct /mnt mount, or the Ventoy partition
# backing a loop-mounted ISO at /mnt) lives on $1. A loop mount shows up as
# /dev/loopN, so compare its backing file's filesystem instead of the name.
medium_on_disk() {
    _disk="$1"
    # most reliable: the boot-time scan recorded the backing device
    if [ -f /run/silen-medium-dev ]; then
        _rec="$(cat /run/silen-medium-dev 2>/dev/null)"
        if [ -n "$_rec" ]; then
            case "$_rec" in
                "$_disk"*) return 0 ;;
            esac
            # recorded device could be a partition (nvme0n1p2) while _disk is the
            # whole disk (nvme0n1) or vice versa - compare either direction
            case "$_disk" in
                "$_rec"*) return 0 ;;
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

# One-shot rescan for the install medium. Mirrors rootfs/init: mount every
# partition briefly at /run/scan, accept it if it carries the tarball
# directly, else loop-mount any *.iso on it (Ventoy keeps silen-linux.iso
# as a file on exFAT/NTFS) and accept that. Leaves ISO contents at /mnt
# with the Ventoy partition kept at /run/ventoy. Returns 0 on success.
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
        case "$_cands" in
            *"$_dm"*) ;;
            *) _cands="$_cands $_dm" ;;
        esac
    done || true
    # also try plain sd/vd/nvme/mmc names even if /sys was thin
    for _d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9] /dev/sr[0-9]*; do
        [ -b "$_d" ] || continue
        case "$_cands" in
            *"$_d"*) ;;
            *) _cands="$_cands $_d" ;;
        esac
        for _p in "$_d"?* "$_d"p?*; do
            [ -b "$_p" ] || continue
            case "$_cands" in
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

# Make sure /mnt carries the tarball, rescanning (incl. Ventoy ISO files) if
# the boot-time mount missed it. Returns 0 when ready to install.
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

trap cleanup EXIT

[ "$(id -u)" = "0" ] || {
    whiptail --msgbox --title "$title" "this installer needs root" 8 40 2>/dev/null || true
    exit 1
}

whiptail --msgbox --title "$title" "Silen linux installer (this script is still in early development errors may occur)" 10 40

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
    for d in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9] /dev/mmcblk[0-9]; do
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
    # never wipe anything before verifying the install tarball is actually
    # reachable: formatting the disk first and checking afterwards would
    # destroy the SSD on a misconfigured boot (and did). If the boot-time
    # mount missed it (typical with Ventoy, where the ISO is a file on an
    # exFAT partition), try to find and (loop-)mount it now before failing.
    if ! medium_has_tarball; then
        rescan_medium || true
    fi
    if ! medium_has_tarball; then
        _dbg_mnt="$(mount 2>/dev/null | grep ' /mnt ' || echo 'nothing mounted at /mnt')"
        _dbg_blk="$(blkid 2>/dev/null | head -n 20 || echo 'blkid unavailable')"
        whiptail --msgbox --title "$title" "No Silen tarball found at /mnt, so installing would fail AFTER wiping $disk.\n\nThe installer already rescanned all disks (including Ventoy ISO files) and found nothing.\n\nPressed OK for details. Current state:\n$_dbg_mnt\n$_dbg_blk\n\nFixes: reboot (slow USB/NVMe may need a retry), write the ISO with dd instead of Ventoy, or open Shell and mount the install medium at /mnt yourself, then rerun Install." 22 70
        main_screen
        return
    fi
    # refuse to install onto the disk the install medium itself lives on:
    # wiping it destroys the ISO/tarball so the install can't finish.
    # (loop-aware: a Ventoy ISO at /mnt is backed by a file on /run/ventoy)
    if medium_on_disk "$disk"; then
        whiptail --msgbox --title "$title" "$disk holds the install medium (directly or as the Ventoy partition backing the ISO) - installing onto it wipes the ISO/tarball. Pick a different disk." 9 70
        partitioning
        return
    fi
    for cmd in sfdisk mkfs.vfat mkfs.ext4 blkid; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            whiptail --msgbox --title "$title" "$cmd not found on the install medium" 8 40
            return
        fi
    done
    # everything interactive happens now, BEFORE the disk is touched: once
    # wiping starts the rest of the install runs without further questions.
    ask-install-settings
    # the target disk is about to be wiped, so release anything still mounted
    # on it (an in-use disk makes sfdisk fail with "device or resource
    # busy"). Never touch the install medium here: /mnt (possibly a loop
    # from /run/ventoy) must stay mounted when it lives on another disk,
    # and installing onto the medium's own disk was already refused above.
    for part in $(mount 2>/dev/null | awk -v d="$disk" '$1 ~ ("^" d) {print $1}' || true); do
        [ -n "$part" ] || continue
        umount "$part" 2>/dev/null || true
    done
    # only release /mnt if it happens to be on the target disk; when the live
    # medium is a *different* disk we still need it for the stage3 tarball
    if medium_on_disk "$disk"; then
        umount /mnt 2>/dev/null || true
    fi
    # full wipe of old signatures so nothing from a previous install survives
    if command -v wipefs >/dev/null 2>&1; then
        wipefs -a "$disk" 2>/dev/null || true
    fi
    if ! sfdisk "$disk" <<EOF
label: gpt
, 512M, U
, , L
EOF
    then
        if mount 2>/dev/null | awk -v d="$disk" '$1 ~ d {f=1} END {exit !f}'; then
            whiptail --msgbox --title "$title" "couldn't write partition table to $disk: it is still in use (something is mounted on it). Open the shell and check 'mount'." 10 60
        else
            whiptail --msgbox --title "$title" "couldn't write partition table to $disk" 8 40
        fi
        return
    fi
    # make the kernel pick up the new partitions (devtmpfs creates the nodes)
    blockdev --rereadpt "$disk" 2>/dev/null || partx -u "$disk" 2>/dev/null || sleep 2
    sleep 1
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
    for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz; do
        [ -f "$s" ] && stage3="$s" && break
    done || true
    if [ -z "$stage3" ]; then
        whiptail --msgbox --title "$title" "no Silen tarball found on the install medium" 8 40
        cleanup
        return
    fi
    if [ "$(tar -tf "$stage3" | awk -F/ 'NF>1 {print $1}' | sort -u | wc -l)" = "1" ]; then
        tar -xpf "$stage3" -C $root --strip-components=1 --no-same-owner --numeric-owner --xattrs-include='*.*'
    else
        tar -xpf "$stage3" -C $root --no-same-owner --numeric-owner --xattrs-include='*.*'
    fi

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
    # answers collected up front by ask-install-settings; applying them here
    # keeps every in-target command at the end of the install.
    echo "$hostnm" > $root/etc/hostname
    if [ -f $root/etc/conf.d/hostname ]; then
        if grep -q '^hostname=' $root/etc/conf.d/hostname 2>/dev/null; then
            sed -i "s/^hostname=.*/hostname=\"$hostnm\"/" $root/etc/conf.d/hostname 2>/dev/null || true
        else
            printf 'hostname="%s"\n' "$hostnm" >> $root/etc/conf.d/hostname
        fi
    fi

    chpasswd_bin=""
    for c in /usr/bin/chpasswd /usr/sbin/chpasswd /bin/chpasswd /sbin/chpasswd; do
        [ -x "$root$c" ] && chpasswd_bin="$c" && break
    done
    [ -z "$chpasswd_bin" ] && chpasswd_bin="/usr/bin/chpasswd"
    if ! printf 'root:%s\n' "$rootpass" | chroot $root "$chpasswd_bin" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't set the root password - log in after reboot and run passwd" 8 60
    fi
    rootpass=""

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

    apply-settings
    if [ -n "$made_swapfile" ]; then
        echo "/swapfile none swap sw 0 0" >> $root/etc/fstab
    fi
    if ! chroot $root /bin/bash -c "ldconfig" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't run ldconfig in the new system; shared libraries may not load until it is run" 8 60
    fi

    install-modules
    install-spk
    install-network
    create-user
    setup-grub

    cleanup
    sync
    whiptail --msgbox --title "$title" "Silen is installed, reboot when ready" 8 40
    main_screen
}

# Everything interactive happens here, BEFORE the disk is wiped. Once this
# returns, partitioning/formatting runs and the rest of the install applies
# these answers without further questions.
ask-install-settings() {
    hostnm=$(hostname 2>/dev/null || true)
    case "$hostnm" in
        ""|archlinux|"(none)"|localhost) hostnm="silen" ;;
    esac
    hostnm=$(whiptail --title "$title" --inputbox "Set the hostname:" 8 40 "$hostnm" 3>&1 1>&2 2>&3 || true)
    [ -z "$hostnm" ] && hostnm="silen"

    rootpass=""
    while :; do
        rootpass=$(whiptail --title "$title" --passwordbox "Set the root password:" 8 40 3>&1 1>&2 2>&3 || true)
        [ -n "$rootpass" ] && break
        whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40
    done

    newuser=""
    userpass=""
    if whiptail --title "$title" --yesno "Create a user account (in addition to root)?" 8 50; then
        while :; do
            newuser=$(whiptail --title "$title" --inputbox "Username for the new account (empty = skip):" 8 50 3>&1 1>&2 2>&3 || true)
            [ -z "$newuser" ] && break
            if [ "$newuser" = "root" ]; then
                whiptail --msgbox --title "$title" "root already exists, pick another name" 8 40
                newuser=""
                continue
            fi
            case "$newuser" in
                [a-z_]*)
                    case "$newuser" in
                        *[!a-z0-9_-]*)
                            whiptail --msgbox --title "$title" "only lowercase letters, digits, _ and - allowed" 8 50
                            newuser=""
                            continue
                            ;;
                    esac
                    if [ "${#newuser}" -gt 32 ]; then
                        whiptail --msgbox --title "$title" "username too long (max 32)" 8 40
                        newuser=""
                        continue
                    fi
                    ;;
                *)
                    whiptail --msgbox --title "$title" "must start with a lowercase letter or _" 8 50
                    newuser=""
                    continue
                    ;;
            esac
            break
        done || true
        while [ -n "$newuser" ]; do
            userpass=$(whiptail --title "$title" --passwordbox "Password for $newuser:" 8 40 3>&1 1>&2 2>&3 || true)
            [ -n "$userpass" ] && break
            whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40
        done || true
    fi

    zone=$(whiptail --title "$title" --menu "Select timezone:" 14 50 6 \
        "UTC" "UTC" \
        "Europe/Berlin" "Central European Time" \
        "Europe/London" "British Time" \
        "America/New_York" "US Eastern" \
        "Asia/Tokyo" "Japan" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$zone" ] && zone="UTC"

    keymap=$(whiptail --title "$title" --menu "Select keyboard layout:" 14 50 6 \
        "us" "US English" \
        "de" "German" \
        "gb" "British" \
        "fr" "French" \
        "es" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$keymap" ] && keymap="us"

    locale=$(whiptail --title "$title" --menu "Select locale:" 14 50 6 \
        "en_US.UTF-8" "US English" \
        "de_DE.UTF-8" "German" \
        "en_GB.UTF-8" "British" \
        "fr_FR.UTF-8" "French" \
        "es_ES.UTF-8" "Spanish" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$locale" ] && locale="en_US.UTF-8"

    want_swap=""
    if whiptail --title "$title" --yesno "Create a 1G swapfile?" 8 40; then
        want_swap="1"
    fi
}

# Non-interactive counterpart: applies the answers from ask-install-settings
# inside the freshly extracted target.
apply-settings() {
    ln -sf /usr/share/zoneinfo/$zone $root/etc/localtime

    mkdir -p $root/etc/conf.d
    echo "keymap=\"$keymap\"" > $root/etc/conf.d/keymaps

    echo "$locale UTF-8" > $root/etc/locale.gen
    if ! chroot $root /bin/bash -c "locale-gen" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't generate locales, check locale.gen later" 8 40
    fi
    mkdir -p $root/etc/env.d
    echo "LANG=\"$locale\"" > $root/etc/env.d/02locale

    made_swapfile=""
    if [ -n "${want_swap:-}" ]; then
        if chroot $root /bin/bash -c "fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile" 2>/dev/null; then
            made_swapfile="1"
        else
            whiptail --msgbox --title "$title" "couldn't create the swapfile" 8 40
        fi
    fi
}

# Creates the user account asked about up front, plus its per-user spk tree
# (~/.local/bin, ~/.local/share/spk, ~/.cache/spk) so `spk --user` works.
create-user() {
    [ -n "${newuser:-}" ] || return 0
    if ! chroot $root /bin/bash -c "command -v useradd" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser (no useradd in the new system)" 8 60
        return 0
    fi
    usergroups=""
    for g in wheel sudo audio video network plugdev; do
        if chroot $root /bin/bash -c "getent group $g" >/dev/null 2>&1; then
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
    if ! chroot $root /bin/bash -c "useradd $_uflags $newuser" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser - add it by hand after reboot with useradd" 8 60
        return 0
    fi
    if ! printf '%s:%s\n' "$newuser" "$userpass" | chroot $root /bin/bash -c "chpasswd" 2>/dev/null; then
        whiptail --msgbox --title "$title" "user $newuser created but the password couldn't be set - run passwd $newuser after reboot" 8 60
    fi
    userpass=""
    if mkdir -p $root/home/$newuser/.local/bin \
             $root/home/$newuser/.local/share/spk/apps \
             $root/home/$newuser/.local/share/spk/packages \
             $root/home/$newuser/.cache/spk 2>/dev/null; then
        chroot $root /bin/bash -c "chown -R $newuser:$newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || \
        chroot $root /bin/bash -c "chown -R $newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || true
    fi
}

install-modules() {
	mkdir -p $root/lib/modules
	kernel_tar=""
	for f in /mnt/kernel-*.tar.*; do
		[ -f "$f" ] && kernel_tar="$f" && break
	done || true
	if [ -n "$kernel_tar" ]; then
		kname="$(basename "$kernel_tar")"
		bundle_kver="${kname#kernel-}"
		bundle_kver="${bundle_kver%%.tar.*}"
		if ! tar -xpf "$kernel_tar" -C $root --no-same-owner --numeric-owner; then
			whiptail --msgbox --title "$title" "couldn't unpack the kernel/modules from the install medium. The system may not boot." 10 60
		fi
	elif [ -d /mnt/modules ] && [ -n "$(ls /mnt/modules 2>/dev/null)" ]; then
		cp -a /mnt/modules/. $root/lib/modules/ 2>/dev/null || true
	elif [ -d /lib/modules ]; then
		cp -a /lib/modules/. $root/lib/modules/ 2>/dev/null || true
	fi
	# prefer the version that came in the bundle; otherwise only use the
	# newest/only dir if there is exactly one (avoid depmod'ing a mystery tree)
	if [ -n "${bundle_kver:-}" ] && [ -d "$root/lib/modules/$bundle_kver" ]; then
		kver="$bundle_kver"
	else
		kver="$(ls $root/lib/modules 2>/dev/null | head -n1)"
	fi
	if [ -n "$kver" ] && chroot $root /bin/bash -c "command -v depmod" >/dev/null 2>&1; then
		chroot $root /bin/bash -c "depmod -a $kver" 2>/dev/null || true
	fi
	if [ -d /mnt/firmware ] && [ -n "$(ls /mnt/firmware 2>/dev/null)" ]; then
		mkdir -p $root/lib/firmware
		cp -a /mnt/firmware/. $root/lib/firmware/ 2>/dev/null || true
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
    if [ -f /mnt/spk ]; then
        cp /mnt/spk $root/usr/bin/spk
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

# NetworkManager + nmtui (+ dbus + wpa_supplicant and all their libraries)
# for the installed system. The stage3 tarball ships none of it, so the stack
# that already runs in the live environment is copied over: preferably the
# network bundle from the install medium (packed by scripts/build.sh), else
# straight from the live root. Libraries the target already has (its own
# glibc, libcrypto, ...) are never overwritten - only missing ones are added.
install-network() {
    net_tar=""
    for f in /mnt/network.tar.*; do
        [ -f "$f" ] && net_tar="$f" && break
    done || true
    if [ -n "$net_tar" ]; then
        # --skip-old-files keeps the stage3's own libraries; the live env
        # ships GNU tar so both spellings are tried, plain extract last
        if ! tar -xpf "$net_tar" -C $root --skip-old-files --no-same-owner --numeric-owner 2>/dev/null; then
            if ! tar -xpf "$net_tar" -C $root -k --no-same-owner --numeric-owner 2>/dev/null; then
                tar -xpf "$net_tar" -C $root --no-same-owner --numeric-owner 2>/dev/null || \
                    whiptail --msgbox --title "$title" "couldn't unpack the network bundle, trying the live files instead" 8 60
            fi
        fi
    fi
    if [ -z "$net_tar" ] || [ ! -x $root/usr/bin/NetworkManager ]; then
        install-network-from-live
    fi
    install-network-config
}

# fallback when no (usable) network bundle is on the medium: copy the running
# live stack - binaries, device plugins, helpers, configs - into the target.
# A library is only copied if the target has it in neither /usr/lib64 nor
# /usr/lib, so the stage3's own versions always win.
install-network-from-live() {
    net_missing=""
    mkdir -p $root/usr/bin $root/usr/lib $root/usr/lib64
    for _b in NetworkManager nmtui nmtui-connect nmtui-edit nmtui-hostname \
            nmcli nm-online dbus-daemon dbus-uuidgen wpa_supplicant wpa_cli; do
        _src=""
        [ -e "/usr/bin/$_b" ] || [ -L "/usr/bin/$_b" ] && _src="/usr/bin/$_b"
        if [ -z "$_src" ] && { [ -e "/usr/sbin/$_b" ] || [ -L "/usr/sbin/$_b" ]; }; then
            _src="/usr/sbin/$_b"
        fi
        if [ -z "$_src" ]; then
            net_missing="$net_missing $_b"
            continue
        fi
        cp -a "$_src" $root/usr/bin/ 2>/dev/null || net_missing="$net_missing $_b"
    done || true
    for _lib in /usr/lib64/*; do
        [ -e "$_lib" ] || [ -L "$_lib" ] || continue
        [ -f "$_lib" ] || [ -L "$_lib" ] || continue
        _bn="$(basename "$_lib")"
        if [ -e "$root/usr/lib64/$_bn" ] || [ -e "$root/usr/lib/$_bn" ]; then
            continue
        fi
        cp -a "$_lib" $root/usr/lib64/ 2>/dev/null || true
    done || true
    if [ -d /usr/lib/NetworkManager ]; then
        mkdir -p $root/usr/lib/NetworkManager
        cp -a /usr/lib/NetworkManager/. $root/usr/lib/NetworkManager/ 2>/dev/null || true
    fi
    for _h in /usr/lib/nm-dispatcher /usr/lib/nm-priv-helper \
            /usr/lib/nm-daemon-helper /usr/lib/nm-dhcp-helper \
            /usr/lib/nm-libnm-helper; do
        [ -e "$_h" ] || [ -L "$_h" ] || continue
        [ -e "$root/usr/lib/${_h##*/}" ] && continue
        cp -a "$_h" $root/usr/lib/ 2>/dev/null || true
    done || true
}

# configs, machine-id, OpenRC services and boot setup for the copied stack.
# Everything here only adds what is missing (except our own init scripts),
# so it is safe whether the files came from the bundle or the live root.
install-network-config() {
    mkdir -p $root/etc/NetworkManager/system-connections \
             $root/etc/NetworkManager/conf.d \
             $root/etc/NetworkManager/dispatcher.d \
             $root/usr/share/dbus-1/system.d \
             $root/usr/share/dbus-1/system-services \
             $root/run/dbus $root/run/NetworkManager \
             $root/var/lib/NetworkManager $root/var/lib/dbus \
             $root/etc/init.d
    chmod 700 $root/etc/NetworkManager/system-connections 2>/dev/null || true
    if [ ! -f $root/etc/NetworkManager/NetworkManager.conf ]; then
        if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
            cp /etc/NetworkManager/NetworkManager.conf $root/etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        else
            cat > $root/etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=keyfile
dhcp=internal
dns=default
EOF
        fi
    fi
    for _dbc in org.freedesktop.NetworkManager.conf wpa_supplicant.conf nm-dispatcher.conf; do
        if [ ! -f $root/usr/share/dbus-1/system.d/$_dbc ] && [ -f /usr/share/dbus-1/system.d/$_dbc ]; then
            cp /usr/share/dbus-1/system.d/$_dbc $root/usr/share/dbus-1/system.d/ 2>/dev/null || true
        fi
    done || true
    if [ ! -f $root/usr/share/dbus-1/system.conf ] && [ -f /usr/share/dbus-1/system.conf ]; then
        cp /usr/share/dbus-1/system.conf $root/usr/share/dbus-1/system.conf 2>/dev/null || true
    fi
    if [ ! -f $root/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service ] && \
       [ -f /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service ]; then
        cp /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service \
            $root/usr/share/dbus-1/system-services/ 2>/dev/null || true
    fi
    # the new libraries need a loader cache entry before first boot (and
    # before dbus-uuidgen below, which links against them)
    chroot $root /bin/bash -c "ldconfig" 2>/dev/null || true
    # the bundle/live id is a static placeholder - give this install its own
    _mid=""
    if [ -x $root/usr/bin/dbus-uuidgen ]; then
        _mid="$(chroot $root /usr/bin/dbus-uuidgen --get 2>/dev/null || true)"
    fi
    [ -z "$_mid" ] && _mid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || true)"
    if [ -n "$_mid" ]; then
        echo "$_mid" > $root/etc/machine-id 2>/dev/null || true
        cp $root/etc/machine-id $root/var/lib/dbus/machine-id 2>/dev/null || true
    fi
    # OpenRC services (the stage3 ships none for dbus/NM - it has neither)
    cat > $root/etc/init.d/dbus <<'EOF'
#!/sbin/openrc-run
command=/usr/bin/dbus-daemon
command_args="--system"
pidfile=/run/dbus/pid
name="D-Bus system daemon"

depend() {
	need localmount
	after bootmisc
}

start_pre() {
	mkdir -p /run/dbus
}
EOF
    cat > $root/etc/init.d/NetworkManager <<'EOF'
#!/sbin/openrc-run
command=/usr/sbin/NetworkManager
pidfile=/run/NetworkManager.pid
name="NetworkManager"

depend() {
	need dbus localmount
	after bootmisc modules
	provide net
}
EOF
    chmod 755 $root/etc/init.d/dbus $root/etc/init.d/NetworkManager
    # start D-Bus + networking automatically on boot
    if ! chroot $root /bin/bash -c "rc-update add dbus default && rc-update add NetworkManager default" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "NetworkManager was copied but couldn't be enabled; after reboot run: rc-update add dbus default; rc-update add NetworkManager default" 9 70
    fi
    if [ -n "${net_missing:-}" ]; then
        whiptail --msgbox --title "$title" "NetworkManager was installed, but these live tools were missing and got skipped:$net_missing" 8 60
    fi
    if [ ! -x $root/usr/bin/NetworkManager ] || [ ! -x $root/usr/bin/nmtui ]; then
        whiptail --msgbox --title "$title" "NetworkManager/nmtui couldn't be installed (not on the medium and not in the live system); Wi-Fi will need manual setup after reboot" 9 70
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

    # the bundled GRUB is x86_64-efi only, so a legacy/BIOS install can't work
    if [ ! -d /sys/firmware/efi ]; then
        whiptail --msgbox --title "$title" "this machine booted in legacy/BIOS mode, but Silen can currently only install an EFI bootloader. Boot the medium in UEFI mode and try again." 10 60
        return
    fi

    if [ -d /mnt/grub/usr/local ]; then
        mkdir -p $root/usr/local
        cp -a /mnt/grub/usr/local/. $root/usr/local/
    fi

    if chroot $root /bin/bash -c "PATH=/usr/local/sbin:/usr/local/bin:\$PATH LD_LIBRARY_PATH=/usr/local/lib /usr/local/sbin/grub-install --target=x86_64-efi --efi-directory=/boot --boot-directory=/boot --removable" >/tmp/grub-install.log 2>&1; then
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
        whiptail --msgbox --title "$title" "grub-install failed, see /tmp/grub-install.log for errors" 8 40
    fi
}

main_screen
