fix-permissions() {
    for _s in bin/su usr/bin/su \
               bin/passwd usr/bin/passwd \
               usr/bin/chage usr/bin/chfn usr/bin/chsh \
               usr/bin/gpasswd usr/bin/newgrp \
               bin/mount usr/bin/mount bin/umount usr/bin/umount \
               usr/bin/sudo bin/sudo usr/bin/sudoedit bin/sudoedit; do
        if [ -e "$root/$_s" ] && [ ! -L "$root/$_s" ]; then
            chown root:root "$root/$_s" 2>/dev/null || true
            chmod 4755 "$root/$_s" 2>/dev/null || true
        fi
    done || true
    for _u in bin/unix_chkpwd usr/bin/unix_chkpwd sbin/unix_chkpwd usr/sbin/unix_chkpwd; do
        if [ -e "$root/$_u" ] && [ ! -L "$root/$_u" ]; then
            chown root:shadow "$root/$_u" 2>/dev/null || chown root:root "$root/$_u" 2>/dev/null || true
            chmod 4755 "$root/$_u" 2>/dev/null || chmod 2711 "$root/$_u" 2>/dev/null || true
        fi
    done || true
    if [ -f "$root/etc/shadow" ]; then
        chown root:shadow "$root/etc/shadow" 2>/dev/null || chown root:root "$root/etc/shadow" 2>/dev/null || true
        chmod 640 "$root/etc/shadow" 2>/dev/null || chmod 600 "$root/etc/shadow" 2>/dev/null || true
    fi
    if [ -f "$root/etc/gshadow" ]; then
        chown root:shadow "$root/etc/gshadow" 2>/dev/null || chown root:root "$root/etc/gshadow" 2>/dev/null || true
        chmod 640 "$root/etc/gshadow" 2>/dev/null || chmod 600 "$root/etc/gshadow" 2>/dev/null || true
    fi
    if [ -f "$root/etc/passwd" ]; then
        chmod 644 "$root/etc/passwd" 2>/dev/null || true
    fi
    if [ -f "$root/etc/group" ]; then
        chmod 644 "$root/etc/group" 2>/dev/null || true
    fi
    if ! chroot "$root" /bin/bash -c "getent group wheel" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "groupadd -r wheel" >/dev/null 2>&1 || true
    fi
}

fix-user-session() {
    mkdir -p "$root/run/user" "$root/run/openrc" "$root/run/dbus" 2>/dev/null || true
    chmod 755 "$root/run/user" 2>/dev/null || true
    mkdir -p "$root/usr/lib/tmpfiles.d" "$root/etc/tmpfiles.d" 2>/dev/null || true
    printf 'd /run/user 0755 root root -\n' > "$root/usr/lib/tmpfiles.d/silen-run-user.conf" 2>/dev/null || true
    if [ -f "$root/etc/rc.conf" ]; then
        if grep -q '^[[:space:]]*rc_autostart_user=' "$root/etc/rc.conf" 2>/dev/null; then
            sed -i 's/^[[:space:]]*rc_autostart_user=.*/rc_autostart_user="YES"/' "$root/etc/rc.conf" 2>/dev/null || true
        fi
    fi
    if chroot "$root" /bin/bash -c "command -v elogind >/dev/null 2>&1 || test -f /etc/init.d/elogind" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "rc-update add elogind boot" >/dev/null 2>&1 || \
        chroot "$root" /bin/bash -c "rc-update add elogind default" >/dev/null 2>&1 || true
    else
        _elogind_hint="1"
    fi
}

apply-settings() {
    if [ -f "$root/usr/share/zoneinfo/$zone" ]; then
        ln -sf "/usr/share/zoneinfo/$zone" "$root"/etc/localtime
    else
        whiptail --msgbox --title "$title" "timezone $zone missing in target, time may be UTC until tzdata is installed" 8 60 || true
        ln -sf "/usr/share/zoneinfo/$zone" "$root"/etc/localtime
    fi

    mkdir -p "$root"/etc/conf.d
    echo "keymap=\"$keymap\"" > "$root"/etc/conf.d/keymaps

    echo "$locale UTF-8" > "$root"/etc/locale.gen
    if ! chroot "$root" /bin/bash -c "locale-gen" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't generate locales, check locale.gen later" 8 40 || true
    fi
    mkdir -p "$root"/etc/env.d
    echo "LANG=\"$locale\"" > "$root"/etc/env.d/02locale

    made_swapfile=""
    if [ -n "${want_swap:-}" ]; then
        if chroot "$root" /bin/bash -c "fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile" 2>/dev/null; then
            made_swapfile="1"
        else
            whiptail --msgbox --title "$title" "couldn't create the swapfile" 8 40 || true
        fi
    fi

    printf 'Welcome to Silen Linux\n' > "$root"/etc/motd 2>/dev/null || true

    cat > "$root"/etc/profile.d/silen-hostname.sh <<'EOF'
if [ -f /etc/hostname ]; then
    HOSTNAME=$(cat /etc/hostname 2>/dev/null)
    export HOSTNAME
fi
EOF
    chmod 644 "$root"/etc/profile.d/silen-hostname.sh 2>/dev/null || true

    cat > "$root"/etc/bash.bashrc <<'EOF'
[ -f /etc/profile.d/silen-hostname.sh ] && . /etc/profile.d/silen-hostname.sh
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi
EOF
    chmod 644 "$root"/etc/bash.bashrc 2>/dev/null || true
}

create-user() {
    [ -n "${newuser:-}" ] || return 0
    if ! chroot "$root" /bin/bash -c "command -v useradd" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser (no useradd in the new system)" 8 60 || true
        return 0
    fi
    usergroups=""
    for g in wheel sudo audio video network plugdev; do
        if chroot "$root" /bin/bash -c "getent group $g" >/dev/null 2>&1; then
            if [ -z "$usergroups" ]; then
                usergroups="$g"
            else
                usergroups="$usergroups,$g"
            fi
        fi
    done || true
    if [ -n "$usergroups" ]; then
        _uflags="-m -s /bin/bash -G $usergroups"
    else
        _uflags="-m -s /bin/bash"
    fi
    if ! chroot "$root" /bin/bash -c "useradd $_uflags $newuser" 2>/dev/null; then
        whiptail --msgbox --title "$title" "couldn't create user $newuser - add it by hand after reboot with useradd" 8 60 || true
        return 0
    fi
    if ! printf '%s:%s\n' "$newuser" "$userpass" | chroot "$root" /bin/bash -c "chpasswd" 2>/dev/null; then
        whiptail --msgbox --title "$title" "user $newuser created but the password couldn't be set - run passwd $newuser after reboot" 8 60 || true
    fi
    userpass=""
    if ! chroot "$root" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
        chroot "$root" /bin/bash -c "usermod -aG wheel $newuser" >/dev/null 2>&1 || true
    fi
    if ! chroot "$root" /bin/bash -c "id -nG $newuser 2>/dev/null | grep -qw wheel" >/dev/null 2>&1; then
        whiptail --msgbox --title "$title" "user $newuser is not in the wheel group, so 'su -' will refuse even the right password. After reboot run as root: usermod -aG wheel $newuser" 9 70 || true
    fi
    if mkdir -p "$root"/home/$newuser/.local/bin \
             "$root"/home/$newuser/.local/share/spk/apps \
             "$root"/home/$newuser/.local/share/spk/packages \
             "$root"/home/$newuser/.cache/spk 2>/dev/null; then
        chroot "$root" /bin/bash -c "chown -R $newuser:$newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || \
        chroot "$root" /bin/bash -c "chown -R $newuser /home/$newuser/.local /home/$newuser/.cache" 2>/dev/null || true
    fi
    chroot "$root" /bin/bash -c "chown $newuser:$(id -gn $newuser 2>/dev/null || echo \$newuser) /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || \
    chroot "$root" /bin/bash -c "chown $newuser /home/$newuser && chmod 755 /home/$newuser" >/dev/null 2>&1 || true
}

install-branding() {
    logo_src=""
    for f in /mnt/branding/fastfetch_logo.txt /mnt/fastfetch_logo.txt; do
        [ -f "$f" ] && logo_src="$f" && break
    done || true
    [ -n "$logo_src" ] || return 0

    mkdir -p "$root"/usr/share/silen
    cp "$logo_src" "$root"/usr/share/silen/fastfetch_logo.txt 2>/dev/null || return 0
    if [ -f /mnt/branding/info.txt ]; then
        cp /mnt/branding/info.txt "$root"/usr/share/silen/info.txt 2>/dev/null || true
    fi

    mkdir -p "$root"/etc/fastfetch "$root"/etc/xdg/fastfetch "$root"/etc/skel/.config/fastfetch "$root"/root/.config/fastfetch
    cat > "$root"/etc/fastfetch/config.jsonc <<'EOF'
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
    cp "$root"/etc/fastfetch/config.jsonc "$root"/etc/xdg/fastfetch/config.jsonc 2>/dev/null || true
    cp "$root"/etc/fastfetch/config.jsonc "$root"/etc/skel/.config/fastfetch/config.jsonc 2>/dev/null || true
    cp "$root"/etc/fastfetch/config.jsonc "$root"/root/.config/fastfetch/config.jsonc 2>/dev/null || true

    if [ -n "${newuser:-}" ] && [ -d "$root/home/$newuser" ]; then
        mkdir -p "$root"/home/$newuser/.config/fastfetch 2>/dev/null || true
        cp "$root"/etc/fastfetch/config.jsonc "$root"/home/$newuser/.config/fastfetch/config.jsonc 2>/dev/null || true
        chroot "$root" /bin/bash -c "chown -R $newuser /home/$newuser/.config" >/dev/null 2>&1 || \
        chown -R --reference="$root/home/$newuser" "$root/home/$newuser/.config" 2>/dev/null || true
    fi
}

setup-quiet-boot() {
    if [ -f "$root"/etc/inittab ]; then
        sed -i 's#/sbin/openrc \(sysinit\|boot\|shutdown\|single\|nonetwork\|default\|reboot\)#/sbin/openrc --quiet \1#g' \
            "$root"/etc/inittab 2>/dev/null || true
    fi
    if [ -f "$root"/etc/rc.conf ]; then
        if grep -q '^[[:space:]]*rc_logger=' "$root"/etc/rc.conf 2>/dev/null; then
            sed -i 's|^[[:space:]]*rc_logger=.*|rc_logger="YES"|' "$root"/etc/rc.conf 2>/dev/null || true
        elif grep -q 'rc_logger=' "$root"/etc/rc.conf 2>/dev/null; then
            sed -i 's|.*rc_logger=.*|rc_logger="YES"|' "$root"/etc/rc.conf 2>/dev/null || true
        else
            printf '\n# log boot messages to /var/log/rc.log while the console stays quiet\nrc_logger="YES"\n' >> "$root"/etc/rc.conf 2>/dev/null || true
        fi
    fi
}
