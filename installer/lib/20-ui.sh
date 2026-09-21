choose-install-mode() {
    while [ -z "$INSTALL_MODE" ]; do
        INSTALL_MODE=$(whiptail --title "$title" --menu "Choose install type" 14 60 2 \
            "online" "With internet: wifi setup, drivers, desktops (needs Wi-Fi)" \
            "offline" "No internet: base system only, no drivers/desktops" \
            3>&1 1>&2 2>&3 || true)
        [ -n "$INSTALL_MODE" ] || continue
    done
    if [ "$INSTALL_MODE" = "online" ]; then
        whiptail --msgbox --title "$title" "Online install selected.\n\nConnect to Wi-Fi next, then drivers and desktops can be installed." 9 60 || true
        connect_internet
    else
        whiptail --msgbox --title "$title" "Offline install selected.\n\nNo internet needed. Only the base system is installed - no Wi-Fi setup, no GPU drivers, no desktop downloads." 10 60 || true
    fi
}

connect_internet() {
    if whiptail --title "$title" --yesno "Would you like to connect to the internet?\nNeeded for drivers, Desktop envs and packages via spk" 10 55; then
        if command -v nmtui >/dev/null 2>&1; then
            nmtui 2>/dev/null || true
        fi
        if whiptail --title "$title" --yesno "Install wifi drivers?\nUses spk for kernel modules and firmware" 10 55; then
            install_wifi_drivers
        fi
    fi
}

main_screen() {
    if [ "$INSTALL_MODE" = "offline" ]; then
        men1=$(whiptail --title "$title (offline)" --menu "Choose an option" 14 53 4 \
            "1" "Install Silen (offline, no downloads)" \
            "2" "Shell" \
            "3" "Reboot" \
            "4" "Change install type (now: offline)" \
            3>&1 1>&2 2>&3 || true)

        if [ "$men1" = "1" ]; then
            partitioning
        elif [ "$men1" = "2" ]; then
            sh || true
            main_screen
        elif [ "$men1" = "3" ]; then
            sync 2>/dev/null || true
            reboot -f 2>/dev/null || whiptail --msgbox --title "$title" "reboot failed run reboot -f or force off you maschine" 8 60 || true
            main_screen
        elif [ "$men1" = "4" ]; then
            INSTALL_MODE=""
            choose-install-mode
            main_screen
        else
            main_screen
        fi
        return
    fi

    men1=$(whiptail --title "$title (online)" --menu "Choose an option" 15 53 6 \
        "1" "Install Silen" \
        "2" "Configure internet nmtui and wifi drivers" \
        "3" "Wi-Fi status (debug purposes)" \
        "4" "Shell" \
        "5" "Reboot" \
        "6" "Change install type (now: online)" \
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
            whiptail --msgbox --title "$title" "wifi check not found on this iso" 8 40 || true
        fi
        main_screen
    elif [ "$men1" = "4" ]; then
        sh || true
        main_screen
    elif [ "$men1" = "5" ]; then
        sync 2>/dev/null || true
        reboot -f 2>/dev/null || whiptail --msgbox --title "$title" "reboot failed run reboot -f or force off you maschine" 8 60 || true
        main_screen
    elif [ "$men1" = "6" ]; then
        INSTALL_MODE=""
        choose-install-mode
        main_screen
    else
        main_screen
    fi
}

configure_internet() {
    if [ "$INSTALL_MODE" != "online" ]; then
        whiptail --msgbox --title "$title" "Offline install: internet setup is disabled" 8 50 || true
        main_screen
        return
    fi
    if ! command -v nmtui >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "nmtui not found on this iso might be a ventoy issue please try again with dd" 8 45 || true
        main_screen
        return
    fi

    nmtui 2>/dev/null || true

    if whiptail --title "$title" --yesno "Install Wi-Fi drivers now? requires wifi access\nThis will use spk to install kernel modules and firmware for your wifi card" 10 55; then
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
        "custom" "Enter custom package name maybe its in the repo" \
        3>&1 1>&2 2>&3 || true)

    [ -z "$wifi_choice" ] && return

    if [ "$wifi_choice" = "custom" ]; then
        wifi_choice=$(whiptail --title "$title" --inputbox "Enter spk package name from spk_pkgs" 8 50 3>&1 1>&2 2>&3 || true)
        [ -z "$wifi_choice" ] && return
    fi

    whiptail --infobox --title "$title" "Installing $wifi_choice via spk This may take a while depending on your internet speeds" 8 50 2>/dev/null || true

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
