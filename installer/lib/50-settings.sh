ask-install-settings() {
    hostnm=$(hostname 2>/dev/null || true)
    case "$hostnm" in
        ""|archlinux|"(none)"|localhost) hostnm="silen" ;;
    esac
    hostnm=$(whiptail --title "$title" --inputbox "Set the hostname" 8 40 "$hostnm" 3>&1 1>&2 2>&3 || true)
    [ -z "$hostnm" ] && hostnm="silen"
    hostnm="$(printf '%s' "$hostnm" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -e 's/^-*//' -e 's/-*$//')"
    [ -z "$hostnm" ] && hostnm="silen"

    rootpass=""
    while :; do
        if ! rootpass=$(whiptail --title "$title" --passwordbox "Set the root password" 8 40 3>&1 1>&2 2>&3); then
            return 1
        fi
        [ -n "$rootpass" ] || { whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true; continue; }
        case "$rootpass" in
            *:*|*$'\n'* )
                whiptail --msgbox --title "$title" "password can't contain : or newline, try again" 8 50 || true
                rootpass=""
                continue
                ;;
        esac
        break
    done

    newuser=""
    userpass=""
    if whiptail --title "$title" --yesno "Create a user account?" 8 50; then
        while :; do
            newuser=$(whiptail --title "$title" --inputbox "Username for the new account if (empty = skip):" 8 50 3>&1 1>&2 2>&3 || true)
            [ -z "$newuser" ] && break
            if [ "$newuser" = "root" ]; then
                whiptail --msgbox --title "$title" "root already exists choose another username" 8 40 || true
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
            if ! userpass=$(whiptail --title "$title" --passwordbox "Password for $newuser:" 8 40 3>&1 1>&2 2>&3); then
                newuser=""
                userpass=""
                break
            fi
            [ -n "$userpass" ] || { whiptail --msgbox --title "$title" "password can't be empty, try again" 8 40 || true; continue; }
            case "$userpass" in
                *:*|*$'\n'* )
                    whiptail --msgbox --title "$title" "password can't contain : or newline, try again" 8 50 || true
                    userpass=""
                    continue
                    ;;
            esac
            break
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
    want_de=""
    de_choice="none"
    dm_choice=""
    driver_choice="none"
    if [ "$INSTALL_MODE" != "online" ]; then
        :
    else
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
    fi

    want_swap=""
    if whiptail --title "$title" --yesno "Create a 1G swapfile" 8 40; then
        want_swap="1"
    fi
}
