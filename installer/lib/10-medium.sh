# finds the install medium, handles ventoy isos too
medium_has_tarball_at() {
	_d="$1"
	for f in "$_d"/stage3-*.tar.* "$_d"/tarball-*.tar.* "$_d"/tarball-*.xz "$_d"/*.tar.xz "$_d"/*.tar.zst; do
		[[ -f "$f" ]] || continue
		case "$(basename "$f")" in
			kernel-*.tar.*|headers-*.tar.*|network.tar.*|spk.tar.*|nvidia-kmods-*.tar.*) continue ;;
		esac
		return 0
	done
	return 1
}

medium_has_tarball() {
	medium_has_tarball_at /mnt
}

ensure_loop_support() {
	modprobe -q loop 2>/dev/null || true
	for _i in 0 1 2 3 4 5 6 7; do
		[[ -b "/dev/loop$_i" ]] || mknod "/dev/loop$_i" b 7 "$_i" 2>/dev/null || true
	done
}

_install_mount_candidate() {
	_dev="$1"
	_mp="$2"
	mount "$_dev" "$_mp" 2>/dev/null && return 0
	mount -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	mount -t iso9660 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	mount -t exfat -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	mount -t vfat -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	mount -t ntfs3 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	mount -t ext4 -o ro "$_dev" "$_mp" 2>/dev/null && return 0
	return 1
}

_install_mount_iso() {
	_iso="$1"
	_mp="$2"
	mount -o loop,ro "$_iso" "$_mp" 2>/dev/null && return 0
	mount -o ro,loop "$_iso" "$_mp" 2>/dev/null && return 0
	mount -o ro "$_iso" "$_mp" 2>/dev/null && return 0
	_loopdev="$(losetup -f 2>/dev/null)" || return 1
	losetup -r "$_loopdev" "$_iso" 2>/dev/null || return 1
	if mount -o ro "$_loopdev" "$_mp" 2>/dev/null; then
		return 0
	fi
	losetup -d "$_loopdev" 2>/dev/null
	return 1
}

medium_on_disk() {
	_disk="$1"
	if [[ -f /run/silen-medium-dev ]]; then
		_rec="$(cat /run/silen-medium-dev 2>/dev/null)"
		if [[ -n "$_rec" ]]; then
			case "$_rec" in
				"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
			esac
		fi
	fi
	_mntsrc="$(mount 2>/dev/null | awk '$3 == "/mnt" {print $1}')"
	case "$_mntsrc" in
		"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
	esac
	case "$_mntsrc" in
		/dev/loop*)
			_loopname="${_mntsrc#/dev/}"
			_backing=""
			[[ -f "/sys/block/$_loopname/loop/backing_file" ]] && _backing="$(cat "/sys/block/$_loopname/loop/backing_file" 2>/dev/null)" || true
			if [[ -z "$_backing" ]]; then
				_backing="$(losetup -a 2>/dev/null | grep "^$_mntsrc:" | sed -n 's/.*(\(.*\)).*/\1/p')"
			fi
			if [[ -n "$_backing" ]]; then
				_ventrysrc="$(mount 2>/dev/null | awk '$3 == "/run/ventoy" {print $1}')"
				case "$_ventrysrc" in
					"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
				esac
				if command -v df >/dev/null 2>&1; then
					_backmnt="$(df "$_backing" 2>/dev/null | awk 'NR==2 {print $1}')"
					case "$_backmnt" in
						"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
					esac
				fi
				case "$_backing" in
					"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
				esac
			fi
			;;
	esac
	_ventrysrc="$(mount 2>/dev/null | awk '$3 == "/run/ventoy" {print $1}')"
	case "$_ventrysrc" in
		"$_disk"|"$_disk"[0-9]*|"$_disk"p[0-9]*) return 0 ;;
	esac
	return 1
}

rescan_medium() {
	ensure_loop_support
	mkdir -p /mnt /run/ventoy /run/scan /iso /tmp 2>/dev/null || true
	_cands=""
	for _blk in /sys/block/*; do
		[[ -d "$_blk" ]] || continue
		_name="${_blk##*/}"
		case "$_name" in
			loop*|ram*|zram*|fd*) continue ;;
		esac
		_cands="$_cands /dev/$_name"
		for _part in "$_blk/$_name"?*; do
			[[ -e "$_part" ]] || continue
			_pn="${_part##*/}"
			case "$_pn" in
				loop*|ram*|zram*) continue ;;
			esac
			_cands="$_cands /dev/$_pn"
		done || true
	done || true
	for _dm in /dev/mapper/*; do
		[[ -e "$_dm" ]] || continue
		case " $_cands " in
			*" $_dm "*) ;;
			*) _cands="$_cands $_dm" ;;
		esac
	done || true
	for _d in /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z] /dev/nvme[0-9]*n[0-9]* /dev/mmcblk[0-9]* /dev/sr[0-9]*; do
		[[ -b "$_d" ]] || continue
		case " $_cands " in
			*" $_d "*) ;;
			*) _cands="$_cands $_d" ;;
		esac
		for _p in "$_d"?* "$_d"p?*; do
			[[ -b "$_p" ]] || continue
			case " $_cands " in
				*" $_p "*) ;;
				*) _cands="$_cands $_p" ;;
			esac
		done || true
	done || true
	for _dev in $_cands; do
		[[ -b "$_dev" ]] || continue
		umount /run/scan 2>/dev/null || true
		_install_mount_candidate "$_dev" /run/scan || continue
		if medium_has_tarball_at /run/scan; then
			umount /mnt 2>/dev/null || true
			if mount --move /run/scan /mnt 2>/dev/null; then
				:
			else
				umount /mnt 2>/dev/null || true
				_install_mount_candidate "$_dev" /mnt || { umount /run/scan 2>/dev/null || true; continue; }
				umount /run/scan 2>/dev/null || true
			fi
			echo "$_dev" > /run/silen-medium-dev 2>/dev/null || true
			return 0
		fi
		rm -f /tmp/.isolist_install 2>/dev/null || true
		touch /tmp/.isolist_install 2>/dev/null || true
		find /run/scan -maxdepth 4 -iname "*silen*.iso" 2>/dev/null | head -n 20 >> /tmp/.isolist_install || true
		find /run/scan -maxdepth 4 -iname "*.iso" 2>/dev/null | head -n 20 >> /tmp/.isolist_install || true
		_tried=""
		_found=""
		while IFS= read -r _iso; do
			[[ -n "$_iso" ]] || continue
			[[ -f "$_iso" ]] || continue
			case "$_tried" in
				*"|$_iso|"*) continue ;;
			esac
			_tried="$_tried|$_iso|"
			umount /iso 2>/dev/null || true
			_install_mount_iso "$_iso" /iso || continue
			if medium_has_tarball_at /iso; then
				umount /mnt 2>/dev/null || true
				if mount --move /run/scan /run/ventoy 2>/dev/null; then
					:
				else
					_install_mount_candidate "$_dev" /run/ventoy 2>/dev/null || mount -o bind /run/scan /run/ventoy 2>/dev/null || true
				fi
				if mount --move /iso /mnt 2>/dev/null; then
					:
				else
					umount /mnt 2>/dev/null || true
					if ! _install_mount_iso "$_iso" /mnt; then
						_rel="${_iso#/run/scan/}"
						if [[ "$_rel" != "$_iso" ]] && [[ -f "/run/ventoy/$_rel" ]]; then
							_install_mount_iso "/run/ventoy/$_rel" /mnt || continue
						else
							continue
						fi
					fi
					umount /iso 2>/dev/null || true
				fi
				if mountpoint -q /run/scan 2>/dev/null && mountpoint -q /run/ventoy 2>/dev/null; then
					umount /run/scan 2>/dev/null || true
				fi
				echo "$_dev" > /run/silen-medium-dev 2>/dev/null || true
				echo "$_iso" > /run/silen-medium-iso 2>/dev/null || true
				_found="1"
				break
			fi
			umount /iso 2>/dev/null || true
		done < /tmp/.isolist_install || true
		rm -f /tmp/.isolist_install 2>/dev/null || true
		umount /run/scan 2>/dev/null || true
		umount /iso 2>/dev/null || true
		[[ -n "$_found" ]] && return 0
	done || true
	umount /run/scan 2>/dev/null || true
	return 1
}

ensure_medium() {
	if medium_has_tarball; then
		return 0
	fi
	rescan_medium || true
	if medium_has_tarball; then
		return 0
	fi
	return 1
}
