#!/bin/bash

# Wi-Fi connection interface for the Silen installer
# This is called when the user selects Install and no internet connection is detected

check_internet() {
    local timeout=5
    local test_urls=("https://huggingface.co" "https://github.com" "https://archlinux.org" "https://google.com")
    
    for url in "${test_urls[@]}"; do
        if curl -s --max-time "$timeout" --head "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
    
    # Also try ping as fallback
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
    
    # Trigger scan
    iwctl station "$iface" scan >/dev/null 2>&1
    sleep 2
    
    # Get scan results
    local scan_output
    scan_output=$(iwctl station "$iface" get-networks 2>/dev/null | tail -n +4 | head -n -1)
    
    if [[ -z "$scan_output" ]]; then
        return 1
    fi
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Parse: network name, security, signal
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
    
    # Create a temporary network config
    local config_dir="/var/lib/iwd"
    mkdir -p "$config_dir"
    
    # Use iwctl to connect
    if [[ -n "$passphrase" ]]; then
        iwctl --passphrase "$passphrase" station "$iface" connect "$ssid" 2>&1
    else
        iwctl station "$iface" connect "$ssid" 2>&1
    fi
    
    local ret=$?
    if [[ $ret -eq 0 ]]; then
        # Wait for connection
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

wifi_connection_screen() {
    local title="Silen Linux - Wi-Fi Setup"
    
    whiptail --title "$title" --msgbox "No internet connection detected.\n\nTo install Silen, an internet connection is required to download packages.\n\nPlease select a Wi-Fi network to continue." 12 60
    
    local interfaces=()
    mapfile -t interfaces < <(get_wireless_interfaces)
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        whiptail --title "$title" --msgbox "No wireless interfaces found.\n\nPlease connect via Ethernet cable and try again." 10 60
        return 1
    fi
    
    # If multiple interfaces, let user choose
    local iface="${interfaces[0]}"
    if [[ ${#interfaces[@]} -gt 1 ]]; then
        local menu_items=()
        for i in "${!interfaces[@]}"; do
            menu_items+=("$((i+1))" "${interfaces[i]}")
        done
        local choice
        choice=$(whiptail --title "$title" --menu "Select wireless interface:" 15 60 6 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        [[ -z "$choice" ]] && return 1
        iface="${interfaces[choice-1]}"
    fi
    
    # Bring interface up
    ip link set "$iface" up 2>/dev/null
    rfkill unblock wifi 2>/dev/null
    rfkill unblock all 2>/dev/null
    
    while true; do
        whiptail --title "$title" --infobox "Scanning for networks on $iface..." 8 60
        
        local networks=()
        mapfile -t networks < <(scan_wifi_networks "$iface")
        
        if [[ ${#networks[@]} -eq 0 ]]; then
            local retry
            retry=$(whiptail --title "$title" --menu "No networks found. What would you like to do?" 15 60 4 \
                "1" "Rescan" \
                "2" "Try different interface" \
                "3" "Enter SSID manually" \
                "4" "Back to main menu" 3>&1 1>&2 2>&3)
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
                        choice=$(whiptail --title "$title" --menu "Select wireless interface:" 15 60 6 "${menu_items[@]}" 3>&1 1>&2 2>&3)
                        [[ -z "$choice" ]] && return 1
                        iface="${interfaces[choice-1]}"
                        ip link set "$iface" up 2>/dev/null
                        continue
                    else
                        whiptail --title "$title" --msgbox "No other wireless interfaces available." 8 60
                        continue
                    fi
                    ;;
                3)
                    local ssid
                    ssid=$(whiptail --title "$title" --inputbox "Enter SSID (network name):" 8 60 3>&1 1>&2 2>&3)
                    [[ -z "$ssid" ]] && continue
                    local passphrase
                    passphrase=$(whiptail --title "$title" --passwordbox "Enter password for $ssid (leave empty for open network):" 8 60 3>&1 1>&2 2>&3)
                    whiptail --title "$title" --infobox "Connecting to $ssid..." 8 60
                    if connect_wifi "$iface" "$ssid" "$passphrase"; then
                        whiptail --title "$title" --msgbox "Connected to $ssid successfully!" 8 60
                        return 0
                    else
                        whiptail --title "$title" --msgbox "Failed to connect to $ssid. Please check password and try again." 10 60
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
        choice=$(whiptail --title "$title" --menu "Available networks on $iface:" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        [[ -z "$choice" ]] && return 1
        
        if [[ $choice -eq $((i+1)) ]]; then
            # Rescan
            continue
        elif [[ $choice -eq $((i+2)) ]]; then
            # Enter SSID manually
            local ssid
            ssid=$(whiptail --title "$title" --inputbox "Enter SSID (network name):" 8 60 3>&1 1>&2 2>&3)
            [[ -z "$ssid" ]] && continue
            local passphrase
            passphrase=$(whiptail --title "$title" --passwordbox "Enter password for $ssid (leave empty for open network):" 8 60 3>&1 1>&2 2>&3)
            whiptail --title "$title" --infobox "Connecting to $ssid..." 8 60
            if connect_wifi "$iface" "$ssid" "$passphrase"; then
                whiptail --title "$title" --msgbox "Connected to $ssid successfully!" 8 60
                return 0
            else
                whiptail --title "$title" --msgbox "Failed to connect to $ssid. Please check password and try again." 10 60
                continue
            fi
        elif [[ $choice -eq $((i+3)) ]]; then
            return 1
        fi
        
        # Connect to selected network
        local idx=$((choice-1))
        IFS='|' read -r ssid security signal <<< "${networks[idx]}"
        
        local passphrase=""
        if [[ "$security" == "psk" || "$security" == "802.1x" ]]; then
            passphrase=$(whiptail --title "$title" --passwordbox "Enter password for $ssid:" 8 60 3>&1 1>&2 2>&3)
            [[ -z "$passphrase" ]] && continue
        fi
        
        whiptail --title "$title" --infobox "Connecting to $ssid..." 8 60
        if connect_wifi "$iface" "$ssid" "$passphrase"; then
            whiptail --title "$title" --msgbox "Connected to $ssid successfully!" 8 60
            return 0
        else
            whiptail --title "$title" --msgbox "Failed to connect to $ssid. Please check password and try again." 10 60
        fi
    done
}

ensure_internet() {
    if check_internet; then
        return 0
    fi
    
    while true; do
        if wifi_connection_screen; then
            if check_internet; then
                return 0
            else
                whiptail --title "Silen Linux" --msgbox "Connected to Wi-Fi but no internet access.\nPlease try a different network or check your connection." 10 60
            fi
        else
            # User chose to go back to main menu
            return 1
        fi
    done
}