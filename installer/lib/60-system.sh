# perms and users and services on the new system
fix-permissions() {
	if [[ ! -e "$ROOT_PATH/bin/bash" ]]; then
		ln -sf /usr/bin/bash "$ROOT_PATH/bin/bash" 2>/dev/null || true
	fi
	if [[ ! -e "$ROOT_PATH/bin/sh" ]]; then
		ln -sf bash "$ROOT_PATH/bin/sh" 2>/dev/null || true
	fi
	if [[ ! -e "$ROOT_PATH/bin/login" ]]; then
		ln -sf /usr/bin/login "$ROOT_PATH/bin/login" 2>/dev/null || true
	fi
	for _s in bin/su usr/bin/su \
			bin/passwd usr/bin/passwd \
			usr/bin/chage usr/bin/chfn usr/bin/chsh \
			usr/bin/gpasswd usr/bin/newgrp \
			bin/mount usr/bin/mount bin/umount usr/bin/umount \
			usr/bin/sudo bin/sudo usr/bin/sudoedit bin/sudoedit; do
		if [[ -e "$ROOT_PATH/$_s" ]] && [[ ! -L "$ROOT_PATH/$_s" ]]; then
			chown root:root "$ROOT_PATH/$_s" 2>/dev/null || true
			chmod 4755 "$ROOT_PATH/$_s" 2>/dev/null || true
		fi
	done || true
	for _u in bin/unix_chkpwd usr/bin/unix_chkpwd sbin/unix_chkpwd usr/sbin/unix_chkpwd; do
		if [[ -e "$ROOT_PATH/$_u" ]] && [[ ! -L "$ROOT_PATH/$_u" ]]; then
			chown root:shadow "$ROOT_PATH/$_u" 2>/dev/null || chown root:root "$ROOT_PATH/$_u" 2>/dev/null || true
			chmod 4755 "$ROOT_PATH/$_u" 2>/dev/null || chmod 2711 "$ROOT_PATH/$_u" 2>/dev/null || true
		fi
	done || true
	if [[ -f "$ROOT_PATH/etc/shadow" ]]; then
		chown root:shadow "$ROOT_PATH/etc/shadow" 2>/dev/null || chown root:root "$ROOT_PATH/etc/shadow" 2>/dev/null || true
		chmod 640 "$ROOT_PATH/etc/shadow" 2>/dev/null || chmod 600 "$ROOT_PATH/etc/shadow" 2>/dev/null || true
	fi
	if [[ -f "$ROOT_PATH/etc/gshadow" ]]; then
		chown root:shadow "$ROOT_PATH/etc/gshadow" 2>/dev/null || chown root:root "$ROOT_PATH/etc/gshadow" 2>/dev/null || true
		chmod 640 "$ROOT_PATH/etc/gshadow" 2>/dev/null || chmod 600 "$ROOT_PATH/etc/gshadow" 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH/etc/sudoers" ]] || [[ -L "$ROOT_PATH/etc/sudoers" ]]; then
		cat > "$ROOT_PATH/etc/sudoers" <<'EOF'
## Silen Linux sudoers
root ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
## Read drop-in files from /etc/sudoers.d
@includedir /etc/sudoers.d
EOF
		chown root:root "$ROOT_PATH/etc/sudoers" 2>/dev/null || true
		chmod 440 "$ROOT_PATH/etc/sudoers" 2>/dev/null || true
	else
		chown root:root "$ROOT_PATH/etc/sudoers" 2>/dev/null || true
		chmod 440 "$ROOT_PATH/etc/sudoers" 2>/dev/null || true
	fi
	if [[ -d "$ROOT_PATH/etc/sudoers.d" ]]; then
		chown root:root "$ROOT_PATH/etc/sudoers.d" 2>/dev/null || true
		chmod 755 "$ROOT_PATH/etc/sudoers.d" 2>/dev/null || true
		for _s in "$ROOT_PATH"/etc/sudoers.d/*; do
			[[ -f "$_s" ]] || continue
			chown root:root "$_s" 2>/dev/null || true
			chmod 440 "$_s" 2>/dev/null || true
		done || true
	fi
	mkdir -p "$ROOT_PATH/etc/pam.d" 2>/dev/null || true
	for _p in sudo sudo-i; do
		if [[ ! -f "$ROOT_PATH/etc/pam.d/$_p" ]]; then
			printf 'auth\tinclude\t\tsystem-auth\naccount\tinclude\t\tsystem-auth\nsession\tinclude\t\tsystem-auth\n' > "$ROOT_PATH/etc/pam.d/$_p" 2>/dev/null || true
		fi
		chmod 644 "$ROOT_PATH/etc/pam.d/$_p" 2>/dev/null || true
	done || true
	if [[ -f "$ROOT_PATH/etc/passwd" ]]; then
		chmod 644 "$ROOT_PATH/etc/passwd" 2>/dev/null || true
	fi
	if [[ -f "$ROOT_PATH/etc/group" ]]; then
		chmod 644 "$ROOT_PATH/etc/group" 2>/dev/null || true
	fi
	# DEBUG: fixed wheel/sudo groups missing on target
	for _g in wheel sudo; do
		if ! chroot "$ROOT_PATH" /bin/bash -c "getent group $_g" >/dev/null 2>&1; then
			chroot "$ROOT_PATH" /bin/bash -c "groupadd -r $_g" >/dev/null 2>&1 || true
		fi
	done || true
}

fix-user-session() {
	mkdir -p "$ROOT_PATH/run/user" "$ROOT_PATH/run/openrc" "$ROOT_PATH/run/dbus" 2>/dev/null || true
	chmod 755 "$ROOT_PATH/run/user" 2>/dev/null || true
	mkdir -p "$ROOT_PATH/usr/lib/tmpfiles.d" "$ROOT_PATH/etc/tmpfiles.d" 2>/dev/null || true
	printf 'd /run/user 0755 root root -\n' > "$ROOT_PATH/usr/lib/tmpfiles.d/silen-run-user.conf" 2>/dev/null || true
	if [[ -f "$ROOT_PATH/etc/rc.conf" ]]; then
		if grep -q '^[[:space:]]*rc_autostart_user=' "$ROOT_PATH/etc/rc.conf" 2>/dev/null; then
			sed -i 's/^[[:space:]]*rc_autostart_user=.*/rc_autostart_user="YES"/' "$ROOT_PATH/etc/rc.conf" 2>/dev/null || true
		fi
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "command -v elogind >/dev/null 2>&1 || test -f /etc/init.d/elogind" >/dev/null 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "rc-update add elogind boot" >/dev/null 2>&1 || \
		chroot "$ROOT_PATH" /bin/bash -c "rc-update add elogind default" >/dev/null 2>&1 || true
	else
		_elogind_hint="1"
	fi
}

apply-settings() {
	if [[ -f "$ROOT_PATH/usr/share/zoneinfo/$zone" ]]; then
		ln -sf "/usr/share/zoneinfo/$zone" "$ROOT_PATH"/etc/localtime
	else
		whiptail --msgbox --title "$title" "timezone $zone missing in target, time may be UTC until tzdata is installed" 8 60 || true
		ln -sf "/usr/share/zoneinfo/$zone" "$ROOT_PATH"/etc/localtime
	fi

	mkdir -p "$ROOT_PATH"/etc/conf.d
	echo "keymap=\"$keymap\"" > "$ROOT_PATH"/etc/conf.d/keymaps

	echo "$locale UTF-8" > "$ROOT_PATH"/etc/locale.gen
	if ! chroot "$ROOT_PATH" /bin/bash -c "locale-gen" 2>/dev/null; then
		whiptail --msgbox --title "$title" "couldn't generate locales, check locale.gen later" 8 40 || true
	fi
	mkdir -p "$ROOT_PATH"/etc/env.d
	echo "LANG=\"$locale\"" > "$ROOT_PATH"/etc/env.d/02locale

	made_swapfile=""
	case "${want_swap:-}" in
		1G|2G|4G|8G) ;;
		*) want_swap="" ;;
	esac
	if [[ -n "${want_swap:-}" ]]; then
		if chroot "$ROOT_PATH" /bin/bash -c "fallocate -l $want_swap /swapfile && chmod 600 /swapfile && mkswap /swapfile" 2>/dev/null; then
			made_swapfile="1"
		else
			whiptail --msgbox --title "$title" "couldn't create the swapfile" 8 40 || true
		fi
	fi

	printf 'Welcome to Silen Linux\n' > "$ROOT_PATH"/etc/motd 2>/dev/null || true

	mkdir -p "$ROOT_PATH"/etc/sudoers.d 2>/dev/null || true
	printf '%s\n' "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > "$ROOT_PATH"/etc/sudoers.d/10-silen 2>/dev/null || true
	chmod 0440 "$ROOT_PATH"/etc/sudoers.d/10-silen 2>/dev/null || true

	cat > "$ROOT_PATH"/etc/profile.d/silen-hostname.sh <<'EOF'
if [ -f /etc/hostname ]; then
    HOSTNAME=$(cat /etc/hostname 2>/dev/null)
    export HOSTNAME
fi
EOF
	chmod 644 "$ROOT_PATH"/etc/profile.d/silen-hostname.sh 2>/dev/null || true

	cat > "$ROOT_PATH"/etc/bash.bashrc <<'EOF'
[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
EOF
	chmod 644 "$ROOT_PATH"/etc/bash.bashrc 2>/dev/null || true
}

create-user() {
	[[ -n "${newuser:-}" ]] || return 0
	if ! chroot "$ROOT_PATH" /bin/bash -c "command -v useradd" >/dev/null 2>&1; then
		whiptail --msgbox --title "$title" "couldn't create user $newuser (no useradd in the new system)" 8 60 || true
		return 0
	fi
	# DEBUG: fixed wheel/sudo groups missing before useradd
	for _g in wheel sudo; do
		if ! chroot "$ROOT_PATH" /bin/bash -c "getent group $_g" >/dev/null 2>&1; then
			chroot "$ROOT_PATH" /bin/bash -c "groupadd -r $_g" >/dev/null 2>&1 || true
		fi
	done || true
	usergroups=""
	for g in wheel sudo audio video network plugdev; do
		if chroot "$ROOT_PATH" /bin/bash -c "getent group $g" >/dev/null 2>&1; then
			if [[ -z "$usergroups" ]]; then
				usergroups="$g"
			else
				usergroups="$usergroups,$g"
			fi
		fi
	done || true
	if [[ -n "$usergroups" ]]; then
		_uflags="-m -s /bin/bash -G $usergroups"
	else
		_uflags="-m -s /bin/bash"
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "useradd $_uflags $newuser" 2>/dev/null; then
		whiptail --msgbox --title "$title" "couldn't create user $newuser - add it by hand after reboot with useradd" 8 60 || true
		return 0
	fi
	if ! printf '%s:%s\n' "$newuser" "$userpass" | chroot "$ROOT_PATH" /bin/bash -c "chpasswd" 2>/dev/null; then
		whiptail --msgbox --title "$title" "user $newuser created but the password couldn't be set - run passwd $newuser after reboot" 8 60 || true
	fi
	userpass=""
	# DEBUG: fixed passwd -S pattern never matching locked accounts
	if chroot "$ROOT_PATH" /bin/bash -c "passwd -S $newuser" 2>/dev/null | grep -q "^$newuser L[[:space:]]"; then
		chroot "$ROOT_PATH" /bin/bash -c "passwd -u $newuser" >/dev/null 2>&1 || true
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "passwd -S $newuser" 2>/dev/null | grep -q "^$newuser L[[:space:]]"; then
		whiptail --msgbox --title "$title" "user $newuser is locked and sudo will refuse it. After reboot run as root: passwd $newuser" 9 70 || true
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "usermod -aG wheel $newuser" >/dev/null 2>&1 || \
		chroot "$ROOT_PATH" /bin/bash -c "gpasswd -a $newuser wheel" >/dev/null 2>&1 || true
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "getent group sudo" >/dev/null 2>&1; then
		if ! chroot "$ROOT_PATH" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw sudo" >/dev/null 2>&1; then
			chroot "$ROOT_PATH" /bin/bash -c "usermod -aG sudo $newuser" >/dev/null 2>&1 || \
			chroot "$ROOT_PATH" /bin/bash -c "gpasswd -a $newuser sudo" >/dev/null 2>&1 || true
		fi
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
		whiptail --msgbox --title "$title" "user $newuser is not in the wheel group, so 'su -' will refuse even the right password. After reboot run as root: usermod -aG wheel $newuser" 9 70 || true
	fi
	# DEBUG: fixed sudo test failing even when sudoers is correct
	mkdir -p "$ROOT_PATH"/etc/sudoers.d 2>/dev/null || true
	if [[ ! -f "$ROOT_PATH"/etc/sudoers.d/10-silen ]]; then
		printf '%s\n' "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > "$ROOT_PATH"/etc/sudoers.d/10-silen 2>/dev/null || true
	fi
	chown root:root "$ROOT_PATH"/etc/sudoers "$ROOT_PATH"/etc/sudoers.d/10-silen 2>/dev/null || true
	chmod 440 "$ROOT_PATH"/etc/sudoers "$ROOT_PATH"/etc/sudoers.d/10-silen 2>/dev/null || true
	_sudo_ok=""
	chroot "$ROOT_PATH" /bin/bash -c "sudo -U $newuser -l" >/dev/null 2>&1 && _sudo_ok="1"
	if [[ -z "$_sudo_ok" ]]; then
		chroot "$ROOT_PATH" /bin/bash -c "su -s /bin/sh $newuser -c 'sudo -n true'" >/dev/null 2>&1 && _sudo_ok="1"
	fi
	if [[ -z "$_sudo_ok" ]]; then
		whiptail --msgbox --title "$title" "sudo doesn't work for $newuser yet. After reboot run as root: passwd $newuser; chown root:root /etc/sudoers /etc/sudoers.d/*; chmod 440 /etc/sudoers /etc/sudoers.d/*" 10 70 || true
	fi
	if mkdir -p "$ROOT_PATH"/home/$newuser/.local/bin \
			"$ROOT_PATH"/home/$newuser/.local/share/spk/apps \
			"$ROOT_PATH"/home/$newuser/.local/share/spk/packages \
			"$ROOT_PATH"/home/$newuser/.cache/spk 2>/dev/null; then
		chroot "$ROOT_PATH" /bin/bash -c "chown -R $newuser:$newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || \
		chroot "$ROOT_PATH" /bin/bash -c "chown -R $newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || true
	fi
	chroot "$ROOT_PATH" /bin/bash -c "chown $newuser:$(id -gn $newuser 2>/dev/null || echo \$newuser) /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || \
	chroot "$ROOT_PATH" /bin/bash -c "chown $newuser /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || true
}

install-branding() {
	logo_src=""
	for f in /mnt/branding/fastfetch_logo.txt /mnt/fastfetch_logo.txt; do
		[[ -f "$f" ]] && logo_src="$f" && break
	done || true
	[[ -n "$logo_src" ]] || return 0

	mkdir -p "$ROOT_PATH"/usr/share/silen
	cp "$logo_src" "$ROOT_PATH"/usr/share/silen/fastfetch_logo.txt 2>/dev/null || return 0
	if [[ -f /mnt/branding/info.txt ]]; then
		cp /mnt/branding/info.txt "$ROOT_PATH"/usr/share/silen/info.txt 2>/dev/null || true
	fi

	mkdir -p "$ROOT_PATH"/usr/local/bin
	cat > "$ROOT_PATH"/usr/local/bin/silenfetch <<'EOF'
#!/bin/sh
command -v fastfetch >/dev/null 2>&1 || { echo "silenfetch: fastfetch is not installed (sudo spk get fastfetch)" >&2; exit 127; }
exec fastfetch -l /usr/share/silen/fastfetch_logo.txt "$@"
EOF
	chmod 755 "$ROOT_PATH"/usr/local/bin/silenfetch 2>/dev/null || true

	mkdir -p "$ROOT_PATH"/etc/fastfetch "$ROOT_PATH"/etc/xdg/fastfetch "$ROOT_PATH"/etc/skel/.config/fastfetch "$ROOT_PATH"/root/.config/fastfetch
	cat > "$ROOT_PATH"/etc/fastfetch/config.jsonc <<'EOF'
{
    "logo": {
        "type": "file",
        "source": "/usr/share/silen/fastfetch_logo.txt",
        "padding": {
            "top": 0,
            "left": 1,
            "right": 3
        }
    },
    "modules": [
        "title",
        "separator",
        "os",
        "host",
        "kernel",
        "uptime",
        "shell",
        "cpu",
        "memory",
        "disk",
        "break",
        "colors"
    ]
}
EOF
	cp "$ROOT_PATH"/etc/fastfetch/config.jsonc "$ROOT_PATH"/etc/xdg/fastfetch/config.jsonc 2>/dev/null || true
	cp "$ROOT_PATH"/etc/fastfetch/config.jsonc "$ROOT_PATH"/etc/skel/.config/fastfetch/config.jsonc 2>/dev/null || true
	cp "$ROOT_PATH"/etc/fastfetch/config.jsonc "$ROOT_PATH"/root/.config/fastfetch/config.jsonc 2>/dev/null || true

	if [[ -n "${newuser:-}" ]] && [[ -d "$ROOT_PATH/home/$newuser" ]]; then
		mkdir -p "$ROOT_PATH"/home/$newuser/.config/fastfetch 2>/dev/null || true
		cp "$ROOT_PATH"/etc/fastfetch/config.jsonc "$ROOT_PATH"/home/$newuser/.config/fastfetch/config.jsonc 2>/dev/null || true
		cp "$logo_src" "$ROOT_PATH/home/$newuser/.ascii" 2>/dev/null || true
		printf '%s\n' "alias silenfetch='fastfetch -l /usr/share/silen/fastfetch_logo.txt'" >> "$ROOT_PATH/home/$newuser/.bashrc" 2>/dev/null || true
		chroot "$ROOT_PATH" /bin/bash -c "chown -R $newuser /home/$newuser/.config" >/dev/null 2>&1 || \
		chown -R --reference="$ROOT_PATH/home/$newuser" "$ROOT_PATH/home/$newuser/.config" 2>/dev/null || true
		chown --reference="$ROOT_PATH/home/$newuser" "$ROOT_PATH/home/$newuser/.ascii" "$ROOT_PATH/home/$newuser/.bashrc" 2>/dev/null || true
	fi
}

setup-root-shell() {
	mkdir -p "$ROOT_PATH"/root 2>/dev/null || true
	if [[ ! -f "$ROOT_PATH"/root/.bashrc ]]; then
		cat > "$ROOT_PATH"/root/.bashrc <<'EOF'
[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh
PS1='\u@\h \w \$ '
alias ls='ls --color=auto'
alias silenfetch='fastfetch -l /usr/share/silen/fastfetch_logo.txt'
EOF
	fi
	if [[ ! -f "$ROOT_PATH"/root/.bash_profile ]]; then
		printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
	fi
	chown root:root "$ROOT_PATH"/root/.bashrc "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
	chmod 644 "$ROOT_PATH"/root/.bashrc "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
}

setup-quiet-boot() {
	if [[ -f "$ROOT_PATH"/etc/inittab ]]; then
		sed -i 's#/sbin/openrc \(sysinit\|boot\|shutdown\|single\|nonetwork\|default\|reboot\)#/sbin/openrc --quiet \1#g' \
			"$ROOT_PATH"/etc/inittab 2>/dev/null || true
	fi
	if [[ -f "$ROOT_PATH"/etc/rc.conf ]]; then
		if grep -q '^[[:space:]]*rc_logger=' "$ROOT_PATH"/etc/rc.conf 2>/dev/null; then
			sed -i 's|^[[:space:]]*rc_logger=.*|rc_logger="YES"|' "$ROOT_PATH"/etc/rc.conf 2>/dev/null || true
		elif grep -q 'rc_logger=' "$ROOT_PATH"/etc/rc.conf 2>/dev/null; then
			sed -i 's|.*rc_logger=.*|rc_logger="YES"|' "$ROOT_PATH"/etc/rc.conf 2>/dev/null || true
		else
			printf '\n# log boot messages to /var/log/rc.log while the console stays quiet\nrc_logger="YES"\n' >> "$ROOT_PATH"/etc/rc.conf 2>/dev/null || true
		fi
	fi
	# DEBUG: fixed blind service failures, always ensure boot logging exists
	if ! grep -q '^[[:space:]]*rc_logger=' "$ROOT_PATH"/etc/rc.conf 2>/dev/null; then
		printf '\nrc_logger="YES"\n' >> "$ROOT_PATH"/etc/rc.conf 2>/dev/null || true
	fi
}

cleanup-rootfs() {
	rm -rf "$ROOT_PATH"/lost+found 2>/dev/null || true
	for d in media opt srv; do
		if [[ -d "$ROOT_PATH/$d" ]] && [[ -z "$(ls -A "$ROOT_PATH/$d" 2>/dev/null)" ]]; then
			rmdir "$ROOT_PATH/$d" 2>/dev/null || true
		fi
	done
}

setup-autologin() {
	_user="${newuser:-root}"
	[[ -n "$_user" ]] || _user="root"
	if [[ -f "$ROOT_PATH"/etc/inittab ]]; then
		sed -i "s#^c1:.*#c1:12345:respawn:/sbin/agetty --noclear --autologin $_user 38400 tty1 linux#" "$ROOT_PATH"/etc/inittab 2>/dev/null || true
	fi
	# DEBUG: fixed installed desktop dying with no log or fallback
	mkdir -p "$ROOT_PATH"/usr/local/bin 2>/dev/null || true
	cat > "$ROOT_PATH"/usr/local/bin/silen-desktop <<'EOF' || true
#!/bin/sh
# auto desktop, drm first then x11 fallback, never spin the login
LOG=/tmp/silen-desktop.log
echo "=== silen-desktop start $(date -u 2>/dev/null || date) ===" >"$LOG" 2>&1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_CURRENT_DESKTOP=instantwm
export XDG_SESSION_DESKTOP=instantwm
export XDG_SESSION_TYPE=wayland
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
if dmesg 2>/dev/null | grep -qi "nouveau.*firmware unavailable"; then
    export LIBGL_ALWAYS_SOFTWARE=1
    echo "nouveau has no firmware, forcing software rendering" >>"$LOG" 2>&1
fi
if [ ! -x /usr/bin/instantwm ]; then
    echo "instantwm missing at /usr/bin/instantwm (run: spk get instantwm seatd)" >>"$LOG" 2>&1
    echo "instantwm missing, dropping to shell (run: spk get instantwm seatd). See $LOG"
    # DEBUG: fixed c1 respawning too fast, slow the retry loop
    sleep 8 2>/dev/null || sleep 8
    exec /bin/bash --login
fi
_i=0
while [ ! -S /run/seatd.sock ] && [ ! -S "$XDG_RUNTIME_DIR/seatd.sock" ] && [ $_i -lt 50 ]; do
    _i=$((_i + 1))
    sleep 0.1 2>/dev/null || sleep 1
done
# run, dont exec: a fast crash means broken gpu setup, fall through instead of killing the login
run_drm() {
    ls /dev/dri/card* >>"$LOG" 2>&1 || { echo "no /dev/dri/card* (KMS driver or firmware missing?)" >>"$LOG" 2>&1; return 1; }
    echo "starting instantwm --backend drm" >>"$LOG" 2>&1
    _t0=$(date +%s 2>/dev/null || echo 0)
    /usr/bin/instantwm --backend drm >>"$LOG" 2>&1
    _rc=$?
    _t1=$(date +%s 2>/dev/null || echo 0)
    echo "instantwm drm exited $_rc after $((_t1 - _t0))s" >>"$LOG" 2>&1
    [ $((_t1 - _t0)) -ge 15 ]
}
run_x11() {
    [ -x /usr/bin/Xorg ] || return 1
    export DISPLAY="${DISPLAY:-:0}"
    echo "trying Xorg $DISPLAY" >>"$LOG" 2>&1
    mkdir -p /tmp/.X11-unix 2>/dev/null || true
    /usr/bin/Xorg "$DISPLAY" vt1 -nolisten tcp -logfile /tmp/xorg.log >>/tmp/xorg.log 2>&1 &
    _xp=$!
    _i=0
    while [ $_i -lt 100 ] && [ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
        _i=$((_i + 1)); sleep 0.1 2>/dev/null || sleep 1
    done
    if [ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
        echo "Xorg socket never appeared, see /tmp/xorg.log" >>"$LOG" 2>&1
        kill "$_xp" 2>/dev/null || true
        return 1
    fi
    unset WAYLAND_DISPLAY
    export XDG_SESSION_TYPE=x11
    echo "starting instantwm --backend x11" >>"$LOG" 2>&1
    _t0=$(date +%s 2>/dev/null || echo 0)
    DISPLAY="$DISPLAY" /usr/bin/instantwm --backend x11 >>"$LOG" 2>&1
    _rc=$?
    _t1=$(date +%s 2>/dev/null || echo 0)
    echo "instantwm x11 exited $_rc after $((_t1 - _t0))s" >>"$LOG" 2>&1
    kill "$_xp" 2>/dev/null || true
    [ $((_t1 - _t0)) -ge 15 ]
}
# a logout ends the session, a fast crash falls through to the next backend
if run_drm; then
    exit 0
fi
if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" != "1" ]; then
    echo "drm backend crashed, retrying with software rendering" >>"$LOG" 2>&1
    export LIBGL_ALWAYS_SOFTWARE=1
    if run_drm; then
        exit 0
    fi
fi
if run_x11; then
    exit 0
fi
if [ "${LIBGL_ALWAYS_SOFTWARE:-0}" != "1" ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    if run_x11; then
        exit 0
    fi
fi
echo "no working desktop (tried drm, drm-sw, x11). See $LOG /tmp/xorg.log" >>"$LOG" 2>&1
echo "desktop failed to start, see $LOG. Dropping to a shell instead of retrying."
# DEBUG: fixed c1 respawning too fast, slow the retry loop
sleep 5 2>/dev/null || sleep 5
exec /bin/bash --login
EOF
	chmod 755 "$ROOT_PATH"/usr/local/bin/silen-desktop 2>/dev/null || true
	chroot "$ROOT_PATH" /bin/bash -c "rc-update add seatd default" >/dev/null 2>&1 || true
	_snip="$(mktemp /tmp/autologin.XXXXXX 2>/dev/null || echo /tmp/autologin.$$)"
	cat > "$_snip" <<'EOF' || true
# DEBUG: fixed desktop crash relaunching forever, launch once per login
if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ] && [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ -z "$SILEN_DESKTOP_DONE" ]; then
    export SILEN_DESKTOP_DONE=1
    if command -v silen-desktop >/dev/null 2>&1; then
        exec silen-desktop
    elif command -v instantwm >/dev/null 2>&1; then
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
        export XDG_CURRENT_DESKTOP=instantwm XDG_SESSION_DESKTOP=instantwm XDG_SESSION_TYPE=wayland
        exec instantwm --backend drm
    fi
fi
EOF
	if ! grep -q "silen-desktop" "$ROOT_PATH"/root/.bash_profile 2>/dev/null; then
		cat "$_snip" >> "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
	fi
	chown root:root "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
	chmod 644 "$ROOT_PATH"/root/.bash_profile 2>/dev/null || true
	if [[ "$_user" != "root" ]]; then
		_uprof="$ROOT_PATH/home/$_user/.bash_profile"
		if [[ ! -f "$_uprof" ]]; then
			printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > "$_uprof" 2>/dev/null || true
		fi
		if ! grep -q "silen-desktop" "$_uprof" 2>/dev/null; then
			cat "$_snip" >> "$_uprof" 2>/dev/null || true
		fi
		chroot "$ROOT_PATH" /bin/bash -c "chown $_user /home/$_user/.bash_profile && chmod 644 /home/$_user/.bash_profile" >/dev/null 2>&1 || true
		chroot "$ROOT_PATH" /bin/bash -c "getent group seat || groupadd -r seat" >/dev/null 2>&1 || true
		# DEBUG: fixed missing render group breaking drm access
		chroot "$ROOT_PATH" /bin/bash -c "usermod -aG seat,video,input,render $_user" >/dev/null 2>&1 || true
	fi
	rm -f "$_snip" 2>/dev/null || true
}

seed-instantwm-defaults() {
	# DEBUG: fixed instantwm warning about missing default apps, seed what the ISO ships
	_dd="$(mktemp -d /tmp/iwdefaults.XXXXXX 2>/dev/null || echo /tmp/iwdefaults.$$)"
	mkdir -p "$_dd" 2>/dev/null || true
	[[ -x "$ROOT_PATH/usr/bin/kitty" ]] && ln -sf /usr/bin/kitty "$_dd/terminal" 2>/dev/null || true
	[[ -x "$ROOT_PATH/usr/bin/yazi" ]] && ln -sf /usr/bin/yazi "$_dd/termfilemanager" 2>/dev/null || true
	if [[ -x "$ROOT_PATH/usr/bin/kitty" ]] && [[ -x "$ROOT_PATH/usr/bin/yazi" ]]; then
		cat > "$_dd/filemanager" <<'EOF' || true
#!/bin/sh
exec kitty -e yazi "$@"
EOF
	fi
	[[ -x "$ROOT_PATH/usr/bin/instantmenu_run" ]] && ln -sf /usr/bin/instantmenu_run "$_dd/appmenu" 2>/dev/null || true
	[[ -x "$ROOT_PATH/usr/bin/swaylock" ]] && ln -sf /usr/bin/swaylock "$_dd/lockscreen" 2>/dev/null || true
	if [[ -x "$ROOT_PATH/usr/bin/kitty" ]] && [[ -x "$ROOT_PATH/usr/bin/nano" ]]; then
		cat > "$_dd/editor" <<'EOF' || true
#!/bin/sh
exec kitty -e nano "$@"
EOF
	fi
	if [[ -x "$ROOT_PATH/usr/bin/kitty" ]] && [[ -x "$ROOT_PATH/usr/bin/btm" ]]; then
		cat > "$_dd/systemmonitor" <<'EOF' || true
#!/bin/sh
exec kitty -e btm "$@"
EOF
	fi
	# browser: nothing shipped, leave missing so the warning stays honest
	chmod 755 "$_dd"/* 2>/dev/null || true
	for _home in "$ROOT_PATH/etc/skel" "$ROOT_PATH/root"; do
		mkdir -p "$_home/.config/instantos/default" 2>/dev/null || continue
		cp -a "$_dd/." "$_home/.config/instantos/default/" 2>/dev/null || true
		chown -R root:root "$_home/.config/instantos" 2>/dev/null || true
	done || true
	if [[ -n "${newuser:-}" ]] && [[ -d "$ROOT_PATH/home/$newuser" ]]; then
		mkdir -p "$ROOT_PATH/home/$newuser/.config/instantos/default" 2>/dev/null || true
		cp -a "$_dd/." "$ROOT_PATH/home/$newuser/.config/instantos/default/" 2>/dev/null || true
		chroot "$ROOT_PATH" /bin/bash -c "chown -R $newuser /home/$newuser/.config/instantos" >/dev/null 2>&1 || \
		chown -R --reference="$ROOT_PATH/home/$newuser" "$ROOT_PATH/home/$newuser/.config/instantos" 2>/dev/null || true
	fi
	rm -rf "$_dd" 2>/dev/null || true
	if [[ -x "$ROOT_PATH/usr/bin/swaylock" ]] && [[ ! -f "$ROOT_PATH/etc/pam.d/swaylock" ]]; then
		printf 'auth\tinclude\t\tsystem-auth\naccount\tinclude\t\tsystem-auth\nsession\tinclude\t\tsystem-auth\n' > "$ROOT_PATH/etc/pam.d/swaylock" 2>/dev/null || true
		chmod 644 "$ROOT_PATH/etc/pam.d/swaylock" 2>/dev/null || true
	fi
}
