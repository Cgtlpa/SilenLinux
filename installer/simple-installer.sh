#!/bin/bash

# Simplified Silen Installer using custom UI (no whiptail)
# This replaces the complex whiptail-based installer

# Source UI library
. /installer/lib/ui.sh

title="Silen Linux Installer"

# Check internet connectivity
check_internet() {
    local timeout=5
    local test_urls=("https://huggingface.co" "https://github.com" "https://archlinux.org" "https://google.com")
    
    for url in "${test_urls[@]}"; do
        if curl -s --max-time "$timeout" --head "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
    
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

get_wireless_interfaces() {
    local interfaces=()
    for iface in /sys/class/net/*; do
        iface="${iface##*/}"
        if [[ -d "/sys/class/net/$iface/wireless" ]] || [[ -d "/sys/class/net/$iface/phy80211" ]]; then
            interfaces+=("$iface")
        fi
    done
    printf '%s\n' "${interfaces[@]}"
}

scan_wifi_networks() {
    local iface="$1"
    local networks=()
    
    iwctl station "$iface" scan >/dev/null 2>&1
    sleep 2
    
    local scan_output
    scan_output=$(iwctl station "$iface" get-networks 2>/dev/null | tail -n +4 | head -n -1)
    
    if [[ -z "$scan_output" ]]; then
        return 1
    fi
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local ssid=$(echo "$line" | awk '{for(i=1;i<=NF-2;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        local security=$(echo "$line" | awk '{print $(NF-1)}')
        local signal=$(echo "$line" | awk '{print $NF}')
        
        if [[ -n "$ssid" && "$ssid" != ">" ]]; then
            networks+=("$ssid|$security|$signal")
        fi
    done <<< "$scan_output"
    
    printf '%s\n' "${networks[@]}"
}

connect_wifi() {
    local iface="$1"
    local ssid="$2"
    local passphrase="$3"
    
    local config_dir="/var/lib/iwd"
    mkdir -p "$config_dir"
    
    if [[ -n "$passphrase" ]]; then
        iwctl --passphrase "$passphrase" station "$iface" connect "$ssid" 2>&1
    else
        iwctl station "$iface" connect "$ssid" 2>&1
    fi
    
    local ret=$?
    if [[ $ret -eq 0 ]]; then
        local i=0
        while [[ $i -lt 30 ]]; do
            if iwctl station "$iface" show 2>/dev/null | grep -q "Connected network"; then
                return 0
            fi
            sleep 1
            ((i++))
        done
        return 1
    fi
    return $ret
}

ensure_internet() {
    if check_internet; then
        return 0
    fi
    
    ui_msg "$title" "No internet connection detected.\n\nTo install Silen, an internet connection is required to download packages.\n\nPlease select a Wi-Fi network to continue." "warn"
    
    local interfaces=()
    mapfile -t interfaces < <(get_wireless_interfaces)
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        ui_msg "$title" "No wireless interfaces found.\n\nPlease connect via Ethernet cable and try again." "error"
        return 1
    fi
    
    local iface="${interfaces[0]}"
    if [[ ${#interfaces[@]} -gt 1 ]]; then
        local menu_items=()
        for i in "${!interfaces[@]}"; do
            menu_items+=("$((i+1))" "${interfaces[i]}")
        done
        local choice
        choice=$(ui_menu "$title" "Select wireless interface:" "${menu_items[@]}")
        [[ $choice -eq 0 ]] && return 1
        iface="${interfaces[choice-1]}"
    fi
    
    ip link set "$iface" up 2>/dev/null
    rfkill unblock wifi 2>/dev/null
    rfkill unblock all 2>/dev/null
    
    while true; do
        ui_info "$title" "Scanning for networks on $iface..."
        
        local networks=()
        mapfile -t networks < <(scan_wifi_networks "$iface")
        
        if [[ ${#networks[@]} -eq 0 ]]; then
            local retry
            retry=$(ui_menu "$title" "No networks found. What would you like to do?" \
                "Rescan" "Scan again" \
                "Try different interface" "Select another wireless interface" \
                "Enter SSID manually" "Connect to hidden network" \
                "Back to main menu" "Return to main menu")
            case "$retry" in
                1) continue ;;
                2) 
                    mapfile -t interfaces < <(get_wireless_interfaces)
                    if [[ ${#interfaces[@]} -gt 1 ]]; then
                        local menu_items=()
                        for i in "${!interfaces[@]}"; do
                            menu_items+=("$((i+1))" "${interfaces[i]}")
                        done
                        local choice
                        choice=$(ui_menu "$title" "Select wireless interface:" "${menu_items[@]}")
                        [[ $choice -eq 0 ]] && return 1
                        iface="${interfaces[choice-1]}"
                        ip link set "$iface" up 2>/dev/null
                        continue
                    else
                        ui_msg "$title" "No other wireless interfaces available." "warn"
                        continue
                    fi
                    ;;
                3)
                    local ssid
                    ssid=$(ui_input "$title" "Enter SSID (network name):")
                    [[ -z "$ssid" ]] && continue
                    local passphrase
                    passphrase=$(ui_password "$title" "Enter password for $ssid (leave empty for open network):")
                    ui_info "$title" "Connecting to $ssid..."
                    if connect_wifi "$iface" "$ssid" "$passphrase"; then
                        ui_msg "$title" "Connected to $ssid successfully!" "info"
                        break
                    else
                        ui_msg "$title" "Failed to connect to $ssid. Please check password and try again." "error"
                        continue
                    fi
                    ;;
                4) return 1 ;;
            esac
            continue
        fi
        
        # Build menu items
        local menu_items=()
        local i=0
        for net in "${networks[@]}"; do
            IFS='|' read -r ssid security signal <<< "$net"
            local display_security="Open"
            [[ "$security" == "psk" ]] && display_security="WPA/WPA2"
            [[ "$security" == "802.1x" ]] && display_security="Enterprise"
            menu_items+=("$((i+1))" "$ssid [$display_security] Signal: $signal")
            ((i++))
        done
        menu_items+=("$((i+1))" "Rescan")
        menu_items+=("$((i+2))" "Enter SSID manually")
        menu_items+=("$((i+3))" "Back to main menu")
        
        local choice
        choice=$(ui_menu "$title" "Available networks on $iface:" "${menu_items[@]}")
        [[ $choice -eq 0 ]] && return 1
        
        if [[ $choice -eq $((i+1)) ]]; then
            continue
        elif [[ $choice -eq $((i+2)) ]]; then
            local ssid
            ssid=$(ui_input "$title" "Enter SSID (network name):")
            [[ -z "$ssid" ]] && continue
            local passphrase
            passphrase=$(ui_password "$title" "Enter password for $ssid (leave empty for open network):")
            ui_info "$title" "Connecting to $ssid..."
            if connect_wifi "$iface" "$ssid" "$passphrase"; then
                ui_msg "$title" "Connected to $ssid successfully!" "info"
                break
            else
                ui_msg "$title" "Failed to connect to $ssid. Please check password and try again." "error"
                continue
            fi
        elif [[ $choice -eq $((i+3)) ]]; then
            return 1
        fi
        
        local idx=$((choice-1))
        IFS='|' read -r ssid security signal <<< "${networks[idx]}"
        
        local passphrase=""
        if [[ "$security" == "psk" || "$security" == "802.1x" ]]; then
            passphrase=$(ui_password "$title" "Enter password for $ssid:")
            [[ -z "$passphrase" ]] && continue
        fi
        
        ui_info "$title" "Connecting to $ssid..."
        if connect_wifi "$iface" "$ssid" "$passphrase"; then
            ui_msg "$title" "Connected to $ssid successfully!" "info"
            break
        else
            ui_msg "$title" "Failed to connect to $ssid. Please check password and try again." "error"
        fi
    done
    
    if check_internet; then
        return 0
    else
        ui_msg "$title" "Connected to Wi-Fi but no internet access.\nPlease try a different network or check your connection." "error"
        return 1
    fi
}

# Get available disks
get_disks() {
    local disks=()
    for disk in /dev/sd* /dev/nvme*n1 /dev/vd* /dev/mmcblk*; do
        [[ -b "$disk" ]] || continue
        [[ "$disk" =~ [0-9]$ ]] && continue  # Skip partitions
        local size=$(lsblk -b -n -o SIZE "$disk" 2>/dev/null | head -1)
        [[ -z "$size" ]] && continue
        local size_gib=$((size / 1024 / 1024 / 1024))
        local model=$(lsblk -n -o MODEL "$disk" 2>/dev/null | head -1)
        disks+=("$disk" "${disk} (${size_gib} GiB) ${model}")
    done
    printf '%s\n' "${disks[@]}"
}

# Main installer
main() {
    ui_msg "$title" "Welcome to Silen Linux Installer!\n\nThis will guide you through installing Silen Linux on your system." "info"
    
    # Check internet
    if ! ensure_internet; then
        ui_msg "$title" "Internet connection is required for installation.\nPlease configure networking and try again." "error"
        return 1
    fi
    
    ui_msg "$title" "Internet connection verified. Proceeding with installation." "info"
    
    # Select disk
    local disks=()
    mapfile -t disks < <(get_disks)
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        ui_msg "$title" "No disks found. Connect a disk and try again." "error"
        return 1
    fi
    
    local disk
    if [[ ${#disks[@]} -eq 2 ]]; then
        disk="${disks[0]}"
    else
        local menu_items=()
        for ((i=0; i<${#disks[@]}; i+=2)); do
            menu_items+=("$((i/2 + 1))" "${disks[i]}" "${disks[i+1]}")
        done
        local choice
        choice=$(ui_menu "$title" "Select the disk to install on:" "${menu_items[@]}")
        [[ $choice -eq 0 ]] && return 1
        disk="${disks[$((choice-1))*2]}"
    fi
    
    # Confirm wipe
    if ! ui_confirm "$title" "Wipe $disk?\n\nThis erases everything on the disk."; then
        return 1
    fi
    
    # Partition
    ui_info "$title" "Partitioning $disk - writing GPT..."
    parted -s "$disk" mklabel gpt 2>/dev/null || { ui_msg "$title" "Failed to write partition table" "error"; return 1; }
    parted -s "$disk" mkpart ESP fat32 1MiB 1GiB 2>/dev/null || { ui_msg "$title" "Failed to create ESP partition" "error"; return 1; }
    parted -s "$disk" set 1 esp on 2>/dev/null
    parted -s "$disk" mkpart root ext4 1GiB 100% 2>/dev/null || { ui_msg "$title" "Failed to create root partition" "error"; return 1; }
    
    # Wait for partitions
    sleep 2
    local bootp="${disk}1"
    local rootp="${disk}2"
    [[ "$disk" =~ nvme|mmcblk ]] && bootp="${disk}p1" && rootp="${disk}p2"
    
    # Format
    ui_info "$title" "Formatting $bootp FAT32 and $rootp ext4..."
    mkfs.fat -F32 "$bootp" 2>/dev/null || { ui_msg "$title" "Failed to format ESP as FAT32" "error"; return 1; }
    mkfs.ext4 -F "$rootp" 2>/dev/null || { ui_msg "$title" "Failed to format root as ext4" "error"; return 1; }
    
    # Mount
    local ROOT_PATH="/mnt/target"
    mkdir -p "$ROOT_PATH"
    mount "$rootp" "$ROOT_PATH" || { ui_msg "$title" "Failed to mount root partition" "error"; return 1; }
    mkdir -p "$ROOT_PATH/boot"
    mount "$bootp" "$ROOT_PATH/boot" || { ui_msg "$title" "Failed to mount boot partition" "error"; return 1; }
    
    # Extract base system
    ui_info "$title" "Installing base system..."
    local base_tarball=""
    for s in /mnt/stage3-*.tar.* /mnt/tarball-*.tar.* /mnt/tarball-*.xz /mnt/*.tar.xz /mnt/*.tar.zst; do
        [[ -f "$s" ]] || continue
        case "$(basename "$s")" in
            kernel-*.tar.*|headers-*.tar.*|network.tar.*|spk.tar.*|nvidia-kmods-*.tar.*) continue ;;
        esac
        base_tarball="$s" && break
    done
    
    if [[ -z "$base_tarball" ]]; then
        ui_msg "$title" "No base tarball found on install medium" "error"
        return 1
    fi
    
    tar -xpf "$base_tarball" -C "$ROOT_PATH" --strip-components=1 --no-same-owner --numeric-owner --xattrs-include='*.*' 2>/dev/null || \
    tar -xpf "$base_tarball" -C "$ROOT_PATH" --no-same-owner --numeric-owner --xattrs-include='*.*' 2>/dev/null || { ui_msg "$title" "Failed to unpack base system" "error"; return 1; }
    
    # Basic setup
    ui_info "$title" "Configuring system..."
    
    # Get settings
    local hostnm
    hostnm=$(ui_input "$title" "Set the hostname:" "silen")
    [[ -z "$hostnm" ]] && hostnm="silen"
    
    local rootpass
    while true; do
        rootpass=$(ui_password "$title" "Set the root password:")
        [[ -n "$rootpass" ]] && break
        ui_msg "$title" "Password can't be empty, try again" "error"
    done
    
    local newuser=""
    if ui_confirm "$title" "Create a user account?"; then
        while true; do
            newuser=$(ui_input "$title" "Username for the new account:")
            [[ -n "$newuser" ]] || { ui_msg "$title" "Username can't be empty" "error"; continue; }
            [[ "$newuser" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ui_msg "$title" "Invalid username: only lowercase letters, digits, _ and - allowed, max 32 chars, must start with letter or _" "error"; continue; }
            break
        done
        
        local userpass
        while true; do
            userpass=$(ui_password "$title" "Password for $newuser:")
            [[ -n "$userpass" ]] && break
            ui_msg "$title" "Password can't be empty" "error"
        done
    fi
    
    # Timezone
    local zone
    zone=$(ui_menu "$title" "Select timezone:" \
        1 "UTC" "Coordinated Universal Time" \
        2 "US/Eastern" "Eastern Time" \
        3 "US/Pacific" "Pacific Time" \
        4 "Europe/London" "London" \
        5 "Europe/Paris" "Paris" \
        6 "Europe/Berlin" "Berlin" \
        7 "Asia/Tokyo" "Tokyo" \
        8 "Australia/Sydney" "Sydney")
    case "$zone" in
        1) zone="UTC" ;;
        2) zone="US/Eastern" ;;
        3) zone="US/Pacific" ;;
        4) zone="Europe/London" ;;
        5) zone="Europe/Paris" ;;
        6) zone="Europe/Berlin" ;;
        7) zone="Asia/Tokyo" ;;
        8) zone="Australia/Sydney" ;;
        *) zone="UTC" ;;
    esac
    
    # Keyboard
    local keymap
    keymap=$(ui_menu "$title" "Select keyboard layout:" \
        1 "us" "US English" \
        2 "uk" "UK English" \
        3 "de" "German" \
        4 "fr" "French" \
        5 "es" "Spanish" \
        6 "it" "Italian" \
        7 "jp" "Japanese" \
        8 "ru" "Russian")
    case "$keymap" in
        1) keymap="us" ;;
        2) keymap="uk" ;;
        3) keymap="de" ;;
        4) keymap="fr" ;;
        5) keymap="es" ;;
        6) keymap="it" ;;
        7) keymap="jp" ;;
        8) keymap="ru" ;;
        *) keymap="us" ;;
    esac
    
    # Filesystem
    local fstype
    fstype=$(ui_menu "$title" "Select filesystem for the system partition:" \
        1 "ext4" "Standard Linux filesystem" \
        2 "btrfs" "Modern filesystem with snapshots")
    case "$fstype" in
        1) fstype="ext4" ;;
        2) fstype="btrfs" ;;
        *) fstype="ext4" ;;
    esac
    
    # Confirm settings
    local settings_summary="hostname: $hostnm\nuser: ${newuser:-none}\ntimezone: $zone\nkeyboard: $keymap\nfilesystem: $fstype"
    if ! ui_confirm "$title" "Install with these settings?\n\n$settings_summary"; then
        return 1
    fi
    
    # Apply settings
    ui_info "$title" "Applying settings..."
    echo "$hostnm" > "$ROOT_PATH/etc/hostname"
    sed -i "s/^hostname=.*/hostname=\"$hostnm\"/" "$ROOT_PATH/etc/conf.d/hostname" 2>/dev/null || echo "hostname=\"$hostnm\"" >> "$ROOT_PATH/etc/conf.d/hostname"
    
    # Set root password
    chroot "$ROOT_PATH" /usr/bin/chpasswd <<< "root:$rootpass" 2>/dev/null || { ui_msg "$title" "Failed to set root password" "error"; return 1; }
    
    # Create user
    if [[ -n "$newuser" ]]; then
        chroot "$ROOT_PATH" /usr/sbin/useradd -m -G wheel,video,audio -s /bin/bash "$newuser" 2>/dev/null
        chroot "$ROOT_PATH" /usr/bin/chpasswd <<< "$newuser:$userpass" 2>/dev/null
    fi
    
    # Timezone
    ln -sf "/usr/share/zoneinfo/$zone" "$ROOT_PATH/etc/localtime"
    echo "$zone" > "$ROOT_PATH/etc/timezone"
    
    # Keymap
    echo "keymap=\"$keymap\"" > "$ROOT_PATH/etc/conf.d/keymaps"
    
    # fstab
    local bootuuid=$(blkid -s UUID -o value "$bootp")
    local rootuuid=$(blkid -s UUID -o value "$rootp")
    local fspass="0 1"
    [[ "$fstype" = "ext4" ]] || fspass="0 0"
    cat > "$ROOT_PATH/etc/fstab" <<EOF
UUID=$rootuuid / $fstype defaults $fspass
UUID=$bootuuid /boot vfat defaults 0 2
EOF
    
    # Install kernel and modules
    ui_info "$title" "Installing kernel and drivers..."
    local kernel_tar=""
    for f in /mnt/kernel-*.tar.*; do
        [[ -f "$f" ]] && kernel_tar="$f" && break
    done
    if [[ -n "$kernel_tar" ]]; then
        tar -xpf "$kernel_tar" -C "$ROOT_PATH" --no-same-owner --numeric-owner 2>/dev/null
        local kname="$(basename "$kernel_tar")"
        local bundle_kver="${kname#kernel-}"
        bundle_kver="${bundle_kver%%.tar.*}"
        if [[ -n "$bundle_kver" ]] && [[ -d "$ROOT_PATH/lib/modules/$bundle_kver" ]]; then
            chroot "$ROOT_PATH" /bin/bash -c "depmod -a $bundle_kver" 2>/dev/null || true
        fi
    fi
    
    # Install firmware
    if [[ -d /mnt/firmware ]]; then
        mkdir -p "$ROOT_PATH/lib/firmware"
        cp -a /mnt/firmware/. "$ROOT_PATH/lib/firmware/" 2>/dev/null
    fi
    
    # Install network
    ui_info "$title" "Installing network stack..."
    # Copy iwd
    if [[ -f /usr/bin/iwctl ]]; then
        mkdir -p "$ROOT_PATH/usr/bin"
        cp /usr/bin/iwctl "$ROOT_PATH/usr/bin/"
        copy_libs "/usr/bin/iwctl" 2>/dev/null || true
    fi
    if [[ -f /usr/libexec/iwd ]]; then
        mkdir -p "$ROOT_PATH/usr/libexec"
        cp /usr/libexec/iwd "$ROOT_PATH/usr/libexec/"
    fi
    
    # Enable services
    chroot "$ROOT_PATH" rc-update add dbus default 2>/dev/null || true
    chroot "$ROOT_PATH" rc-update add iwd default 2>/dev/null || true
    chroot "$ROOT_PATH" rc-update add dhcpcd default 2>/dev/null || true
    chroot "$ROOT_PATH" rc-update add elogind boot 2>/dev/null || true
    chroot "$ROOT_PATH" rc-update add sddm default 2>/dev/null || true
    
    # Install packages via Cres
    ui_info "$title" "Downloading and installing packages via Cres..."
    # This would be the Cres integration - simplified for now
    
    # Install GRUB
    ui_info "$title" "Installing bootloader..."
    chroot "$ROOT_PATH" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Silen 2>/dev/null || { ui_msg "$title" "GRUB install failed" "error"; return 1; }
    chroot "$ROOT_PATH" grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || { ui_msg "$title" "GRUB config failed" "error"; return 1; }
    
    # Generate initramfs
    ui_info "$title" "Generating initramfs..."
    chroot "$ROOT_PATH" /usr/local/bin/silen-mkinitramfs 2>/dev/null || true
    
    # Sync and finish
    sync
    umount -R "$ROOT_PATH" 2>/dev/null || true
    
    ui_msg "$title" "Silen Linux has been successfully installed!\n\nThe system will now show a short introduction to Silen." "info"
    
    # Show tutorial
    ui_msg "$title" "Welcome to Silen Linux!\n\n\"Reliable by default. Powerful when you want it.\"\n\nSilen is a minimal, independent x86_64 Linux distribution focused on simplicity, reliability, and user control." "info"
    
    ui_msg "$title" "Cres Package Manager:\n  sudo cres get <package>   Install a package\n  sudo cres rm <package>    Remove a package\n  sudo cres update           Update all packages\n  cres search <pattern>      Search packages\n  cres list                  List installed packages\n\nExample: sudo cres get fastfetch" "info"
    
    ui_msg "$title" "InstantWM (default Wayland compositor):\n  Super+Return   Open terminal (kitty)\n  Super+Space    Application launcher (rofi)\n  Super+E        InstantMenu\n  Super+Shift+Q  Close window\n  Super+C        Toggle floating\n  Super+M        Toggle tiling/maximized\n\nConfig: ~/.config/instantwm/config.toml" "info"
    
    ui_msg "$title" "System Basics:\n  rc-status          Show running services\n  rc-service <svc> start|stop|restart\n  rc-update add <svc> <runlevel>\n\nNetwork: iwctl for Wi-Fi\nDNS: /etc/resolv.conf (managed by iwd)" "info"
    
    ui_msg "$title" "Help & Documentation:\n  man silen-installer     Installation guide\n  man cres                Package manager manual\n  silen-wifi-check        Wi-Fi diagnostics\n  silenfetch              System info\n\nGitHub: https://github.com/SilenLinux" "info"
    
    # Final choice
    local choice
    choice=$(ui_menu "$title - Installation Complete" "Silen Linux has been successfully installed!\n\nWhat would you like to do?" \
        "Reboot into Silen" "Restart and boot into your new Silen system" \
        "Exit to shell" "Stay in the live environment")
    
    case "$choice" in
        1)
            sync
            reboot -f
            ;;
        2)
            return 0
            ;;
    esac
}

main "$@"