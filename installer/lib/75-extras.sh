install-extras() {
	install-busybox-tools
	install-log-services
	install-ntp-service
	install-bootlogd
	install-efibootmgr
	install-fstrim-service
	build-microcode-image
	compute-resume-params
	build-installed-initramfs
}

install-busybox-tools() {
	local bb="" c
	for c in /bin/busybox /usr/bin/busybox; do
		if [[ -x "$c" ]]; then
			bb="$c"
			break
		fi
	done
	[[ -n "$bb" ]] || return 0
	mkdir -p "$ROOT_PATH"/bin "$ROOT_PATH"/usr/bin 2>/dev/null || true
	if ! cp "$bb" "$ROOT_PATH"/bin/busybox 2>/dev/null; then
		return 0
	fi
	chmod 0755 "$ROOT_PATH"/bin/busybox 2>/dev/null || true
	for c in syslogd klogd ntpd; do
		if [[ -e "$ROOT_PATH"/usr/bin/"$c" ]] && [[ ! -L "$ROOT_PATH"/usr/bin/"$c" ]]; then
			continue
		fi
		if [[ -e "$ROOT_PATH"/sbin/"$c" ]] && [[ ! -L "$ROOT_PATH"/sbin/"$c" ]]; then
			continue
		fi
		ln -sf /bin/busybox "$ROOT_PATH"/usr/bin/"$c" 2>/dev/null || true
	done
	return 0
}

install-log-services() {
	mkdir -p "$ROOT_PATH"/etc/init.d "$ROOT_PATH"/var/log 2>/dev/null || true
	if [[ ! -e "$ROOT_PATH"/var/log/btmp ]]; then
		: > "$ROOT_PATH"/var/log/btmp 2>/dev/null || true
		chmod 0600 "$ROOT_PATH"/var/log/btmp 2>/dev/null || true
		chown root:utmp "$ROOT_PATH"/var/log/btmp 2>/dev/null || true
	fi
	[[ -e "$ROOT_PATH"/usr/bin/syslogd ]] || return 0
	cat > "$ROOT_PATH"/etc/init.d/syslogd <<'EOF'
#!/sbin/openrc-run

description="busybox system logger"

supervisor="supervise-daemon"
command="/usr/bin/syslogd"
command_args="-n -L -O /var/log/messages -s 4096"
respawn_delay=5
respawn_period=60

depend() {
	need localmount
	after bootmisc
	provide logger
}
EOF
	cat > "$ROOT_PATH"/etc/init.d/klogd <<'EOF'
#!/sbin/openrc-run

description="busybox kernel logger"

supervisor="supervise-daemon"
command="/usr/bin/klogd"
command_args="-n"
respawn_delay=5
respawn_period=60

depend() {
	need localmount syslogd
	after bootmisc
}
EOF
	chmod 0755 "$ROOT_PATH"/etc/init.d/syslogd "$ROOT_PATH"/etc/init.d/klogd 2>/dev/null || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add syslogd boot" >/dev/null 2>&1 || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add klogd boot" >/dev/null 2>&1 || true
}

install-ntp-service() {
	[[ -e "$ROOT_PATH"/usr/bin/ntpd ]] || return 0
	cat > "$ROOT_PATH"/etc/init.d/ntpd <<'EOF'
#!/sbin/openrc-run

description="busybox NTP client"

supervisor="supervise-daemon"
command="/usr/bin/ntpd"
command_args="-n -p pool.ntp.org -p time.cloudflare.com"
respawn_delay=30
respawn_delay_cap=120
respawn_max=0

depend() {
	need localmount
	after bootmisc dhcpcd iwd
}
EOF
	chmod 0755 "$ROOT_PATH"/etc/init.d/ntpd 2>/dev/null || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add ntpd default" >/dev/null 2>&1 || true
}

install-bootlogd() {
	[[ -e "$ROOT_PATH"/usr/bin/bootlogd ]] || return 0
	if [[ -f "$ROOT_PATH"/etc/conf.d/bootlogd ]]; then
		sed -i 's|^#\?BOOTLOGD_ARGS=.*|BOOTLOGD_ARGS="-l /var/log/boot"|' "$ROOT_PATH"/etc/conf.d/bootlogd 2>/dev/null || true
	else
		printf 'BOOTLOGD_ARGS="-l /var/log/boot"\n' > "$ROOT_PATH"/etc/conf.d/bootlogd 2>/dev/null || true
	fi
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add bootlogd boot" >/dev/null 2>&1 || true
}

install-efibootmgr() {
	local src="" lib bn
	[[ -x "$ROOT_PATH"/usr/bin/efibootmgr ]] && return 0
	for src in /usr/bin/efibootmgr /usr/sbin/efibootmgr /sbin/efibootmgr /bin/efibootmgr; do
		[[ -x "$src" ]] && break
		src=""
	done
	[[ -n "$src" ]] || return 0
	mkdir -p "$ROOT_PATH"/usr/bin "$ROOT_PATH"/usr/lib64 2>/dev/null || true
	cp -a "$src" "$ROOT_PATH"/usr/bin/efibootmgr 2>/dev/null || return 0
	if command -v ldd >/dev/null 2>&1; then
		for lib in $(ldd "$src" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true); do
			[[ -e "$lib" ]] || continue
			bn="$(basename "$lib")"
			if [[ -e "$ROOT_PATH/usr/lib64/$bn" ]] || [[ -e "$ROOT_PATH/usr/lib/$bn" ]]; then
				continue
			fi
			cp -a "$lib" "$ROOT_PATH"/usr/lib64/ 2>/dev/null || true
		done || true
		chroot "$ROOT_PATH" /bin/bash -c "ldconfig" >/dev/null 2>&1 || true
	fi
	return 0
}

install-fstrim-service() {
	[[ -x "$ROOT_PATH"/usr/bin/fstrim ]] || return 0
	mkdir -p "$ROOT_PATH"/var/lib/silen 2>/dev/null || true
	cat > "$ROOT_PATH"/etc/init.d/fstrim <<'EOF'
#!/sbin/openrc-run

description="periodic fstrim for mounted filesystems"

depend() {
	need localmount
	after bootmisc
}

start() {
	local stamp="/var/lib/silen/fstrim.stamp"
	local now last
	now="$(date +%s 2>/dev/null || echo 0)"
	last=0
	if [ -f "$stamp" ]; then
		last="$(cat "$stamp" 2>/dev/null || echo 0)"
	fi
	case "$last" in
		''|*[!0-9]*) last=0 ;;
	esac
	if [ "$((now - last))" -lt 604800 ]; then
		return 0
	fi
	ebegin "Trimming filesystems"
	fstrim -av >> /var/log/fstrim.log 2>&1
	eend 0
	mkdir -p /var/lib/silen 2>/dev/null || true
	printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
	return 0
}
EOF
	chmod 0755 "$ROOT_PATH"/etc/init.d/fstrim 2>/dev/null || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add fstrim default" >/dev/null 2>&1 || true
}

build-microcode-image() {
	local dir="" intel="" amd="" wd="" size_kb="" need_kb="" avail_kb=""
	local img="$ROOT_PATH/boot/silen-ucode.img"
	for dir in /mnt/firmware /usr/lib/firmware /lib/firmware; do
		if [[ -d "$dir/intel-ucode" ]] || [[ -d "$dir/amd-ucode" ]]; then
			if [[ -d "$dir/intel-ucode" ]]; then
				intel="$dir/intel-ucode"
			fi
			if [[ -d "$dir/amd-ucode" ]]; then
				amd="$dir/amd-ucode"
			fi
			break
		fi
	done
	[[ -n "$intel" ]] || [[ -n "$amd" ]] || return 0
	[[ -x /bin/busybox ]] || return 0
	wd="/tmp/ucode.$$"
	mkdir -p "$wd/kernel/x86/microcode" 2>/dev/null || return 0
	if [[ -n "$intel" ]]; then
		cat "$intel"/* > "$wd/kernel/x86/microcode/GenuineIntel.bin" 2>/dev/null || true
	fi
	if [[ -n "$amd" ]]; then
		cat "$amd"/* > "$wd/kernel/x86/microcode/AuthenticAMD.bin" 2>/dev/null || true
	fi
	if [[ ! -s "$wd/kernel/x86/microcode/GenuineIntel.bin" ]] && [[ ! -s "$wd/kernel/x86/microcode/AuthenticAMD.bin" ]]; then
		rm -rf "$wd" 2>/dev/null || true
		return 0
	fi
	mkdir -p "$ROOT_PATH"/boot 2>/dev/null || { rm -rf "$wd" 2>/dev/null || true; return 0; }
	if ( cd "$wd" && find kernel -type f | /bin/busybox cpio -o -H newc > "$wd/ucode.img" 2>/dev/null ) && [[ -s "$wd/ucode.img" ]]; then
		size_kb=$(( $(wc -c < "$wd/ucode.img") / 1024 ))
		need_kb=$(( size_kb + 8192 ))
		avail_kb="$(df -Pk "$ROOT_PATH"/boot 2>/dev/null | awk 'NR == 2 { print $4 }')"
		case "$avail_kb" in
			''|*[!0-9]*) avail_kb=0 ;;
		esac
		if [[ "$avail_kb" -gt "$need_kb" ]]; then
			cp -f "$wd/ucode.img" "$img" 2>/dev/null || true
			if [[ -s "$img" ]]; then
				ucode_img="silen-ucode.img"
			fi
		fi
	fi
	rm -rf "$wd" 2>/dev/null || true
	return 0
}

compute-resume-params() {
	resume_param=""
	[[ -n "$made_swapfile" ]] || return 0
	[[ "$fstype" = "ext4" ]] || return 0
	[[ -n "$rootuuid" ]] || return 0
	[[ -f "$ROOT_PATH"/swapfile ]] || return 0
	local off=""
	off="$(chroot "$ROOT_PATH" /usr/bin/filefrag -v /swapfile 2>/dev/null | awk '$1 == "0:" { print $4; exit }' | tr -d '.' 2>/dev/null || true)"
	case "$off" in
		''|*[!0-9]*) return 0 ;;
	esac
	resume_param=" resume=UUID=$rootuuid resume_offset=$off"
	return 0
}

build-installed-initramfs() {
	local log="/tmp/silen-mkinitramfs.log"
	[[ -x "$ROOT_PATH/usr/local/bin/silen-mkinitramfs" ]] || return 0
	whiptail --infobox "Building the boot initramfs..." 8 60 2>/dev/null || true
	if chroot "$ROOT_PATH" /usr/local/bin/silen-mkinitramfs >"$log" 2>&1; then
		cp "$log" /tmp/mkinitramfs.log 2>/dev/null || true
		return 0
	fi
	cp "$log" /tmp/mkinitramfs.log 2>/dev/null || true
	whiptail --msgbox --title "$title" "couldn't build the boot initramfs, using the live one instead. After reboot run silen-mkinitramfs as root before the next kernel update. Details: /tmp/mkinitramfs.log" 10 70 || true
	return 0
}
