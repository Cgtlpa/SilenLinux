#!/bin/bash

# Wi-Fi connection interface for the Silen installer
# Uses the new ui.sh library (no whiptail dependency)

# Source UI library
. /installer/lib/ui.sh

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
    
    # Ensure interface is up
    ip link set "$iface" up 2>/dev/null
    rfkill unblock wifi 2>/dev/null
    rfkill unblock all 2>/dev/null
    
    # Try iwctl first (iwd backend)
    if command -v iwctl >/dev/null 2>&1; then
        # Trigger scan
        iwctl station "$iface" scan >/dev/null 2>&1
        sleep 2
        
        # Get scan results
        local scan_output
        scan_output=$(iwctl station "$iface" get-networks 2>/dev/null)
        
        if [[ -n "$scan_output" ]]; then
            # iwctl output format:
            # *   Network name         Security   Signal
            #     MyNetwork            psk        ▂▄▆_
            local in_networks=0
            while IFS= read -r line; do
                # Skip header lines and empty lines
                [[ -z "$line" ]] && continue
                [[ "$line" == *"Network name"* ]] && continue
                [[ "$line" == *"---"* ]] && continue
                [[ "$line" == *"No networks"* ]] && continue
                
                # Parse: * SSID security signal
                # Remove leading * or space
                line="${line#* }"
                line="${line#* }"
                [[ -z "$line" ]] && continue
                
                local ssid=""
                local security=""
                local signal=""
                
                # Extract SSID (first field)
                ssid=$(echo "$line" | awk '{print $1}')
                
                # Extract security (second field)  
                security=$(echo "$line" | awk '{print $2}')
                
                # Extract signal (last field)
                signal=$(echo "$line" | awk '{print $NF}')
                
                if [[ -n "$ssid" && "$ssid" != "*" && "$ssid" != ">" ]]; then
                    networks+=("$ssid|$security|$signal")
                    in_networks=1
                fi
            done <<< "$scan_output"
            
            if [[ $in_networks -eq 1 ]]; then
                printf '%s\n' "${networks[@]}"
                return 0
            fi
        fi
    fi
    
    # Fallback: try iw dev scan (works without iwd)
    if command -v iw >/dev/null 2>&1; then
        local scan_output
        scan_output=$(iw dev "$iface" scan 2>/dev/null)
        if [[ -n "$scan_output" ]]; then
            local ssid=""
            while IFS= read -r line; do
                if [[ "$line" == *"SSID:"* ]]; then
                    ssid="${line#*SSID: }"
                    ssid="${ssid// /}"
                    if [[ -n "$ssid" && "$ssid" != ">" ]]; then
                        networks+=("$ssid|psk|▂▄▆_")
                    fi
                fi
            done <<< "$scan_output"
            
            if [[ ${#networks[@]} -gt 0 ]]; then
                printf '%s\n' "${networks[@]}"
                return 0
            fi
        fi
    fi
    
    return 1
}

connect_wifi() {
    local iface="$1"
    local ssid="$2"
    local passphrase="$3"
    
    # Use iwctl to connect
    if [[ -n "$passphrase" ]]; then
        iwctl --passphrase "$passphrase" station "$iface" connect "$ssid" 2>&1
    else
        iwctl station "$iface" connect "$ssid" 2>&1
    fi
    
    local ret=$?
    if [[ $ret -eq 0 ]]; then
        # Wait for connection (up to 30 seconds)
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
    
    ui_msg "$title" "No internet connection detected.\n\nTo install Silen, an internet connection is required to download packages.\n\nPlease select a Wi-Fi network to continue." "warn"
    
    local interfaces=()
    mapfile -t interfaces < <(get_wireless_interfaces)
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        ui_msg "$title" "No wireless interfaces found.\n\nPlease connect via Ethernet cable and try again." "error"
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
        choice=$(ui_menu "$title" "Select wireless interface:" "${menu_items[@]}")
        [[ $choice -eq 0 ]] && return 1
        iface="${interfaces[choice-1]}"
    fi
    
    # Bring interface up
    ip link set "$iface" up 2>/dev/null
    rfkill unblock wifi 2>/dev/null
    rfkill unblock all 2>/dev/null
    
    while true; do
        ui_info "$title" "Scanning for networks on $iface...\n\nPlease wait while we scan for available Wi-Fi networks."
        
        local networks=()
        mapfile -t networks < <(scan_wifi_networks "$iface")
        
        if [[ ${#networks[@]} -eq 0 ]]; then
            local retry
            retry=$(ui_menu "$title" "No Wi-Fi networks found. What would you like to do?" \
                "Rescan" "Scan for networks again" \
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
                        return 0
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
            # Rescan
            continue
        elif [[ $choice -eq $((i+2)) ]]; then
            # Enter SSID manually
            local ssid
            ssid=$(ui_input "$title" "Enter SSID (network name):")
            [[ -z "$ssid" ]] && continue
            local passphrase
            passphrase=$(ui_password "$title" "Enter password for $ssid (leave empty for open network):")
            ui_info "$title" "Connecting to $ssid..."
            if connect_wifi "$iface" "$ssid" "$passphrase"; then
                ui_msg "$title" "Connected to $ssid successfully!" "info"
                return 0
            else
                ui_msg "$title" "Failed to connect to $ssid. Please check password and try again." "error"
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
            passphrase=$(ui_password "$title" "Enter password for $ssid:")
            [[ -z "$passphrase" ]] && continue
        fi
        
        ui_info "$title" "Connecting to $ssid..."
        if connect_wifi "$iface" "$ssid" "$passphrase"; then
            ui_msg "$title" "Connected to $ssid successfully!" "info"
            return 0
        else
            ui_msg "$title" "Failed to connect to $ssid. Please check password and try again." "error"
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
                ui_msg "$title" "Connected to Wi-Fi but no internet access.\nPlease try a different network or check your connection." "error"
            fi
        else
            # User chose to go back to main menu
            return 1
        fi
    done
}