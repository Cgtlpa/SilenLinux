# kernel firmware network and the rest of the payloads
install-modules() {
	mkdir -p "$ROOT_PATH"/lib/modules
	kernel_tar=""
	for f in /mnt/kernel-*.tar.*; do
		[[ -f "$f" ]] && kernel_tar="$f" && break
	done || true
	if [[ -n "$kernel_tar" ]]; then
		kname="$(basename "$kernel_tar")"
		bundle_kver="${kname#kernel-}"
		bundle_kver="${bundle_kver%%.tar.*}"
		if ! tar -xpf "$kernel_tar" -C "$ROOT_PATH" --no-same-owner --numeric-owner; then
			whiptail --msgbox --title "$title" "couldn't unpack the kernel/modules from the install medium. The system may not boot." 10 60 || true
		fi
	elif [[ -d /mnt/modules ]] && [[ -n "$(ls /mnt/modules 2>/dev/null)" ]]; then
		cp -a /mnt/modules/. "$ROOT_PATH"/lib/modules/ 2>/dev/null || true
	elif [[ -d /lib/modules ]]; then
		cp -a /lib/modules/. "$ROOT_PATH"/lib/modules/ 2>/dev/null || true
	fi
	if [[ -n "${bundle_kver:-}" ]] && [[ -d "$ROOT_PATH/lib/modules/$bundle_kver" ]]; then
		kver="$bundle_kver"
	else
		kver="$(ls "$ROOT_PATH"/lib/modules 2>/dev/null | head -n1)"
	fi
	if [[ -n "$kver" ]] && chroot "$ROOT_PATH" /bin/bash -c "command -v depmod" >/dev/null 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "depmod -a $kver" 2>/dev/null || true
	fi
	headers_tar=""
	for f in /mnt/headers-*.tar.*; do
		[[ -f "$f" ]] && headers_tar="$f" && break
	done || true
	if [[ -n "$headers_tar" ]]; then
		if tar -xpf "$headers_tar" -C "$ROOT_PATH" --no-same-owner --numeric-owner 2>/dev/null; then
			if [[ -n "${kver:-}" ]] && [[ -d "$ROOT_PATH/usr/src/linux-$kver" ]]; then
				mkdir -p "$ROOT_PATH"/lib/modules 2>/dev/null || true
				ln -sfn "/usr/src/linux-$kver" "$ROOT_PATH/lib/modules/$kver/build" 2>/dev/null || true
				ln -sfn "/usr/src/linux-$kver" "$ROOT_PATH/lib/modules/$kver/source" 2>/dev/null || true
			fi
		else
			whiptail --msgbox --title "$title" "couldn't unpack the kernel headers, nvidia module builds will fail until headers are provided" 9 60 || true
		fi
	fi
	if [[ -d /mnt/firmware ]] && [[ -n "$(ls /mnt/firmware 2>/dev/null)" ]]; then
		mkdir -p "$ROOT_PATH"/lib/firmware
		cp -a /mnt/firmware/. "$ROOT_PATH"/lib/firmware/ 2>/dev/null || true
	fi
	if [[ -d /lib/firmware ]]; then
		mkdir -p "$ROOT_PATH"/lib/firmware
		find /lib/firmware -mindepth 1 | while IFS= read -r _src; do
			_rel="${_src#/lib/firmware/}"
			[[ -n "$_rel" ]] || continue
			if [[ -e "$ROOT_PATH/lib/firmware/$_rel" ]]; then
				continue
			fi
			if [[ -d "$_src" ]]; then
				mkdir -p "$ROOT_PATH/lib/firmware/$_rel" 2>/dev/null || true
			else
				mkdir -p "$ROOT_PATH/lib/firmware/$(dirname "$_rel")" 2>/dev/null || true
				cp -a "$_src" "$ROOT_PATH/lib/firmware/$_rel" 2>/dev/null || true
			fi
		done || true
	fi
	mkdir -p "$ROOT_PATH"/etc/modprobe.d 2>/dev/null || true
	# rtw88 cards need this or they keep dropping
	cat > "$ROOT_PATH"/etc/modprobe.d/silen-rtw88.conf <<'EOF'
options rtw88_pci disable_aspm=Y
options rtw88_core disable_lps_deep=Y
EOF
	record-target-modules() {
		_mods="$1"
		_out="$2"
		[[ -n "${kver:-}" ]] || return 0
		_dep="$ROOT_PATH/lib/modules/$kver/modules.dep"
		[[ -f "$_dep" ]] || return 0
		_builtin="$ROOT_PATH/lib/modules/$kver/modules.builtin"
		mkdir -p "$ROOT_PATH"/etc/modules-load.d 2>/dev/null || true
		: > "$ROOT_PATH$_out" 2>/dev/null || true
		for _m in $_mods; do
			_n="$(printf '%s' "$_m" | tr '-' '_')"
			if [[ -f "$_builtin" ]] && grep -q "/$_n\.ko" "$_builtin" 2>/dev/null; then
				continue
			fi
			grep -q "/$_n\.ko" "$_dep" 2>/dev/null || continue
			printf '%s\n' "$_m" >> "$ROOT_PATH$_out" 2>/dev/null || true
		done || true
	}
	if [[ -f /etc/modules ]]; then
		_netmods="$(grep -E '^(cfg80211|mac80211|rfkill|iwlwifi|iwlmvm|iwlmld|iwldvm|iwlegacy|ipw2100|ipw2200|ath9k|ath5k|ath10k|ath11k|ath12k|ath6kl|carl9170|ar5523|wil6210|zd1211|mt7|mt76|rtw88|rtw89|rtl8|rtlwifi|rtl_pci|rtl_usb|brcmfmac|brcmsmac|b43|bcma|ssb|wl12xx|wl18xx|wlcore|wl1251|mwifiex|mwl8k|libertas|usb8xxx|p54|at76c50x|adm8211|rsi|wfx|wilc|rt2|rt3|rt6|rt7|virtio_net|e1000|e1000e|r8169|tg3|igb|ixgbe|r8152|ax88179_178a|cdc_ether|rndis_host|rndis_wlan|alx|8139too|via-rhine)' /etc/modules 2>/dev/null | sort -u | tr '\n' ' ' || true)"
		record-target-modules "$_netmods" /etc/modules-load.d/silen-net.conf
		if [[ -s "$ROOT_PATH/etc/modules-load.d/silen-net.conf" ]] && [[ -f "$ROOT_PATH/etc/conf.d/modules" ]]; then
			_wifi_mods="$(tr '\n' ' ' < "$ROOT_PATH/etc/modules-load.d/silen-net.conf" 2>/dev/null)"
			if [[ -n "$_wifi_mods" ]] && ! grep -q '^modules=' "$ROOT_PATH/etc/conf.d/modules" 2>/dev/null; then
				printf 'modules="%s"\n' "$_wifi_mods" >> "$ROOT_PATH/etc/conf.d/modules" 2>/dev/null || true
			fi
		fi
	fi
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add udev sysinit" >/dev/null 2>&1 || true
}

install-spk() {
	spk_src=""
	for f in /mnt/spk.tar.*; do
		[[ -f "$f" ]] && spk_src="$f" && break
	done || true
	if [[ -n "$spk_src" ]]; then
		_spk_tmp="$(mktemp -d /tmp/spk-install.XXXXXX 2>/dev/null || echo /tmp/spk-install.$$)"
		mkdir -p "$_spk_tmp" 2>/dev/null || true
		if tar -xpf "$spk_src" -C "$_spk_tmp" --no-same-owner --numeric-owner 2>/dev/null; then
			if [[ -x "$_spk_tmp/usr/bin/spk" ]]; then
				mkdir -p "$ROOT_PATH/usr/bin" 2>/dev/null || true
				cp "$_spk_tmp/usr/bin/spk" "$ROOT_PATH/usr/bin/spk" 2>/dev/null || true
				if [[ -d "$_spk_tmp/usr" ]]; then
					cp -a "$_spk_tmp/usr/." "$ROOT_PATH/usr/" 2>/dev/null || true
				fi
				chmod 0755 "$ROOT_PATH/usr/bin/spk" 2>/dev/null || true
				rm -rf "$_spk_tmp" 2>/dev/null || true
				[[ -x "$ROOT_PATH/usr/bin/spk" ]] && return
			else
				_found_spk="$(find "$_spk_tmp" -maxdepth 3 -name spk -type f -perm -u+x 2>/dev/null | head -n1)"
				[[ -z "$_found_spk" ]] && _found_spk="$(find "$_spk_tmp" -maxdepth 3 -name spk -type f 2>/dev/null | head -n1)"
				if [[ -n "$_found_spk" ]] && [[ -f "$_found_spk" ]]; then
					mkdir -p "$ROOT_PATH/usr/bin" 2>/dev/null || true
					if cp "$_found_spk" "$ROOT_PATH/usr/bin/spk" 2>/dev/null; then
						chmod 0755 "$ROOT_PATH/usr/bin/spk" 2>/dev/null || true
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
	if [[ -f /usr/bin/spk ]]; then
		if cp /usr/bin/spk "$ROOT_PATH"/usr/bin/spk 2>/dev/null; then
			return
		fi
		whiptail --msgbox --title "$title" "couldn't install live spk, trying other sources" 8 60 || true
	fi
	if [[ -f /mnt/spk ]]; then
		if cp /mnt/spk "$ROOT_PATH"/usr/bin/spk 2>/dev/null; then
			return
		fi
		whiptail --msgbox --title "$title" "couldn't install spk from medium, trying other sources" 8 60 || true
	fi
	if [[ -d /mnt/spk ]]; then
		if [[ -f /mnt/spk/spk ]]; then
			cp /mnt/spk/spk "$ROOT_PATH"/usr/bin/spk 2>/dev/null && return
		fi
		whiptail --msgbox --title "$title" "/mnt/spk is a directory, skipping it" 8 50 || true
	fi
	return
}

install-network() {
	net_tar=""
	for f in /mnt/network.tar.*; do
		[[ -f "$f" ]] && net_tar="$f" && break
	done || true
	if [[ -n "$net_tar" ]]; then
		if ! tar -xpf "$net_tar" -C "$ROOT_PATH" --skip-old-files --no-same-owner --numeric-owner 2>/dev/null; then
			if ! tar -xpf "$net_tar" -C "$ROOT_PATH" -k --no-same-owner --numeric-owner 2>/dev/null; then
				tar -xpf "$net_tar" -C "$ROOT_PATH" --no-same-owner --numeric-owner 2>/dev/null || \
					whiptail --msgbox --title "$title" "couldn't unpack the network bundle, trying the live files instead" 8 60 || true
			fi
		fi
	fi
	if [[ -z "$net_tar" ]] || [[ ! -x "$ROOT_PATH"/usr/libexec/iwd ]]; then
		install-network-from-live
	fi
	install-network-config
}

install-network-from-live() {
	net_missing=""
	mkdir -p "$ROOT_PATH"/usr/bin "$ROOT_PATH"/usr/libexec "$ROOT_PATH"/usr/lib "$ROOT_PATH"/usr/lib64
	for _b in iwd; do
		_src=""
		if [[ -e "/usr/libexec/$_b" ]] || [[ -L "/usr/libexec/$_b" ]]; then _src="/usr/libexec/$_b"; fi
		if [[ -z "$_src" ]] && { [[ -e "/usr/sbin/$_b" ]] || [[ -L "/usr/sbin/$_b" ]]; }; then
			_src="/usr/sbin/$_b"
		fi
		if [[ -z "$_src" ]] && { [[ -e "/usr/bin/$_b" ]] || [[ -L "/usr/bin/$_b" ]]; }; then
			_src="/usr/bin/$_b"
		fi
		if [[ -z "$_src" ]]; then
			net_missing="$net_missing $_b"
			continue
		fi
		cp -a "$_src" "$ROOT_PATH"/usr/libexec/ 2>/dev/null || net_missing="$net_missing $_b"
	done || true
	[[ -e "$ROOT_PATH/usr/libexec/iwd" ]] && ln -sf /usr/libexec/iwd "$ROOT_PATH"/usr/bin/iwd 2>/dev/null || true
	for _b in iwctl iwmon dbus-daemon dbus-uuidgen; do
		_src=""
		if [[ -e "/usr/bin/$_b" ]] || [[ -L "/usr/bin/$_b" ]]; then _src="/usr/bin/$_b"; fi
		if [[ -z "$_src" ]] && { [[ -e "/usr/sbin/$_b" ]] || [[ -L "/usr/sbin/$_b" ]]; }; then
			_src="/usr/sbin/$_b"
		fi
		if [[ -z "$_src" ]]; then
			net_missing="$net_missing $_b"
			continue
		fi
		cp -a "$_src" "$ROOT_PATH"/usr/bin/ 2>/dev/null || net_missing="$net_missing $_b"
	done || true
	for _b in rfkill iw ip efibootmgr; do
		_src=""
		if [[ -e "/usr/bin/$_b" ]] || [[ -L "/usr/bin/$_b" ]]; then _src="/usr/bin/$_b"; fi
		if [[ -z "$_src" ]] && { [[ -e "/usr/sbin/$_b" ]] || [[ -L "/usr/sbin/$_b" ]]; }; then
			_src="/usr/sbin/$_b"
		fi
		if [[ -z "$_src" ]] && { [[ -e "/sbin/$_b" ]] || [[ -L "/sbin/$_b" ]]; }; then
			_src="/sbin/$_b"
		fi
		if [[ -z "$_src" ]] && { [[ -e "/bin/$_b" ]] || [[ -L "/bin/$_b" ]]; }; then
			_src="/bin/$_b"
		fi
		[[ -z "$_src" ]] && continue
		cp -a "$_src" "$ROOT_PATH"/usr/bin/ 2>/dev/null || true
	done || true
	if command -v ldd >/dev/null 2>&1; then
		for _b in "$ROOT_PATH"/usr/bin/* "$ROOT_PATH"/usr/libexec/*; do
			[[ -f "$_b" ]] || [[ -L "$_b" ]] || continue
			for _lib in $(ldd "$_b" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true); do
				[[ -e "$_lib" ]] || continue
				_bn="$(basename "$_lib")"
				if [[ -e "$ROOT_PATH/usr/lib64/$_bn" ]] || [[ -e "$ROOT_PATH/usr/lib/$_bn" ]]; then
					continue
				fi
				cp -a "$_lib" "$ROOT_PATH"/usr/lib64/ 2>/dev/null || true
			done || true
		done || true
	else
		for _lib in /usr/lib64/*; do
			[[ -e "$_lib" ]] || [[ -L "$_lib" ]] || continue
			[[ -f "$_lib" ]] || [[ -L "$_lib" ]] || continue
			_bn="$(basename "$_lib")"
			if [[ -e "$ROOT_PATH/usr/lib64/$_bn" ]] || [[ -e "$ROOT_PATH/usr/lib/$_bn" ]]; then
				continue
			fi
			cp -a "$_lib" "$ROOT_PATH"/usr/lib64/ 2>/dev/null || true
		done || true
	fi
	if [[ -f /usr/share/dbus-1/system.d/iwd-dbus.conf ]]; then
		mkdir -p "$ROOT_PATH"/usr/share/dbus-1/system.d 2>/dev/null || true
		cp /usr/share/dbus-1/system.d/iwd-dbus.conf "$ROOT_PATH"/usr/share/dbus-1/system.d/ 2>/dev/null || true
	fi
}

install-network-config() {
	mkdir -p "$ROOT_PATH"/etc/iwd \
			"$ROOT_PATH"/usr/share/dbus-1/system.d \
			"$ROOT_PATH"/run/dbus \
			"$ROOT_PATH"/run/user \
			"$ROOT_PATH"/var/lib/iwd "$ROOT_PATH"/var/lib/dbus \
			"$ROOT_PATH"/etc/init.d
	chmod 755 "$ROOT_PATH"/run/user 2>/dev/null || true
	mkdir -p "$ROOT_PATH/usr/lib/tmpfiles.d" 2>/dev/null || true
	printf 'd /run/dbus 0755 root root -\n' > "$ROOT_PATH/usr/lib/tmpfiles.d/silen-network.conf" 2>/dev/null || true
	if [[ -f /etc/iwd/main.conf ]]; then
		cp /etc/iwd/main.conf "$ROOT_PATH"/etc/iwd/main.conf 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH"/etc/iwd/main.conf ]]; then
		cat > "$ROOT_PATH"/etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true
EOF
	fi
	if [[ ! -f "$ROOT_PATH"/usr/share/dbus-1/system.d/iwd-dbus.conf ]] && [[ -f /usr/share/dbus-1/system.d/iwd-dbus.conf ]]; then
		cp /usr/share/dbus-1/system.d/iwd-dbus.conf "$ROOT_PATH"/usr/share/dbus-1/system.d/ 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH"/usr/share/dbus-1/system.conf ]] && [[ -f /usr/share/dbus-1/system.conf ]]; then
		cp /usr/share/dbus-1/system.conf "$ROOT_PATH"/usr/share/dbus-1/system.conf 2>/dev/null || true
	fi
	if [[ -f "$ROOT_PATH/usr/share/dbus-1/system.conf" ]]; then
		if ! grep -q '<fork/>' "$ROOT_PATH/usr/share/dbus-1/system.conf" 2>/dev/null; then
			sed -i 's|<busconfig>|<busconfig>\n\n  <fork/>|' \
				"$ROOT_PATH/usr/share/dbus-1/system.conf" 2>/dev/null || true
		fi
		if ! grep -q '<pidfile>' "$ROOT_PATH/usr/share/dbus-1/system.conf" 2>/dev/null; then
			sed -i 's|<fork/>|<fork/>\n\n  <pidfile>/run/dbus/pid</pidfile>|' \
				"$ROOT_PATH/usr/share/dbus-1/system.conf" 2>/dev/null || true
		fi
	fi
	if [[ ! -e "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper ]]; then
		if [[ -e /usr/lib/dbus-daemon-launch-helper ]]; then
			cp -a /usr/lib/dbus-daemon-launch-helper "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
		elif [[ -e /usr/libexec/dbus-daemon-launch-helper ]]; then
			cp -a /usr/libexec/dbus-daemon-launch-helper "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
		fi
	fi
	if [[ -e "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper ]]; then
		# dbus helper needs setuid or wifi stays broken
		chown root:root "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
		chmod 4755 "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper 2>/dev/null || true
	fi
	if [[ -e "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper ]] && [[ ! -e "$ROOT_PATH"/usr/libexec/dbus-daemon-launch-helper ]]; then
		mkdir -p "$ROOT_PATH"/usr/libexec 2>/dev/null || true
		cp -a "$ROOT_PATH"/usr/lib/dbus-daemon-launch-helper "$ROOT_PATH"/usr/libexec/dbus-daemon-launch-helper 2>/dev/null || true
	fi
	if [[ -f /usr/bin/silen-wifi-check ]]; then
		mkdir -p "$ROOT_PATH"/usr/local/bin 2>/dev/null || true
		cp /usr/bin/silen-wifi-check "$ROOT_PATH"/usr/local/bin/silen-wifi-check 2>/dev/null || true
		chmod 0755 "$ROOT_PATH"/usr/local/bin/silen-wifi-check 2>/dev/null || true
	fi
	if [[ -f /usr/bin/silen-nvidia-check ]]; then
		mkdir -p "$ROOT_PATH"/usr/local/bin 2>/dev/null || true
		cp /usr/bin/silen-nvidia-check "$ROOT_PATH"/usr/local/bin/silen-nvidia-check 2>/dev/null || true
		chmod 0755 "$ROOT_PATH"/usr/local/bin/silen-nvidia-check 2>/dev/null || true
	fi
	chroot "$ROOT_PATH" /bin/bash -c "ldconfig" 2>/dev/null || true
	_mid=""
	if [[ -x "$ROOT_PATH/usr/bin/dbus-uuidgen" ]]; then
		_mid="$(chroot "$ROOT_PATH" /usr/bin/dbus-uuidgen --get 2>/dev/null || true)"
	fi
	[[ -z "$_mid" ]] && _mid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || true)"
	if [[ -n "$_mid" ]]; then
		echo "$_mid" > "$ROOT_PATH"/etc/machine-id 2>/dev/null || true
		cp "$ROOT_PATH"/etc/machine-id "$ROOT_PATH"/var/lib/dbus/machine-id 2>/dev/null || true
	fi
	cat > "$ROOT_PATH"/etc/init.d/dbus <<'EOF'
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
	_iwd_cmd=/usr/libexec/iwd
	[[ -x "$ROOT_PATH"/usr/libexec/iwd ]] || _iwd_cmd=/usr/sbin/iwd
	[[ -x "$ROOT_PATH$_iwd_cmd" ]] || _iwd_cmd=/usr/bin/iwd
	cat > "$ROOT_PATH"/etc/init.d/iwd <<EOF
#!/sbin/openrc-run
command=$_iwd_cmd
pidfile=/run/iwd.pid
command_background="yes"
name="iwd wireless daemon"

depend() {
	need dbus localmount
	after bootmisc modules
	provide net
}

start_pre() {
	mkdir -p /var/lib/iwd 2>/dev/null || true
	if command -v rfkill >/dev/null 2>&1; then
		rfkill unblock all >/dev/null 2>&1 || true
	fi
}
EOF
	chmod 755 "$ROOT_PATH"/etc/init.d/dbus "$ROOT_PATH"/etc/init.d/iwd
	mkdir -p "$ROOT_PATH"/etc/local.d 2>/dev/null || true
	cat > "$ROOT_PATH"/etc/local.d/wifi-unblock.start <<'EOF'
#!/bin/sh
if command -v rfkill >/dev/null 2>&1; then
	rfkill unblock all >/dev/null 2>&1 || true
fi
EOF
	chmod 0755 "$ROOT_PATH"/etc/local.d/wifi-unblock.start 2>/dev/null || true
	cat > "$ROOT_PATH"/etc/local.d/dns-fallback.start <<'EOF'
#!/bin/sh
if grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
	rm -f /etc/resolv.conf 2>/dev/null || true
fi
if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
	printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > /etc/resolv.conf 2>/dev/null || true
	chmod 644 /etc/resolv.conf 2>/dev/null || true
fi
EOF
	chmod 0755 "$ROOT_PATH"/etc/local.d/dns-fallback.start 2>/dev/null || true
	_net_broken=""
	for _bin in /usr/bin/dbus-daemon /usr/bin/iwctl /usr/bin/iwmon; do
		if [[ -x "$ROOT_PATH$_bin" ]] && ! chroot "$ROOT_PATH" "${_bin#/usr/bin/}" --help >/dev/null 2>&1; then
			_net_broken="$_net_broken ${_bin##*/}"
		fi
	done || true
	if [[ -x "$ROOT_PATH/usr/libexec/iwd" ]] && ! chroot "$ROOT_PATH" /usr/libexec/iwd --version >/dev/null 2>&1; then
		_net_broken="$_net_broken iwd"
	fi
	if [[ -n "$_net_broken" ]]; then
		whiptail --msgbox --title "$title" "Network tools copied but fail to run in the new system missing libraries $_net_broken Wi-Fi may not work after reboot run silen-wifi-check then" 10 65 || true
	fi
	_rc_ok="1"
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add dbus default" >/dev/null 2>&1 || _rc_ok=""
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add iwd default" >/dev/null 2>&1 || _rc_ok=""
	if [[ -x "$ROOT_PATH"/usr/bin/dhcpcd ]] || [[ -x "$ROOT_PATH"/sbin/dhcpcd ]]; then
		chroot "$ROOT_PATH" /bin/bash -c "rc-update add dhcpcd default" >/dev/null 2>&1 || true
	fi
	if [[ -f "$ROOT_PATH"/etc/dhcpcd.conf ]] && ! grep -q 'denyinterfaces wlan' "$ROOT_PATH"/etc/dhcpcd.conf 2>/dev/null; then
		printf '\ndenyinterfaces wlan* wlp*\n' >> "$ROOT_PATH"/etc/dhcpcd.conf 2>/dev/null || true
	fi
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add modules boot" >/dev/null 2>&1 || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add local default" >/dev/null 2>&1 || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update del wpa_supplicant default" >/dev/null 2>&1 || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update del NetworkManager default" >/dev/null 2>&1 || true
	rm -f "$ROOT_PATH"/etc/runlevels/*/net.* 2>/dev/null || true
	if [[ -z "$_rc_ok" ]]; then
		whiptail --msgbox --title "$title" "iwd was copied but couldn't be enabled; after reboot run: rc-update add dbus default; rc-update add iwd default; for wired also: rc-update add dhcpcd default" 9 70 || true
	fi
}

# installs the driver after reboot on nvidia machines
install-nvidia-auto() {
	[[ -f /mnt/nvidia-auto ]] || return 0
	_nv_run=""
	for f in /mnt/nvidia-*.run; do
		[[ -f "$f" ]] && _nv_run="$f" && break
	done || true
	if [[ -z "$_nv_run" ]]; then
		whiptail --msgbox --title "$title" "nvidia variant flag found but no nvidia-*.run on the medium, continuing with nouveau" 8 60 || true
		return 0
	fi
	_has_nv="0"
	for d in /sys/bus/pci/devices/*; do
		[[ -f "$d/vendor" ]] || continue
		[[ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ]] || continue
		case "$(cat "$d/class" 2>/dev/null)" in
			0x03*) _has_nv="1" && break ;;
		esac
	done || true
	if [[ "$_has_nv" != "1" ]]; then
		whiptail --msgbox --title "$title" "no NVIDIA GPU found, skipping the proprietary driver (nouveau stays active)" 8 60 || true
		return 0
	fi
	_kver="${kver:-$(ls "$ROOT_PATH"/lib/modules 2>/dev/null | head -n1)}"
	if [[ -z "$_kver" ]] || [[ ! -f "$ROOT_PATH/usr/src/linux-$_kver/Makefile" ]]; then
		whiptail --msgbox --title "$title" "kernel headers missing in the new system, skipping the NVIDIA driver (nouveau stays active)" 8 60 || true
		return 0
	fi
	mkdir -p "$ROOT_PATH"/etc/modprobe.d 2>/dev/null || true
	printf 'blacklist nouveau\noptions nouveau modeset=0\n' > "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
	_nv_kmods=""
	for f in /mnt/nvidia-kmods-*.tar.*; do
		[[ -f "$f" ]] && _nv_kmods="$f" && break
	done || true
	if [[ -z "$_nv_kmods" ]]; then
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "no prebuilt NVIDIA driver on the medium for this kernel, continuing with nouveau" 8 60 || true
		return 0
	fi
	_km_base="$(basename "$_nv_kmods")"
	_km_kver="${_km_base#nvidia-kmods-}"
	_km_kver="${_km_kver%%.tar.*}"
	if [[ "$_km_kver" != "$_kver" ]]; then
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "prebuilt NVIDIA driver is for $_km_kver but the system is $_kver, continuing with nouveau" 8 60 || true
		return 0
	fi
	whiptail --infobox "Installing the NVIDIA driver into the new system..." 8 60 2>/dev/null || true
	if ! tar -xpf "$_nv_kmods" -C "$ROOT_PATH" --no-same-owner --numeric-owner 2>/dev/null; then
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "couldn't unpack the prebuilt NVIDIA driver, continuing with nouveau" 8 60 || true
		return 0
	fi
	chroot "$ROOT_PATH" /bin/bash -c "depmod -a $_kver" 2>/dev/null || true
	if [[ ! -f "$ROOT_PATH/lib/modules/$_kver/updates/nvidia.ko" ]] && ! find "$ROOT_PATH"/lib/modules -iname 'nvidia.ko*' 2>/dev/null | grep -q .; then
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "prebuilt NVIDIA modules missing after unpack, continuing with nouveau" 8 60 || true
		return 0
	fi
	if ! cp "$_nv_run" "$ROOT_PATH/tmp/nvidia.run" 2>/dev/null; then
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "couldn't stage the NVIDIA installer (disk full?), continuing with nouveau" 8 60 || true
		return 0
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "sh /tmp/nvidia.run --silent --accept-license --no-questions -z --no-x-check --no-dkms --no-systemd --no-distro-scripts --no-kernel-modules" >>"$ROOT_PATH/tmp/nvidia-install.log" 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "depmod -a $_kver" 2>/dev/null || true
		cp "$ROOT_PATH/tmp/nvidia-install.log" /tmp/nvidia-install.log 2>/dev/null || true
		mkdir -p "$ROOT_PATH/var/log" 2>/dev/null || true
		cp "$ROOT_PATH/tmp/nvidia-install.log" "$ROOT_PATH/var/log/nvidia-install.log" 2>/dev/null || true
		mkdir -p "$ROOT_PATH/usr/src" 2>/dev/null || true
		cp "$_nv_run" "$ROOT_PATH/usr/src/$(basename "$_nv_run")" 2>/dev/null || true
	else
		cp "$ROOT_PATH/tmp/nvidia-install.log" /tmp/nvidia-install.log 2>/dev/null || true
		mkdir -p "$ROOT_PATH/var/log" 2>/dev/null || true
		cp "$ROOT_PATH/tmp/nvidia-install.log" "$ROOT_PATH/var/log/nvidia-install.log" 2>/dev/null || true
		rm -f "$ROOT_PATH"/etc/modprobe.d/nvidia-disable-nouveau.conf "$ROOT_PATH"/etc/modprobe.d/nvidia-installer-disable-nouveau.conf 2>/dev/null || true
		whiptail --msgbox --title "$title" "NVIDIA driver install failed (live: /tmp/nvidia-install.log, installed: /var/log/nvidia-install.log), continuing with nouveau" 8 70 || true
	fi
	rm -f "$ROOT_PATH/tmp/nvidia.run" 2>/dev/null || true
}

install-desktop() {
	desktop_tar=""
	for f in /mnt/desktop.tar.*; do
		[[ -f "$f" ]] && desktop_tar="$f" && break
	done || true
	if [[ -n "$desktop_tar" ]]; then
		whiptail --infobox "Installing the system this might take a while...\n(unpacking desktop)" 8 60 2>/dev/null || true
		tar -xpf "$desktop_tar" -C "$ROOT_PATH" --no-same-owner --numeric-owner 2>/dev/null || \
			whiptail --msgbox --title "$title" "couldn't unpack the desktop bundle, continuing without it" 8 60 || true
	fi
	if [[ -x "$ROOT_PATH/usr/bin/spk" ]] || chroot "$ROOT_PATH" /bin/bash -c "command -v spk" >/dev/null 2>&1; then
		whiptail --infobox "Installing the system this might take a while...\n(fetching desktop packages, needs network)" 8 60 2>/dev/null || true
		chroot "$ROOT_PATH" /bin/bash -c "spk get instantwm instantmenu xorg-server xorg-libs xkb-data dejavu kitty" 2>/dev/null || \
			whiptail --msgbox --title "$title" "desktop packages had errors (offline?), continuing with what unpacked" 8 60 || true
	fi
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add seatd default" >/dev/null 2>&1 || true
}
