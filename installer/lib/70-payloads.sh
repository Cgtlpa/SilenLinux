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
        _spk_tmp="$(mktemp -d /tmp/spk-install.XXXXXX 2>/dev/null || echo /tmp/spk-install.$$)"
        mkdir -p "$_spk_tmp" 2>/dev/null || true
        if tar -xpf "$spk_src" -C "$_spk_tmp" --no-same-owner --numeric-owner 2>/dev/null; then
            if [ -x "$_spk_tmp/usr/bin/spk" ]; then
                mkdir -p "$root/usr/bin" 2>/dev/null || true
                cp "$_spk_tmp/usr/bin/spk" "$root/usr/bin/spk" 2>/dev/null || true
                if [ -d "$_spk_tmp/usr" ]; then
                    cp -a "$_spk_tmp/usr/." "$root/usr/" 2>/dev/null || true
                fi
                chmod 0755 "$root/usr/bin/spk" 2>/dev/null || true
                rm -rf "$_spk_tmp" 2>/dev/null || true
                [ -x "$root/usr/bin/spk" ] && return
            else
                _found_spk="$(find "$_spk_tmp" -maxdepth 3 -name spk -type f -perm -u+x 2>/dev/null | head -n1)"
                [ -z "$_found_spk" ] && _found_spk="$(find "$_spk_tmp" -maxdepth 3 -name spk -type f 2>/dev/null | head -n1)"
                if [ -n "$_found_spk" ] && [ -f "$_found_spk" ]; then
                    mkdir -p "$root/usr/bin" 2>/dev/null || true
                    if cp "$_found_spk" "$root/usr/bin/spk" 2>/dev/null; then
                        chmod 0755 "$root/usr/bin/spk" 2>/dev/null || true
                        rm -rf "$_spk_tmp" 2>/dev/null || true
                        return
                    fi
                fi
                rm -rf "$_spk_tmp" 2>/dev/null || true
            fi
        else
            rm -rf "$_spk_tmp" 2>/dev/null || true
        fi
        whiptail --msgbox --title "$title" "couldn't unpack $spk_src, trying other spk sources" 8 60 || true
        spk_src=""
    fi
    if [ -f /usr/bin/spk ]; then
        if cp /usr/bin/spk "$root"/usr/bin/spk 2>/dev/null; then
            return
        fi
        whiptail --msgbox --title "$title" "couldn't install live spk, trying other sources" 8 60 || true
    fi
    if [ -f /mnt/spk ]; then
        if cp /mnt/spk "$root"/usr/bin/spk 2>/dev/null; then
            return
        fi
        whiptail --msgbox --title "$title" "couldn't install spk from medium, trying other sources" 8 60 || true
    fi
    if [ -d /mnt/spk ]; then
        if [ -f /mnt/spk/spk ]; then
            cp /mnt/spk/spk "$root"/usr/bin/spk 2>/dev/null && return
        fi
        whiptail --msgbox --title "$title" "/mnt/spk is a directory, skipping it" 8 50 || true
    fi
    if [ "$INSTALL_MODE" != "online" ]; then
        return
    fi
    url=$(whiptail --title "$title" --inputbox "spk not found, enter a git url to clone it (leave empty to skip):" 8 46 3>&1 1>&2 2>&3 || true)
    if [ -n "$url" ]; then
        rm -rf /tmp/spk 2>/dev/null || true
        if ! git clone -- "$url" /tmp/spk 2>/dev/null; then
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
    if command -v ldd >/dev/null 2>&1; then
        for _b in "$root"/usr/bin/*; do
            [ -f "$_b" ] || [ -L "$_b" ] || continue
            for _lib in $(ldd "$_b" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true); do
                [ -e "$_lib" ] || continue
                _bn="$(basename "$_lib")"
                if [ -e "$root/usr/lib64/$_bn" ] || [ -e "$root/usr/lib/$_bn" ]; then
                    continue
                fi
                cp -a "$_lib" "$root"/usr/lib64/ 2>/dev/null || true
            done || true
        done || true
    else
        for _lib in /usr/lib64/*; do
            [ -e "$_lib" ] || [ -L "$_lib" ] || continue
            [ -f "$_lib" ] || [ -L "$_lib" ] || continue
            _bn="$(basename "$_lib")"
            if [ -e "$root/usr/lib64/$_bn" ] || [ -e "$root/usr/lib/$_bn" ]; then
                continue
            fi
            cp -a "$_lib" "$root"/usr/lib64/ 2>/dev/null || true
        done || true
    fi
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
