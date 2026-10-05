fix-permissions() {
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
	if [[ -f "$ROOT_PATH/etc/sudoers" ]] && [[ ! -L "$ROOT_PATH/etc/sudoers" ]]; then
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
	if [[ -f "$ROOT_PATH/etc/passwd" ]]; then
		chmod 644 "$ROOT_PATH/etc/passwd" 2>/dev/null || true
	fi
	if [[ -f "$ROOT_PATH/etc/group" ]]; then
		chmod 644 "$ROOT_PATH/etc/group" 2>/dev/null || true
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "getent group wheel" >/dev/null 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "groupadd -r wheel" >/dev/null 2>&1 || true
	fi
}

fix-sudo-emerge() {
	if [[ -d "$ROOT_PATH/etc/pam.d" ]]; then
		for _p in sudo sudo-i; do
			if [[ ! -f "$ROOT_PATH/etc/pam.d/$_p" ]]; then
				printf 'auth\tinclude\t\tsystem-auth\naccount\tinclude\t\tsystem-auth\nsession\tinclude\t\tsystem-auth\n' > "$ROOT_PATH/etc/pam.d/$_p" 2>/dev/null || true
			fi
			chmod 644 "$ROOT_PATH/etc/pam.d/$_p" 2>/dev/null || true
		done || true
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "getent passwd portage" >/dev/null 2>&1; then
		if ! grep -q '^portage:' "$ROOT_PATH/etc/shadow" 2>/dev/null; then
			printf '%s\n' 'portage:*:9797:0:::::' >> "$ROOT_PATH/etc/shadow" 2>/dev/null || true
		fi
		if ! grep -q '^portage:' "$ROOT_PATH/etc/gshadow" 2>/dev/null; then
			printf '%s\n' 'portage:!::portage' >> "$ROOT_PATH/etc/gshadow" 2>/dev/null || true
		fi
		sed -i 's/^portage::/portage:x:/' "$ROOT_PATH/etc/group" 2>/dev/null || true
	fi
	chown 250:250 "$ROOT_PATH/var/cache/binpkgs" 2>/dev/null || true
	chmod 775 "$ROOT_PATH/var/cache/binpkgs" 2>/dev/null || true
	chown 250:250 "$ROOT_PATH/var/db/repos/gentoo" 2>/dev/null || true
	chmod 775 "$ROOT_PATH/var/db/repos/gentoo" 2>/dev/null || true
	chown 0:250 "$ROOT_PATH/var/cache/distfiles" 2>/dev/null || true
	chmod 775 "$ROOT_PATH/var/cache/distfiles" 2>/dev/null || true
	chown 250:250 "$ROOT_PATH/var/tmp/portage" 2>/dev/null || true
	chmod 775 "$ROOT_PATH/var/tmp/portage" 2>/dev/null || true
	sed -i 's/^auto-sync *= *no/auto-sync = yes/' "$ROOT_PATH/etc/portage/repos.conf/gentoo.conf" 2>/dev/null || true
	if [[ -f "$ROOT_PATH/etc/portage/make.conf" ]]; then
		if ! grep -q '^EMERGE_DEFAULT_OPTS=' "$ROOT_PATH/etc/portage/make.conf" 2>/dev/null; then
			printf '%s\n' 'EMERGE_DEFAULT_OPTS="--getbinpkg --binpkg-respect-use=y"' >> "$ROOT_PATH/etc/portage/make.conf" 2>/dev/null || true
		fi
		if ! grep -q '^FEATURES=' "$ROOT_PATH/etc/portage/make.conf" 2>/dev/null; then
			printf '%s\n' 'FEATURES="binpkg-request-signature"' >> "$ROOT_PATH/etc/portage/make.conf" 2>/dev/null || true
		fi
	fi
	mkdir -p "$ROOT_PATH/etc/portage/binrepos.conf" "$ROOT_PATH/etc/portage/package.use" "$ROOT_PATH/etc/portage/package.accept_keywords" 2>/dev/null || true
	if [[ ! -f "$ROOT_PATH/etc/portage/binrepos.conf/gentoobinhost.conf" ]]; then
		printf '%s\n' '[binhost]' 'priority = 9999' 'sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64' > "$ROOT_PATH/etc/portage/binrepos.conf/gentoobinhost.conf" 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH/etc/portage/package.use/freetype" ]]; then
		printf '%s\n' 'media-libs/freetype harfbuzz' > "$ROOT_PATH/etc/portage/package.use/freetype" 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH/etc/portage/package.use/bootstrap" ]]; then
		printf '%s\n' 'sys-devel/gettext -xattr' 'sys-apps/attr -nls' > "$ROOT_PATH/etc/portage/package.use/bootstrap" 2>/dev/null || true
	fi
	if [[ ! -f "$ROOT_PATH/etc/portage/package.accept_keywords/elt-patches" ]]; then
		printf '%s\n' 'app-portage/elt-patches **' > "$ROOT_PATH/etc/portage/package.accept_keywords/elt-patches" 2>/dev/null || true
	fi
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
	if chroot "$ROOT_PATH" /bin/bash -c "passwd -S $newuser" 2>/dev/null | grep -q " $newuser L "; then
		chroot "$ROOT_PATH" /bin/bash -c "passwd -u $newuser" >/dev/null 2>&1 || true
	fi
	if chroot "$ROOT_PATH" /bin/bash -c "passwd -S $newuser" 2>/dev/null | grep -q " $newuser L "; then
		whiptail --msgbox --title "$title" "user $newuser is locked and sudo will refuse it. After reboot run as root: passwd $newuser" 9 70 || true
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
		chroot "$ROOT_PATH" /bin/bash -c "usermod -aG wheel $newuser" >/dev/null 2>&1 || true
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
		whiptail --msgbox --title "$title" "user $newuser is not in the wheel group, so 'su -' will refuse even the right password. After reboot run as root: usermod -aG wheel $newuser" 9 70 || true
	fi
	if ! chroot "$ROOT_PATH" /bin/bash -c "su -s /bin/sh $newuser -c 'sudo -n true'" >/dev/null 2>&1; then
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
		printf '%s\n' "alias silenfetch='fastfetch -l ~/.ascii'" >> "$ROOT_PATH/home/$newuser/.bashrc" 2>/dev/null || true
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
}

cleanup-rootfs() {
	rm -rf "$ROOT_PATH"/lost+found 2>/dev/null || true
	for d in media opt srv; do
		if [[ -d "$ROOT_PATH/$d" ]] && [[ -z "$(ls -A "$ROOT_PATH/$d" 2>/dev/null)" ]]; then
			rmdir "$ROOT_PATH/$d" 2>/dev/null || true
		fi
	done
}
