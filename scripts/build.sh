#!/bin/bash
set -e
set -E
set -o pipefail

trap 'rc=$?; echo; echo "!! Build stopped with an error (exit $rc at line $LINENO: $BASH_COMMAND) See the message above"; echo "   Remove build/ if needed: sudo rm -rf build" >&2' ERR
DEFAULT_KVER=""
for _kv in rootfs/lib/modules/[0-9]*; do
	[ -d "$_kv" ] || continue
	DEFAULT_KVER="${_kv##*/}"
	break
done
KERNEL_VERSION="${KERNEL_VERSION:-${DEFAULT_KVER:-6.18.54-silen}}"
KERNEL_SOURCE="${KERNEL_SOURCE:-boot/vmlinuz}"
MODULES_SOURCE="${MODULES_SOURCE:-rootfs/lib/modules/$KERNEL_VERSION}"
FIRMWARE_SOURCE="${FIRMWARE_SOURCE:-rootfs/lib/firmware}"
HOST_FIRMWARE="${HOST_FIRMWARE:-/lib/firmware}"
BUSYBOX_SOURCE="${BUSYBOX_SOURCE:-rootfs/bin/busybox}"
INIT_SOURCE="${INIT_SOURCE:-rootfs/init}"
IWD_ROOT="${IWD_ROOT:-build/iwd-root}"

RAMROOT="build/initramfs-root"
ISO_DIR="build/iso"
RESULT="build/silen-linux.iso"
if [ "${NVIDIA:-0}" = "1" ]; then
	RESULT="build/silen-linux-nvidia.iso"
fi

COMPRESS="${COMPRESS:-zstd}"   
AUTO_HOST="${AUTO_HOST:-0}"    
FULL="${FULL:-0}"             
FORCE="${FORCE:-0}"            
MIN_RAM_MB="${MIN_RAM_MB:-2048}"
MIN_DISK_MB="${MIN_DISK_MB:-2048}"
NVIDIA="${NVIDIA:-0}"

ALLOW="
	ahci libahci ata_piix sd_mod sr_mod cdrom nvme nvme_core nvme_auth nvme_common vmd
	mmc_block sdhci sdhci-pci sdhci-acpi
	virtio_blk virtio_scsi virtio_pci virtio_console virtio_input
	xhci-pci ehci-pci ohci-pci uhci-hcd usb-storage uas usbhid hid-generic
	virtio_net e1000 e1000e r8169 tg3 igb ixgbe r8152 ax88179_178a
	# wired nics people actually have, firmware rides along automatically
	bnx2 bnx2x be2net sfc thunderbolt
	ext4 jbd2 mbcache crc32c_intel vfat fat fuse squashfs ntfs3 btrfs xfs isofs
	nls_utf8 nls_cp437 nls_iso8859-1 dm_mod md_mod loop
	i8042 psmouse
	exfat cdc_ether rndis_host rndis_wlan alx 8139too via-rhine
	bochs cirrus-qemu qxl virtio-gpu vboxvideo vmwgfx
	drm drm_kms_helper ttm
	amdgpu radeon nouveau i915 xe
	evdev hid hid-generic usbhid
	input-core uinput joydev
	snd snd_pcm snd_timer soundcore
"

ALLOW_WIFI="
	cfg80211 mac80211 rfkill
	iwlwifi iwlmvm iwlmld iwldvm iwlegacy
	ipw2100 ipw2200
	ath9k ath9k_htc ath5k
	ath10k_core ath10k_pci ath10k_sdio ath10k_usb
	ath11k ath11k_pci ath12k
	ath6kl_usb ath6kl_sdio
	carl9170
	ar5523
	wil6210
	zd1211rw
	mt7601u
	mt7921e mt7921u mt7921s mt7925e mt7925u
	mt7915e mt7615e mt7663u mt7663s mt7603e mt7996e
	mt76x0u mt76x0e mt76x2u mt76x2e
	rtl8xxxu
	rtw88_pci rtw88_usb rtw88_sdio
	rtw88_8822be rtw88_8822ce rtw88_8822bu rtw88_8822cu
	rtw88_8821ce rtw88_8821cu rtw88_8821au
	rtw88_8723d rtw88_8723de rtw88_8723ds rtw88_8723du
	rtw88_8703b rtw88_8812au rtw88_8814ae rtw88_8814au
	rtw89_pci rtw89_usb
	rtw89_8851be rtw89_8851bu
	rtw89_8852ae rtw89_8852au rtw89_8852be rtw89_8852bu rtw89_8852ce rtw89_8852cu rtw89_8852bt
	rtw89_8922ae rtw89_8922au
	rtlwifi rtl_pci rtl_usb
	rtl8192ce rtl8192cu rtl8192de rtl8192se
	rtl8188ee rtl8723ae rtl8723be rtl8821ae
	brcmfmac brcmsmac b43 b43legacy bcma ssb
	wl12xx wl18xx wlcore wl1251 wl1251_sdio wl1251_spi wlcore_sdio
	mwifiex_pcie mwifiex_usb mwifiex_sdio
	libertas libertas_tf libertas_sdio usb8xxx
	mwl8k
	p54pci p54usb
	at76c50x-usb adm8211
	rsi_usb rsi_sdio
	wfx
	wilc1000 wilc1000-sdio wilc1000-spi
	rt2400pci rt2500pci rt61pci rt2800pci
	rt2500usb rt73usb rt2800usb
"

BLACKLIST="
	nvidia
	nvidia_drm
	nvidia_modeset
	nvidia_uvm
	zfs
	zcommon
	znvpair
	zlua
	zavl
	zunicode
	icp
	splat
"

case "$COMPRESS" in
	zstd) INITRAMFS="initramfs.zst" ;;
	gzip) INITRAMFS="initramfs.gz"  ;;
	xz)   INITRAMFS="initramfs.xz"  ;;
	*)    echo "Unknown COMPRESS=$COMPRESS (use zstd, gzip or xz)"; exit 1 ;;
esac

echo "== Silen Linux ISO builder =="
echo "compression $COMPRESS   auto-detect host modules $AUTO_HOST   full module tree $FULL"
echo

modules_ok() {
	[ -d "$1" ] || return 1
	[ -n "$(find "$1" \( -name '*.ko' -o -name '*.ko.zst' \) -print -quit 2>/dev/null)" ]
}

if ! modules_ok "$MODULES_SOURCE"; then
	echo "  kernel module tree not found $MODULES_SOURCE"
	echo "  auto-detecting host kernel instead"
	HOST_VER="$(uname -r 2>/dev/null || true)"
	HOST_MODS="/usr/lib/modules/$HOST_VER"
	if [ -n "$HOST_VER" ] && modules_ok "$HOST_MODS"; then
		echo "  using host kernel $HOST_VER"
		echo "     modules from $HOST_MODS"
		KERNEL_VERSION="$HOST_VER"
		MODULES_SOURCE="$HOST_MODS"
		for _kv in "$HOST_MODS/vmlinuz" "/boot/vmlinuz-$HOST_VER" /boot/vmlinuz; do
			[ -f "$_kv" ] || continue
			KERNEL_SOURCE="$_kv"
			break
		done
	else
		echo
		echo "  No usable module tree found anywhere. You must provide one, e.g.:"
		echo "      for a specific kernel: KERNEL_VERSION=... make iso"
		echo "      with the host kernel:  (the script auto-detects it)"
		echo
		echo "  ENV overrides: KERNEL_VERSION=foo KERNEL_SOURCE=/path/vmlinuz \\"
		echo "                 MODULES_SOURCE=/path/modules make iso"
		exit 1
	fi
fi

if [ ! -f "$KERNEL_SOURCE" ]; then
	echo "  ERROR kernel image not found $KERNEL_SOURCE"
	echo "  Set KERNEL_SOURCE=/path/to/vmlinuz or put one at boot/vmlinuz"
	exit 1
fi

echo "  kernel    $KERNEL_SOURCE"
echo "  modules   $MODULES_SOURCE"

if ! command -v grub-mkrescue >/dev/null 2>&1; then
	echo "  ERROR grub-mkrescue not found"
	echo "  Install it first e.g. on Arch sudo pacman -S grub xorriso mtools dosfstools"
	exit 1
fi

AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
if [ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt "$MIN_RAM_MB" ] && [ "$FORCE" != "1" ]; then
	echo "  ERROR only ${AVAIL_MB}MB RAM available need ${MIN_RAM_MB}MB"
	echo "  Close heavy apps first or rerun with FORCE=1 to try anyway"
	exit 1
fi


echo "[1/7] Cleaning old build"

_IWD_KEEP=""
for _keep in iwd-root iwd-src nvidia-dl; do
	[ -e "build/$_keep" ] || continue
	if [ -z "$_IWD_KEEP" ]; then
		_IWD_KEEP="$(mktemp -d /tmp/silen-iwd-keep.XXXXXX 2>/dev/null || echo /tmp/silen-iwd-keep.$$)" || true
		mkdir -p "$_IWD_KEEP" 2>/dev/null || true
	fi
	mv "build/$_keep" "$_IWD_KEEP/" 2>/dev/null || true
done || true

if [ -d build ]; then
	rm -rf build 2>/dev/null || true
fi

if [ -d build ]; then
	echo "  build/ is root-owned using sudo"
	if ! sudo -n rm -rf build 2>/dev/null; then
		echo "  ERROR cannot remove build/ without typing a sudo password"
		echo "  Fix it yourself once then rerun this script"
		echo "      sudo rm -rf $(pwd)/build"
		exit 1
	fi
fi

if [ -n "$_IWD_KEEP" ]; then
	mkdir -p build 2>/dev/null || true
	for _keep in iwd-root iwd-src nvidia-dl; do
		[ -e "$_IWD_KEEP/$_keep" ] || continue
		mv "$_IWD_KEEP/$_keep" "build/$_keep" 2>/dev/null || true
	done || true
	rm -rf "$_IWD_KEEP" 2>/dev/null || true
fi

FREE_KB=$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt $((MIN_DISK_MB * 1024)) ] && [ "$FORCE" != "1" ]; then
	echo "  ERROR: only $((FREE_KB / 1024))MB free on disk - need at least ${MIN_DISK_MB}MB to build."
	exit 1
fi

echo "[2/7] Building module list"

mod_name_from_path() {
	local n
	n="${1##*/}"
	n="${n%.ko.zst}"
	printf '%s\n' "${n%.ko}"
}

declare -A module_file_by_name
while IFS= read -r path; do
	name="$(mod_name_from_path "$path")"
	if [ -z "${module_file_by_name[$name]:-}" ]; then
		module_file_by_name[$name]="$path"
	fi
done < <(find "$MODULES_SOURCE" \( -name '*.ko' -o -name '*.ko.zst' \))


module_file() {
	local name="$1" alt=""
	if [ -n "${module_file_by_name[$name]:-}" ]; then
		printf '%s\n' "${module_file_by_name[$name]}"
		return 0
	fi
	alt="${name//_/-}"
	if [ "$alt" != "$name" ] && [ -n "${module_file_by_name[$alt]:-}" ]; then
		printf '%s\n' "${module_file_by_name[$alt]}"
		return 0
	fi
	alt="${name//-/_}"
	if [ "$alt" != "$name" ] && [ -n "${module_file_by_name[$alt]:-}" ]; then
		printf '%s\n' "${module_file_by_name[$alt]}"
		return 0
	fi
	return 1
}

is_blacklisted() {
	local name="$1" norm="$1" bad
	norm="${norm//_/-}"
	for bad in $BLACKLIST; do
		bad="${bad//_/-}"
		if [ "$norm" = "$bad" ]; then
			return 0
		fi
	done
	return 1
}

if [ "$FULL" = "1" ]; then
	queue=()
	while IFS= read -r path; do
		queue+=("$(mod_name_from_path "$path")")
	done < <(find "$MODULES_SOURCE" \( -name '*.ko' -o -name '*.ko.zst' \))
else
	queue=($ALLOW $ALLOW_WIFI)
	if [ "$AUTO_HOST" = "1" ]; then
		for _mp in /sys/module/*; do
			[ -e "$_mp" ] || continue
			queue+=("${_mp##*/}")
		done
	fi
fi

chosen=()
already_done=" "

while [ ${#queue[@]} -gt 0 ]; do
	name="${queue[0]}"
	queue=("${queue[@]:1}")

	[ -z "$name" ] && continue

	case " $already_done " in
		*" $name "*) continue ;;
	esac
	already_done="$already_done $name "

	is_blacklisted "$name" && continue

	path="$(module_file "$name" || true)"
	[ -z "$path" ] && continue

	chosen+=("$name")

	deps="$(modinfo -F depends "$path" 2>/dev/null || true)"
	for dep in ${deps//,/ }; do
		[ -n "$dep" ] && queue+=("$dep")
	done
done

echo "  ${#chosen[@]} modules selected"


echo "[3/7] Setting up ramdisk root"

mkdir -p "$RAMROOT/bin"
mkdir -p "$RAMROOT/sbin"
mkdir -p "$RAMROOT/etc"
mkdir -p "$RAMROOT/dev"
mkdir -p "$RAMROOT/proc"
mkdir -p "$RAMROOT/sys"
mkdir -p "$RAMROOT/tmp"
mkdir -p "$RAMROOT/run"
mkdir -p "$RAMROOT/mnt"
mkdir -p "$RAMROOT/root"
mkdir -p "$RAMROOT/lib64"
mkdir -p "$RAMROOT/usr/lib64"
mkdir -p "$RAMROOT/lib/modules"

cp "$BUSYBOX_SOURCE" "$RAMROOT/bin/busybox"

for _ld in /lib64/ld-linux-x86-64.so.2 /usr/lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2; do
	[ -f "$_ld" ] || continue
	cp --dereference "$_ld" "$RAMROOT/lib64/ld-linux-x86-64.so.2" 2>/dev/null && break
done
for _clib in /usr/lib64/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/libc.so.6; do
	[ -f "$_clib" ] || continue
	cp --dereference "$_clib" "$RAMROOT/usr/lib64/libc.so.6" 2>/dev/null && break
done
for _mlib in /usr/lib64/libm.so.6 /lib/x86_64-linux-gnu/libm.so.6 /usr/lib/libm.so.6; do
	[ -f "$_mlib" ] || continue
	cp --dereference "$_mlib" "$RAMROOT/usr/lib64/libm.so.6" 2>/dev/null && break
done
for _rlib in /usr/lib64/libresolv.so.2 /lib/x86_64-linux-gnu/libresolv.so.2 /usr/lib/libresolv.so.2; do
	[ -f "$_rlib" ] || continue
	cp --dereference "$_rlib" "$RAMROOT/usr/lib64/libresolv.so.2" 2>/dev/null && break
done
[ -f "$RAMROOT/lib64/ld-linux-x86-64.so.2" ] || { echo "  ERROR dynamic loader not found install it first"; exit 1; }
[ -f "$RAMROOT/usr/lib64/libc.so.6" ] || { echo "  ERROR libc.so.6 copy failed install it first"; exit 1; }
[ -f "$RAMROOT/usr/lib64/libm.so.6" ] || echo "  ! libm.so.6 not copied some tools may fail"
[ -f "$RAMROOT/usr/lib64/libresolv.so.2" ] || echo "  ! libresolv.so.2 not copied DNS may fail in live env"

cat > "$RAMROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

cat > "$RAMROOT/etc/group" <<'EOF'
root:x:0:
EOF

cat > "$RAMROOT/etc/hosts" <<'EOF'
127.0.0.1   localhost
EOF

touch "$RAMROOT/etc/fstab"

_applets="$("$BUSYBOX_SOURCE" --list 2>/dev/null)" || _applets=""
if [ -z "$_applets" ]; then
	echo "  ERROR busybox --list failed ($BUSYBOX_SOURCE unusable)"
	exit 1
fi
for applet in $_applets; do
	ln -sf busybox "$RAMROOT/bin/$applet"
done
[ -x "$RAMROOT/bin/sh" ] && [ -x "$RAMROOT/bin/mount" ] || { echo "  ERROR busybox applets missing sh/mount"; exit 1; }

libs_seen=" "
copy_libs() {
	local bin="$1" lib
	[ -f "$bin" ] || return 0
	mkdir -p "$RAMROOT/usr/lib64"
	if ldd "$bin" 2>/dev/null | grep -q '=> not found'; then
		echo "  ! $bin has missing libs:"
		ldd "$bin" 2>/dev/null | grep '=> not found' | sed 's/^/    /' || true
	fi
	while IFS= read -r lib; do
		lib="$(printf '%s' "$lib" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
		[ -n "$lib" ] || continue
		case "$lib" in
			/*) ;;
			*) continue ;;
		esac
		case "$lib" in
			*linux-vdso*|*linux-gate*) continue ;;
		esac
		case " $libs_seen " in
			*" $lib "*) continue ;;
		esac
		libs_seen="$libs_seen $lib "
		if [ ! -e "$lib" ]; then
			echo "  ! missing lib $lib (needed by $bin)"
			continue
		fi
		cp --dereference "$lib" "$RAMROOT/usr/lib64/" 2>/dev/null || echo "  ! cannot copy lib $lib (needed by $bin)"
		copy_libs "$lib"
	done < <(ldd "$bin" 2>/dev/null | grep -o '/[^ ()]*' | sort -u || true)

}

copy_app() {
	local dest="$1"
	local src="$2"
	if [ ! -e "$src" ]; then
		echo "  ERROR required tool missing: $src (install it first)"
		exit 1
	fi
	mkdir -p "$RAMROOT/usr/bin" || { echo "  ERROR cannot create $RAMROOT/usr/bin"; exit 1; }
	cp --dereference "$src" "$RAMROOT/usr/bin/$dest" || { echo "  ERROR cannot copy $src (disk full?)"; exit 1; }
	copy_libs "$src"
}
copy_opt() {
	local dest="$1"
	local src="$2"
	[ -e "$src" ] || return 0
	mkdir -p "$RAMROOT/usr/bin" || { echo "  ERROR cannot create $RAMROOT/usr/bin"; exit 1; }
	cp --dereference "$src" "$RAMROOT/usr/bin/$dest" || { echo "  ! cannot copy optional $src"; return 0; }
	copy_libs "$src"
}

if [ -f /usr/bin/bash ]; then copy_app bash /usr/bin/bash; ln -sf /usr/bin/bash "$RAMROOT/bin/bash" 2>/dev/null || true; elif [ -f /bin/bash ]; then copy_app bash /bin/bash; ln -sf /usr/bin/bash "$RAMROOT/bin/bash" 2>/dev/null || true; else echo "  ERROR bash not found but installer needs it"; exit 1; fi
copy_app whiptail /usr/bin/whiptail
copy_app dbus-uuidgen /usr/bin/dbus-uuidgen

_IWD_DAEMON=""
for _cand in "$IWD_ROOT/usr/libexec/iwd" /usr/libexec/iwd /usr/sbin/iwd /usr/bin/iwd; do
	[ -x "$_cand" ] || [ -f "$_cand" ] || continue
	_IWD_DAEMON="$_cand"
	break
done
_IWCTL=""
for _cand in "$IWD_ROOT/usr/bin/iwctl" /usr/bin/iwctl /usr/sbin/iwctl; do
	[ -x "$_cand" ] || [ -f "$_cand" ] || continue
	_IWCTL="$_cand"
	break
done
_IWMON=""
for _cand in "$IWD_ROOT/usr/bin/iwmon" /usr/bin/iwmon /usr/sbin/iwmon; do
	[ -x "$_cand" ] || [ -f "$_cand" ] || continue
	_IWMON="$_cand"
	break
done
if [ -z "$_IWD_DAEMON" ]; then
	echo "  ERROR iwd daemon not found (checked $IWD_ROOT and the host)"
	echo "  Build it first with ./scripts/build-iwd.sh or install iwd on the host"
	exit 1
fi
if [ -z "$_IWCTL" ]; then
	echo "  ERROR iwctl not found (checked $IWD_ROOT and the host)"
	echo "  Build it first with ./scripts/build-iwd.sh or install iwd on the host"
	exit 1
fi
mkdir -p "$RAMROOT/usr/libexec" || { echo "  ERROR cannot create $RAMROOT/usr/libexec"; exit 1; }
cp --dereference "$_IWD_DAEMON" "$RAMROOT/usr/libexec/iwd" || { echo "  ERROR cannot copy iwd (disk full?)"; exit 1; }
ln -sf /usr/libexec/iwd "$RAMROOT/usr/bin/iwd" 2>/dev/null || true
copy_libs "$_IWD_DAEMON"
copy_app iwctl "$_IWCTL"
[ -n "$_IWMON" ] && copy_opt iwmon "$_IWMON"

copy_app mkfs.ext4 /usr/sbin/mkfs.ext4
copy_app mkfs.vfat /usr/sbin/mkfs.vfat
if [ -f /usr/bin/blkid ]; then copy_app blkid /usr/bin/blkid; elif [ -f /usr/sbin/blkid ]; then copy_app blkid /usr/sbin/blkid; else echo "  ERROR required tool missing: blkid (install it first)"; exit 1; fi
if [ -f /usr/bin/sfdisk ]; then copy_app sfdisk /usr/bin/sfdisk; elif [ -f /usr/sbin/sfdisk ]; then copy_app sfdisk /usr/sbin/sfdisk; else echo "  ERROR required tool missing: sfdisk (install it first)"; exit 1; fi
if [ -f /usr/bin/mkfs.btrfs ]; then copy_app mkfs.btrfs /usr/bin/mkfs.btrfs; elif [ -f /usr/sbin/mkfs.btrfs ]; then copy_app mkfs.btrfs /usr/sbin/mkfs.btrfs; else echo "  ! mkfs.btrfs not found btrfs installs will fail"; fi
copy_app tar     /usr/bin/tar
ln -sf /usr/bin/tar "$RAMROOT/bin/tar"
ln -sf /usr/bin/blkid    "$RAMROOT/bin/blkid"
ln -sf /usr/bin/mkfs.vfat "$RAMROOT/bin/mkfs.vfat"
ln -sf /usr/bin/mkfs.ext4 "$RAMROOT/bin/mkfs.ext4"
copy_app zstd    /usr/bin/zstd
ln -sf /usr/bin/zstd "$RAMROOT/bin/zstd"

copy_app git  /usr/bin/git
copy_app curl /usr/bin/curl

if [ -d /usr/lib/git-core ]; then
	mkdir -p "$RAMROOT/usr/lib/git-core"
	cp -a /usr/lib/git-core/. "$RAMROOT/usr/lib/git-core/"
fi
for helper in git-remote-http git-http-fetch git-http-push git-http-backend git-imap-send git-daemon; do
	copy_libs "/usr/lib/git-core/$helper"
done

if [ -d /usr/share/git-core/templates ]; then
	mkdir -p "$RAMROOT/usr/share/git-core"
	cp -a /usr/share/git-core/templates "$RAMROOT/usr/share/git-core/"
fi

mkdir -p "$RAMROOT/etc/ssl/certs"
if [ -f /etc/ca-certificates/extracted/tls-ca-bundle.pem ]; then
	cp /etc/ca-certificates/extracted/tls-ca-bundle.pem "$RAMROOT/etc/ssl/certs/ca-certificates.crt"
elif [ -f /etc/ssl/certs/ca-certificates.crt ]; then
	cp /etc/ssl/certs/ca-certificates.crt "$RAMROOT/etc/ssl/certs/ca-certificates.crt"
else
	echo "  ! no CA bundle found https may fail in live env"
fi
[ -f /etc/ssl/openssl.cnf ] && cp /etc/ssl/openssl.cnf "$RAMROOT/etc/ssl/openssl.cnf" || true

copy_app dbus-daemon  /usr/bin/dbus-daemon
mkdir -p "$RAMROOT/usr/sbin" || { echo "  ERROR cannot create $RAMROOT/usr/bin"; exit 1; }
for _sbin_link in mkfs.ext4 mkfs.vfat blkid; do
	ln -sf "/usr/bin/$_sbin_link" "$RAMROOT/usr/sbin/$_sbin_link" 2>/dev/null || true
done
[ -f /usr/bin/rfkill ] && copy_opt rfkill /usr/bin/rfkill
[ -f /usr/bin/iw ] && copy_opt iw /usr/bin/iw
[ -f /usr/sbin/rfkill ] && { copy_opt rfkill /usr/sbin/rfkill; ln -sf /usr/bin/rfkill "$RAMROOT/usr/sbin/rfkill" 2>/dev/null || true; }
[ -f /usr/sbin/iw ] && { copy_opt iw /usr/sbin/iw; ln -sf /usr/bin/iw "$RAMROOT/usr/sbin/iw" 2>/dev/null || true; }
[ -f /usr/bin/efibootmgr ] && copy_opt efibootmgr /usr/bin/efibootmgr
[ -f /usr/sbin/efibootmgr ] && { copy_opt efibootmgr /usr/sbin/efibootmgr; ln -sf /usr/bin/efibootmgr "$RAMROOT/usr/sbin/efibootmgr" 2>/dev/null || true; }
for _dbus_helper in /usr/lib/dbus-daemon-launch-helper /usr/libexec/dbus-daemon-launch-helper; do
	[ -f "$_dbus_helper" ] || continue
	_helper_rel="${_dbus_helper#/}"
	mkdir -p "$RAMROOT/$(dirname "$_helper_rel")"
	if cp -a "$_dbus_helper" "$RAMROOT/$_helper_rel" 2>/dev/null; then
		chmod 4755 "$RAMROOT/$_helper_rel" 2>/dev/null || true
		copy_libs "$_dbus_helper"
	else
		echo "  ! cannot copy $_dbus_helper (build as root so live wifi works)"
	fi
done
if [ ! -e "$RAMROOT/usr/lib/dbus-daemon-launch-helper" ] && [ ! -e "$RAMROOT/usr/libexec/dbus-daemon-launch-helper" ]; then
	echo "  ! no dbus-daemon-launch-helper copied wifi activation may fail"
fi

mkdir -p "$RAMROOT/var/lib/dbus" "$RAMROOT/etc"
# no fixed machine-id, every boot makes its own or clones break stuff
rm -f "$RAMROOT/etc/machine-id" "$RAMROOT/var/lib/dbus/machine-id" 2>/dev/null || true

mkdir -p "$RAMROOT/usr/share/dbus-1/system.d"
_IWD_POLICY=""
for _cand in "$IWD_ROOT/usr/share/dbus-1/system.d/iwd-dbus.conf" /usr/share/dbus-1/system.d/iwd-dbus.conf; do
	[ -f "$_cand" ] || continue
	_IWD_POLICY="$_cand"
	break
done
if [ -n "$_IWD_POLICY" ]; then
	cp "$_IWD_POLICY" "$RAMROOT/usr/share/dbus-1/system.d/"
else
	echo "  ! iwd dbus policy missing (D-Bus will deny iwd)"
fi
if [ -f /usr/share/dbus-1/system.conf ]; then sed -e '/<user>.*<\/user>/d' -e '/<fork\/>/d' /usr/share/dbus-1/system.conf > "$RAMROOT/usr/share/dbus-1/system.conf"; else echo "  ! dbus system.conf missing"; fi

mkdir -p "$RAMROOT/etc/iwd"
cat > "$RAMROOT/etc/iwd/main.conf" <<'EOF'
[General]
EnableNetworkConfiguration=true
EOF

cat > "$RAMROOT/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
EOF

mkdir -p "$RAMROOT/usr/share/terminfo/l"
mkdir -p "$RAMROOT/usr/share/terminfo/x"
mkdir -p "$RAMROOT/usr/share/terminfo/v"
mkdir -p "$RAMROOT/usr/share/terminfo/s"
for _ti in "l/linux" "x/xterm" "x/xterm-256color" "v/vt100" "s/screen"; do
	[ -f "/usr/share/terminfo/$_ti" ] && cp "/usr/share/terminfo/$_ti" "$RAMROOT/usr/share/terminfo/$_ti" 2>/dev/null || echo "  ! terminfo $_ti missing"
done

printf '/lib64\n/usr/lib64\n/usr/lib\n/lib\n' > "$RAMROOT/etc/ld.so.conf" || { echo "  ERROR cannot write ld.so.conf"; exit 1; }
# nss never shows up in ldd so copy it by hand or dns dies on live
for _n in libnss_dns.so.2 libnss_files.so.2; do
	_nss=""
	for _cand in /usr/lib64/$_n /lib64/$_n /usr/lib/x86_64-linux-gnu/$_n /lib/x86_64-linux-gnu/$_n /usr/lib/$_n; do
		[ -e "$_cand" ] || continue
		_nss="$_cand"
		break
	done
	[ -n "$_nss" ] || continue
	if command -v file >/dev/null 2>&1; then
		case "$(file -L -b "$_nss" 2>/dev/null)" in
			*32-bit*) continue ;;
		esac
	fi
	cp --dereference "$_nss" "$RAMROOT/usr/lib64/" 2>/dev/null || echo "  ! cannot copy $_nss (live DNS may fail)"
done
touch "$RAMROOT/etc/resolv.conf" 2>/dev/null || true
if ! ldconfig -r "$RAMROOT" 2>/dev/null; then
	echo "  ERROR ldconfig failed (dynamic apps will not load)"
	exit 1
fi
[ -f "$RAMROOT/etc/ld.so.cache" ] || { echo "  ERROR ldconfig produced no cache"; exit 1; }

mkdir -p "$RAMROOT/installer/lib" || { echo "  ERROR cannot create installer dir"; exit 1; }
cp installer/main.sh "$RAMROOT/installer/main.sh" || { echo "  ERROR cannot copy installer"; exit 1; }
cp -a installer/lib/. "$RAMROOT/installer/lib/" || { echo "  ERROR cannot copy installer libs"; exit 1; }
chmod 0755 "$RAMROOT/installer/main.sh"
echo "  bash installer ships as fallback if graphics fail; live boot prefers silen-installer (Rust+egui)"

if [ -f scripts/wifi-check.sh ]; then
	cp scripts/wifi-check.sh "$RAMROOT/usr/bin/silen-wifi-check" || { echo "  ERROR cannot copy wifi-check"; exit 1; }
	chmod 0755 "$RAMROOT/usr/bin/silen-wifi-check"
fi
if [ -f scripts/nvidia-check.sh ]; then
	cp scripts/nvidia-check.sh "$RAMROOT/usr/bin/silen-nvidia-check" || { echo "  ERROR cannot copy nvidia-check"; exit 1; }
	chmod 0755 "$RAMROOT/usr/bin/silen-nvidia-check"
fi
if [ -f scripts/lock-ssd.sh ]; then
	cp scripts/lock-ssd.sh "$RAMROOT/usr/bin/lock-ssd" || { echo "  ERROR cannot copy lock-ssd"; exit 1; }
	chmod 0755 "$RAMROOT/usr/bin/lock-ssd"
fi
if [ -f scripts/unlock-ssd.sh ]; then
	cp scripts/unlock-ssd.sh "$RAMROOT/usr/bin/unlock-ssd" || { echo "  ERROR cannot copy unlock-ssd"; exit 1; }
	chmod 0755 "$RAMROOT/usr/bin/unlock-ssd"
fi

cp "$INIT_SOURCE" "$RAMROOT/init" || { echo "  ERROR cannot copy init"; exit 1; }
chmod 0755 "$RAMROOT/init"

echo "  $(du -sh "$RAMROOT/bin" | cut -f1) busybox + applets"


echo "[4/7] Copying modules and firmware"

MODULES_DIR="$RAMROOT/lib/modules/$KERNEL_VERSION"
mkdir -p "$MODULES_DIR"

copy_firmware() {
	local fw="$1" src f
	for src in "$FIRMWARE_SOURCE" "$HOST_FIRMWARE"; do
		[ -n "$src" ] && [ -d "$src" ] || continue
		local found=0
		set -- "$src"/$fw
		for f in "$@"; do
			[ -e "$f" ] || continue
			found=1
			local rel="${f#$src/}"
			if [ -d "$f" ]; then
				mkdir -p "$RAMROOT/lib/firmware/$rel" || { echo "  ERROR cannot create firmware dir $rel"; exit 1; }
				find "$RAMROOT/lib/firmware/$rel" -xtype l -delete 2>/dev/null || true
				cp -an "$f"/. "$RAMROOT/lib/firmware/$rel"/ 2>/dev/null || cp -a "$f"/. "$RAMROOT/lib/firmware/$rel"/ || { echo "  ERROR cannot copy firmware dir $rel"; exit 1; }
			else
				local target="$RAMROOT/lib/firmware/$rel"
				mkdir -p "$(dirname "$target")" || { echo "  ERROR cannot create firmware dir"; exit 1; }
				if [ -L "$target" ] && [ ! -e "$target" ]; then rm -f "$target"; fi
				[ -f "$target" ] || cp "$f" "$target" || { echo "  ERROR cannot copy firmware $rel"; exit 1; }
			fi
		done
		if [ "$found" = 0 ]; then
			set -- "$src"/$fw.zst
			for f in "$@"; do
				[ -e "$f" ] || continue
				found=1
				local rel="${f#$src/}"
				local target="$RAMROOT/lib/firmware/$rel"
				mkdir -p "$(dirname "$target")" || { echo "  ERROR cannot create firmware dir"; exit 1; }
				if [ -L "$target" ] && [ ! -e "$target" ]; then rm -f "$target"; fi
				[ -f "$target" ] || cp "$f" "$target" || { echo "  ERROR cannot copy firmware $rel"; exit 1; }
			done
		fi
		if [ "$found" = 0 ] && [ -f "$src/$fw.zst" ]; then
			local target="$RAMROOT/lib/firmware/$fw.zst"
			mkdir -p "$(dirname "$target")" || { echo "  ERROR cannot create firmware dir"; exit 1; }
			if [ -L "$target" ] && [ ! -e "$target" ]; then rm -f "$target"; fi
			[ -f "$target" ] || cp "$src/$fw.zst" "$target" || { echo "  ERROR cannot copy firmware $fw.zst"; exit 1; }
		fi
	done
}

in_chosen() {
	local name="$1"
	for c in "${chosen[@]}"; do
		[ "$c" = "$name" ] && return 0
	done
	return 1
}

for name in "${chosen[@]}"; do
	path="$(module_file "$name" || true)"
	[ -z "$path" ] && continue

	relative="${path#$MODULES_SOURCE/}"
	mkdir -p "$MODULES_DIR/$(dirname "$relative")" || { echo "  ERROR cannot create $MODULES_DIR/$(dirname "$relative")"; exit 1; }
	cp "$path" "$MODULES_DIR/$relative" || { echo "  ERROR cannot copy module $name (disk full?)"; exit 1; }
	if [ "${relative##*.}" = "zst" ]; then
		zstd -d -f -q "$MODULES_DIR/$relative" || { echo "  ERROR cannot decompress module $name"; exit 1; }
		rm "$MODULES_DIR/$relative"
	fi

	for firmware in $(modinfo -F firmware "$path" 2>/dev/null || true); do
		[ -n "$firmware" ] || continue
		copy_firmware "$firmware"
	done
done

if in_chosen iwlwifi; then
	copy_firmware "iwlwifi-*.ucode*"
fi
if in_chosen rtw88_core; then
	copy_firmware "rtw88"
fi
if in_chosen rtw89_core; then
	copy_firmware "rtw89"
fi
if in_chosen ath10k_core; then
	copy_firmware "ath10k"
fi
if in_chosen ath11k; then
	copy_firmware "ath11k"
fi
if in_chosen ath12k; then
	copy_firmware "ath12k"
fi
if in_chosen ath9k_htc; then
	copy_firmware "ath9k_htc"
fi
if in_chosen brcmfmac; then
	copy_firmware "brcm"
fi
if in_chosen mt76; then
	copy_firmware "mediatek"
fi
if in_chosen mwifiex_pcie || in_chosen mwifiex_usb || in_chosen mwifiex_sdio; then
	copy_firmware "mrvl"
fi
if in_chosen mwl8k; then
	copy_firmware "mwl8k"
fi
if in_chosen libertas || in_chosen libertas_sdio || in_chosen usb8xxx; then
	copy_firmware "libertas"
	copy_firmware "sd8688.bin*"
	copy_firmware "sd8688_helper.bin*"
	copy_firmware "sd8686.bin*"
	copy_firmware "sd8686_helper.bin*"
	copy_firmware "usb8388.bin*"
fi
if in_chosen zd1211rw; then
	copy_firmware "zd1211"
fi
if in_chosen carl9170; then
	copy_firmware "carl9170-1.fw*"
fi
if in_chosen rtl8xxxu; then
	copy_firmware "rtlwifi"
fi
if in_chosen rsi_91x; then
	copy_firmware "rsi"
fi
if in_chosen wfx; then
	copy_firmware "wfx"
fi
if in_chosen wlcore; then
	copy_firmware "ti-connectivity"
fi
if in_chosen ar5523; then
	copy_firmware "ar5523.bin*"
fi
if in_chosen wilc1000; then
	copy_firmware "atmel"
fi
if in_chosen cfg80211; then
	copy_firmware "regulatory.db"
	copy_firmware "regulatory.db.p7s"
fi

if [ -d "$FIRMWARE_SOURCE" ]; then
	echo "  copying ALL wifi firmware from rootfs to initramfs for live ISO"
	mkdir -p "$RAMROOT/lib/firmware" || { echo "  ERROR cannot create firmware dir"; exit 1; }
	find "$RAMROOT/lib/firmware" -xtype l -delete 2>/dev/null || true
	cp -a "$FIRMWARE_SOURCE"/. "$RAMROOT/lib/firmware/" || { echo "  ERROR cannot copy firmware (disk full?)"; exit 1; }
fi

# gpu firmware has to ride along or the screen just stays black after grub
# no nvidia blobs here, way too fat and they need the proprietary driver anyway
for _gpu_fw in amdgpu amd-ucode intel-ucode i915 xe nouveau radeon; do
	for _fwsrc in "$FIRMWARE_SOURCE" "$HOST_FIRMWARE"; do
		[ -n "$_fwsrc" ] && [ -d "$_fwsrc/$_gpu_fw" ] || continue
		mkdir -p "$RAMROOT/lib/firmware/$_gpu_fw" || { echo "  ERROR cannot create firmware dir $_gpu_fw"; exit 1; }
		cp -an "$_fwsrc/$_gpu_fw"/. "$RAMROOT/lib/firmware/$_gpu_fw"/ 2>/dev/null || \
		cp -a "$_fwsrc/$_gpu_fw"/. "$RAMROOT/lib/firmware/$_gpu_fw"/ || { echo "  ERROR cannot copy GPU firmware $_gpu_fw"; exit 1; }
	done
done

cp "$MODULES_SOURCE/modules.builtin" "$MODULES_DIR/modules.builtin" 2>/dev/null || true
cp "$MODULES_SOURCE/modules.builtin.modinfo" "$MODULES_DIR/modules.builtin.modinfo" 2>/dev/null || true
cp "$MODULES_SOURCE/modules.order" "$MODULES_DIR/modules.order" 2>/dev/null || true

echo "  modules   $(du -sh "$MODULES_DIR" | cut -f1)"
echo "  firmware  $(du -sh "$RAMROOT/lib/firmware" 2>/dev/null | cut -f1)"


echo "[5/7] Stripping debug info"

command -v strip >/dev/null 2>&1 || { echo "  ERROR strip not found"; exit 1; }
find "$MODULES_DIR" -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null || true

echo "  modules after strip $(du -sh "$MODULES_DIR" | cut -f1)"

echo "  writing /etc modules"
if [ "${#chosen[@]}" -gt 0 ]; then
	printf '%s\n' "${chosen[@]}" | sort > "$RAMROOT/etc/modules"
else
	echo "  ! WARNING no modules selected (ALLOW list matched nothing)"
	: > "$RAMROOT/etc/modules"
fi

mkdir -p "$RAMROOT/etc/modprobe.d"
printf 'options rtw88_pci disable_aspm=Y\noptions rtw88_core disable_lps_deep=Y\n' > "$RAMROOT/etc/modprobe.d/silen-rtw88.conf"

echo "  generating modules dep"

if [ -x /usr/bin/depmod ]; then
	DEPMOD=/usr/bin/depmod
elif [ -x /sbin/depmod ]; then
	DEPMOD=/sbin/depmod
else
	DEPMOD=depmod
fi
if ! "$DEPMOD" -b "$RAMROOT" "$KERNEL_VERSION"; then
	echo "  ERROR depmod failed (modules will not load)"
	exit 1
fi
[ -f "$MODULES_DIR/modules.dep" ] || [ -f "$MODULES_DIR/modules.dep.bin" ] || { echo "  ERROR depmod produced no modules.dep"; exit 1; }


echo "[5b/7] Live Wayland desktop (instantwm) + Rust installer"
echo "  applies to both 'make iso' and 'make nvidia-iso' (NVIDIA flag only adds the driver payload later)"

if command -v cargo >/dev/null 2>&1; then
	echo "  building silen-installer (Rust + egui port of installer/*.sh)"
	CARGO_ENV=()
	CARGO_AS_USER=""
	if [ -n "${SUDO_USER:-}" ]; then
		_SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
		if [ -n "$_SUDO_HOME" ]; then
			CARGO_ENV+=(RUSTUP_HOME="$_SUDO_HOME/.rustup" CARGO_HOME="$_SUDO_HOME/.cargo")
			if [ "$(id -u)" = "0" ] && command -v sudo >/dev/null 2>&1; then
				CARGO_AS_USER="$SUDO_USER"
			fi
		fi
	fi
	_SI_OK=0
	if [ -n "$CARGO_AS_USER" ]; then
		if sudo -u "$CARGO_AS_USER" env "${CARGO_ENV[@]}" cargo build --release --manifest-path silen-installer/Cargo.toml; then
			_SI_OK=1
		fi
	else
		if env "${CARGO_ENV[@]}" cargo build --release --manifest-path silen-installer/Cargo.toml; then
			_SI_OK=1
		fi
	fi
	if [ "$_SI_OK" = "1" ] && [ -f silen-installer/target/release/silen-installer ]; then
		echo "  installing silen-installer into live ramroot"
		mkdir -p "$RAMROOT/usr/bin" || { echo "  ERROR cannot create usr/bin"; exit 1; }
		cp silen-installer/target/release/silen-installer "$RAMROOT/usr/bin/silen-installer" || { echo "  ERROR cannot copy silen-installer"; exit 1; }
		chmod 0755 "$RAMROOT/usr/bin/silen-installer" 2>/dev/null || true
		copy_libs "$RAMROOT/usr/bin/silen-installer"
		mkdir -p "$RAMROOT/usr/share/applications" || true
		cp silen-installer/target/release/silen-installer "build/silen-installer" 2>/dev/null || true
	else
		echo "  ERROR silen-installer build failed (live ISO needs it)"; exit 1
	fi
else
	echo "  ERROR cargo not found (needed for silen-installer)"; exit 1
fi

echo "  unpacking instantwm + Wayland stack into live ramroot"
for _lp in instantwm instantmenu wl-libs gtk-libs xorg-libs xorg-server xorg-drivers xinit xkb-data dejavu kitty seatd wlroots scenefx vulkan-loader llvm; do
	_spk="spk-pkgs/packages/$_lp/$_lp.spk"
	[ -f "$_spk" ] || continue
	echo "    + $_lp"
	tar -xzpf "$_spk" -C "$RAMROOT" 2>/dev/null || tar -xzf "$_spk" -C "$RAMROOT" 2>/dev/null || echo "  ! cannot unpack $_lp"
done
if [ -x /usr/local/bin/instantwm ] && [ ! -x "$RAMROOT/usr/bin/instantwm" ]; then
	echo "    + instantwm (host fallback)"
	mkdir -p "$RAMROOT/usr/bin" || true
	cp -a /usr/local/bin/instantwm "$RAMROOT/usr/bin/instantwm" 2>/dev/null || true
	chmod 0755 "$RAMROOT/usr/bin/instantwm" 2>/dev/null || true
	[ -x /usr/local/bin/instantwmctl ] && cp -a /usr/local/bin/instantwmctl "$RAMROOT/usr/bin/instantwmctl" 2>/dev/null || true
fi
if [ -x "$RAMROOT/usr/bin/seatd" ] && [ ! -e "$RAMROOT/usr/local/bin/seatd" ]; then
	mkdir -p "$RAMROOT/usr/local/bin" || true
	ln -sf /usr/bin/seatd "$RAMROOT/usr/local/bin/seatd" 2>/dev/null || true
fi
echo "  merging host Mesa/DRI (software rendering for egui/instantwm)"
for _mesa_src in /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib; do
	[ -d "$_mesa_src" ] || continue
	mkdir -p "$RAMROOT/usr/lib64" || true
	for _m in libGL.so* libEGL.so* libGLESv*.so* libgbm.so* libdrm.so* libglapi.so* libxkbcommon.so* libwayland-*.so* libseat.so* libinput.so* libudev.so* libevdev.so* libwacom.so* libmtdev.so* libxkbcommon-x11.so* libEGL_mesa.so* libGLX_mesa.so* liblua*.so* libsystemd.so* libxml2.so* libexpat.so* libffi.so* libpcre2*.so* libz.so* liblzma.so* libbz2.so* libbrotli*.so* libgcc_s.so* libstdc++.so* libGLX_mesa.so* libGLdispatch.so* libOpenGL.so*; do
		for _f in "$_mesa_src"/$_m; do
			[ -e "$_f" ] || continue
			case "$_f" in
				*nvidia*) continue ;;
			esac
			if command -v file >/dev/null 2>&1; then
				case "$(file -L -b "$_f" 2>/dev/null)" in
					*32-bit*) continue ;;
				esac
			elif [ "$_mesa_src" != "/usr/lib64" ] && [ -e "$RAMROOT/usr/lib64/$(basename "$_f")" ]; then
				continue
			fi
			cp --dereference "$_f" "$RAMROOT/usr/lib64/" 2>/dev/null || true
		done
	done
	if [ -d "$_mesa_src/dri" ]; then
		mkdir -p "$RAMROOT/usr/lib64/dri" || true
		for _df in "$_mesa_src"/dri/*; do
			[ -e "$_df" ] || continue
			_db="$(basename "$_df")"
			if [ "$_mesa_src" != "/usr/lib64" ] && [ -e "$RAMROOT/usr/lib64/dri/$_db" ]; then
				continue
			fi
			if command -v file >/dev/null 2>&1; then
				case "$(file -L -b "$_df" 2>/dev/null)" in
					*32-bit*) continue ;;
				esac
			fi
			cp -a "$_df" "$RAMROOT/usr/lib64/dri/" 2>/dev/null || true
		done
	fi
	if [ -d "$_mesa_src/gconv" ]; then
		mkdir -p "$RAMROOT/usr/lib64/gconv" || true
		for _gf in "$_mesa_src"/gconv/*; do
			[ -e "$_gf" ] || continue
			_gb="$(basename "$_gf")"
			if [ "$_mesa_src" != "/usr/lib64" ] && [ -e "$RAMROOT/usr/lib64/gconv/$_gb" ]; then
				continue
			fi
			if command -v file >/dev/null 2>&1; then
				case "$(file -L -b "$_gf" 2>/dev/null)" in
					*32-bit*) continue ;;
				esac
			fi
			cp -a "$_gf" "$RAMROOT/usr/lib64/gconv/" 2>/dev/null || true
		done
	fi
done
# mesa gl vendor file or instantwm never starts, never ship the nvidia one
mkdir -p "$RAMROOT/usr/share/glvnd/egl_vendor.d" || true
if [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then
	cp /usr/share/glvnd/egl_vendor.d/50_mesa.json "$RAMROOT/usr/share/glvnd/egl_vendor.d/" 2>/dev/null || echo "  ! cannot copy mesa egl vendor json"
else
	echo "  ! host 50_mesa.json missing (EGL will fail in live session)"
fi
echo "  resolving remaining live-binary deps via ldd (instantwm/kitty/wofi/waybar/silen-installer)"
for _lb in "$RAMROOT"/usr/bin/*; do
	[ -f "$_lb" ] || continue
	case "$_lb" in
		*.sh|*.log|*.conf|*.desktop) continue ;;
	esac
	if head -c 4 "$_lb" 2>/dev/null | grep -q '^.ELF'; then
		copy_libs "$_lb"
	fi
done
for _font_src in /usr/share/fonts /usr/share/fontconfig; do
	[ -d "$_font_src" ] || continue
	mkdir -p "$RAMROOT/usr/share" || true
	cp -an "$_font_src" "$RAMROOT/usr/share/" 2>/dev/null || cp -a "$_font_src" "$RAMROOT/usr/share/" 2>/dev/null || true
done
if command -v fc-cache >/dev/null 2>&1; then
	mkdir -p "$RAMROOT/usr/bin" || true
	_FC="$(command -v fc-cache)"
	cp --dereference "$_FC" "$RAMROOT/usr/bin/fc-cache" 2>/dev/null || true
	copy_libs "$_FC"
fi
mkdir -p "$RAMROOT/etc/skel/.config/instantwm" "$RAMROOT/root/.config/instantwm" "$RAMROOT/usr/share/wayland-sessions" "$RAMROOT/etc/instantwm" || true
if [ -f "$RAMROOT/usr/share/doc/instantwm/config.toml.example" ]; then
	cp -a "$RAMROOT/usr/share/doc/instantwm/config.toml.example" "$RAMROOT/etc/skel/.config/instantwm/config.toml" 2>/dev/null || true
	cp -a "$RAMROOT/usr/share/doc/instantwm/config.toml.example" "$RAMROOT/root/.config/instantwm/config.toml" 2>/dev/null || true
	for _cfg in "$RAMROOT/etc/skel/.config/instantwm/config.toml" "$RAMROOT/root/.config/instantwm/config.toml" "$RAMROOT/usr/share/doc/instantwm/config.toml.example"; do
		[ -f "$_cfg" ] || continue
		if grep -q '^keybinds = \[\]' "$_cfg" 2>/dev/null; then
			sed -i 's|^keybinds = \[\]|keybinds = [{ modifiers = ["super", "shift"], key = "space", action = { spawn = ["instantmenu_run"] } }]|' "$_cfg" 2>/dev/null || true
		fi
	done
fi
if [ ! -f "$RAMROOT/usr/share/wayland-sessions/instantwm.desktop" ]; then
	cat > "$RAMROOT/usr/share/wayland-sessions/instantwm.desktop" <<'EOF'
[Desktop Entry]
Name=instantwm
Comment=instantWM hybrid tiling window manager
Exec=instantwm --backend drm
Type=Application
DesktopNames=instantwm
EOF
fi
mkdir -p "$RAMROOT/usr/share/applications" || true
cat > "$RAMROOT/usr/share/applications/silen-installer.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Silen Installer
Comment=Install Silen Linux
Exec=silen-installer
Icon=system-software-install
Terminal=false
Categories=System;
EOF
cat > "$RAMROOT/usr/bin/silen-live-wayland" <<'EOF'
#!/bin/sh
# live desktop, no login. compositor first then the installer, drm then x11
LOG=/tmp/live-gui.log
echo "=== silen-live-wayland start ===" >"$LOG" 2>&1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_CURRENT_DESKTOP=instantwm
export XDG_SESSION_DESKTOP=instantwm
export XDG_SESSION_TYPE=wayland
export INSTANTWM_LOG="${INSTANTWM_LOG:-info}"
export SEATD_SOCK="${SEATD_SOCK:-/run/seatd.sock}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
if command -v seatd >/dev/null 2>&1 && [ ! -S "$SEATD_SOCK" ]; then
	seatd -g root >>"$LOG" 2>&1 &
	_i=0
	while [ ! -S "$SEATD_SOCK" ] && [ $_i -lt 50 ]; do
		_i=$((_i + 1))
		sleep 0.1 2>/dev/null || sleep 1
	done
fi
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY" >>"$LOG" 2>&1
ls /dev/dri/card* >>"$LOG" 2>&1 || echo "no /dev/dri/card* (KMS driver or firmware missing?)" >>"$LOG" 2>&1
try_drm() {
	[ -x /usr/bin/instantwm ] || return 1
	ls /dev/dri/card* >/dev/null 2>&1 || return 1
	echo "starting instantwm --backend drm" >>"$LOG" 2>&1
	/usr/bin/instantwm --backend drm >>/tmp/instantwm.log 2>&1 &
	echo $! >/tmp/instantwm.pid 2>/dev/null || true
	return 0
}
try_x11() {
	[ -x /usr/bin/Xorg ] && [ -x /usr/bin/instantwm ] || return 1
	export DISPLAY="${DISPLAY:-:0}"
	echo "starting Xorg $DISPLAY" >>"$LOG" 2>&1
	mkdir -p /tmp/.X11-unix 2>/dev/null || true
	/usr/bin/Xorg "$DISPLAY" vt1 -nolisten tcp -logfile /tmp/xorg.log >>/tmp/xorg.log 2>&1 &
	echo $! >/tmp/xorg.pid 2>/dev/null || true
	i=0
	while [ $i -lt 100 ] && [ ! -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; do
		i=$((i + 1)); sleep 0.1 2>/dev/null || sleep 1
	done
	[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || { echo "Xorg socket never appeared" >>"$LOG" 2>&1; return 1; }
	unset WAYLAND_DISPLAY
	export XDG_SESSION_TYPE=x11
	echo "starting instantwm --backend x11" >>"$LOG" 2>&1
	sleep 1 2>/dev/null || true
	DISPLAY="$DISPLAY" /usr/bin/instantwm --backend x11 >>/tmp/instantwm.log 2>&1 &
	echo $! >/tmp/instantwm.pid 2>/dev/null || true
	sleep 2 2>/dev/null || true
	read -r _p </tmp/instantwm.pid 2>/dev/null || _p=""
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null || { echo "instantwm x11 died at startup" >>"$LOG" 2>&1; return 1; }
	return 0
}
wait_socket() {
	i=0
	while [ $i -lt 150 ]; do
		[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && return 0
		if [ -f /tmp/instantwm.pid ]; then
			read -r _pid </tmp/instantwm.pid 2>/dev/null || _pid=""
			if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
				echo "compositor died while waiting for socket, see /tmp/instantwm.log" >>"$LOG" 2>&1
				return 1
			fi
		fi
		i=$((i + 1)); sleep 0.2 2>/dev/null || sleep 1
	done
	echo "Wayland socket never appeared" >>"$LOG" 2>&1
	return 1
}
cleanup() {
	[ -f /tmp/instantwm.pid ] && read -r _p </tmp/instantwm.pid 2>/dev/null && [ -n "$_p" ] && kill "$_p" 2>/dev/null || true
	[ -f /tmp/xorg.pid ] && read -r _p </tmp/xorg.pid 2>/dev/null && [ -n "$_p" ] && kill "$_p" 2>/dev/null || true
}
_started=""
if try_drm && wait_socket; then
	_started="drm"
	echo "compositor up (drm)" >>"$LOG" 2>&1
else
	cleanup
	if try_x11; then
		_started="x11"
		echo "compositor up (x11 fallback)" >>"$LOG" 2>&1
	fi
fi
if [ -z "$_started" ]; then
	echo "no compositor available" >>"$LOG" 2>&1
	cleanup
	exit 1
fi
touch /tmp/gui-was-up 2>/dev/null || true
(
_wp=0
[ -f /tmp/instantwm.pid ] && read -r _wp </tmp/instantwm.pid 2>/dev/null
_autorecover=0
case " $(cat /proc/cmdline 2>/dev/null) " in
	*" silen.debug "*) _autorecover=1 ;;
esac
_n=0
touch /tmp/.watchdog-mark 2>/dev/null || true
while [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null; do
	sleep 15 2>/dev/null || sleep 15
	_n=$((_n + 1))
	echo "--- watchdog $(date -u 2>/dev/null || date)" >>"$LOG" 2>&1
	ps >>"$LOG" 2>&1 || true
	tail -n 8 /tmp/instantwm.log >>"$LOG" 2>&1 || true
	dmesg 2>/dev/null | tail -n 15 >>"$LOG" 2>&1 || true
	if [ "$_autorecover" = "1" ] && [ $_n -ge 24 ]; then
		if ! ps 2>/dev/null | grep -q "[s]ilen-installer"; then
			if [ /tmp/instantwm.log -ot /tmp/.watchdog-mark ]; then
				echo "watchdog: installer never started and compositor log stale, recovering to shell" >>"$LOG" 2>&1
				kill "$_wp" 2>/dev/null || true
				sleep 3
				kill -9 "$_wp" 2>/dev/null || true
				break
			fi
		fi
	fi
	touch /tmp/.watchdog-mark 2>/dev/null || true
done
) &
if command -v kitty >/dev/null 2>&1; then
	(kitty sh -c 'echo Silen live terminal; exec sh' >>/tmp/kitty.log 2>&1 &) || true
fi
if [ -x /usr/bin/silen-installer ]; then
	echo "launching installer" >>"$LOG" 2>&1
	/usr/bin/silen-installer >>/tmp/silen-installer.log 2>&1
	echo "installer exited rc=$?" >>"$LOG" 2>&1
fi
echo "holding desktop session" >>"$LOG" 2>&1
while [ -f /tmp/instantwm.pid ]; do
	read -r _p </tmp/instantwm.pid 2>/dev/null || break
	[ -n "$_p" ] || break
	kill -0 "$_p" 2>/dev/null || break
	sleep 5 2>/dev/null || sleep 5
done
cleanup
echo "compositor gone, session over" >>"$LOG" 2>&1
exit 0
EOF
chmod 0755 "$RAMROOT/usr/bin/silen-live-wayland" 2>/dev/null || true
if ! ldconfig -r "$RAMROOT" 2>/dev/null; then
	echo "  ERROR ldconfig failed after live desktop merge"; exit 1
fi
echo "  live desktop: $(du -sh "$RAMROOT/usr/bin/instantwm" 2>/dev/null | cut -f1) instantwm + $(du -sh "$RAMROOT/usr/lib64" 2>/dev/null | cut -f1) libs"


echo "[6/7] Packing initramfs ($COMPRESS)"

AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
if [ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt "$MIN_RAM_MB" ] && [ "$FORCE" != "1" ]; then
	echo "  ERROR only ${AVAIL_MB}MB RAM available need ${MIN_RAM_MB}MB at compression time"
	echo "  Rerun with FORCE=1 to try anyway"
	exit 1
fi

for cmd in cpio tar modinfo ldd depmod ldconfig du strip; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "  ERROR $cmd not found install it e.g. sudo pacman -S $cmd"
		exit 1
	fi
done
if ! command -v "$COMPRESS" >/dev/null 2>&1; then
	echo "  ERROR $COMPRESS not found install it e.g. sudo pacman -S $COMPRESS"
	exit 1
fi

CPIO_FILE="build/initramfs.cpio"

if ! (
	cd "$RAMROOT"
	find . -print0 | cpio --null -o --format=newc --owner=0:0
) > "$CPIO_FILE"; then
	echo "  ERROR cpio failed (need cpio package, disk space)"
	exit 1
fi
[ -s "$CPIO_FILE" ] || { echo "  ERROR cpio produced empty archive"; exit 1; }

if [ "$COMPRESS" = "zstd" ]; then
	zstd -19 -q -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR zstd compression failed (need RAM/disk, try FORCE=1)"; exit 1; }
elif [ "$COMPRESS" = "gzip" ]; then
	gzip -9 -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR gzip compression failed"; exit 1; }
else
	xz -9 -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR xz compression failed"; exit 1; }
fi

rm -f "$CPIO_FILE"

echo "  initramfs: $(du -h "build/$INITRAMFS" | cut -f1)"


echo "[7/7] Assembling ISO"

mkdir -p "$ISO_DIR/boot/grub"

if modules_ok "$MODULES_SOURCE"; then
	echo "  packing kernel + module tree for the installed system"
	if ! command -v zstd >/dev/null 2>&1; then
		echo "  ERROR zstd not found (needed for kernel/network bundles) install it e.g. sudo pacman -S zstd"
		exit 1
	fi
	KROOT="build/kernel-root"
	rm -rf "$KROOT"
	mkdir -p "$KROOT/boot" "$KROOT/lib/modules"
	cp "$KERNEL_SOURCE" "$KROOT/boot/vmlinuz" || { echo "  ERROR cannot copy kernel image"; exit 1; }
	cp -a "$MODULES_SOURCE" "$KROOT/lib/modules/$KERNEL_VERSION" || { echo "  ERROR cannot copy module tree"; exit 1; }
	rm -rf "$KROOT/lib/modules/$KERNEL_VERSION/vmlinuz"
	find "$KROOT/lib/modules" -name '*.ko' -exec strip --strip-debug {} + 2>/dev/null || true
	KERNEL_TAR="$ISO_DIR/kernel-$KERNEL_VERSION.tar.zst"
	tar -C "$KROOT" --exclude='./lib/modules/*/vmlinuz' -I 'zstd -19' -cf "$KERNEL_TAR" . || { echo "  ERROR kernel tarball creation failed (disk full?)"; exit 1; }
	echo "  kernel bundle: $(du -h "$KERNEL_TAR" | cut -f1)"
else
	echo "  no module tree found to add to ISO installed system gets the initramfs set"
fi

_HEADERS_TAR=""
for _h in headers-*.tar.zst headers-*.tar.gz headers-*.tar.xz; do
	[ -f "$_h" ] || continue
	_HEADERS_TAR="$_h"
	break
done
if [ -n "$_HEADERS_TAR" ]; then
	echo "  adding kernel headers to ISO ($_HEADERS_TAR)"
	cp "$_HEADERS_TAR" "$ISO_DIR/" || { echo "  ERROR cannot copy headers bundle"; exit 1; }
else
	echo "  ! no headers-*.tar.zst found - run scripts/make-headers-bundle.sh or nvidia module builds will fail"
fi

if [ "$NVIDIA" = "1" ]; then
	echo "  nvidia variant: staging driver payload"
	[ -n "$_HEADERS_TAR" ] || { echo "  ERROR nvidia variant needs headers-*.tar.zst (run KERNEL_SRC=... scripts/make-headers-bundle.sh first)"; exit 1; }
	_NVIDIA_RUN=""
	for _r in nvidia-*.run; do
		[ -f "$_r" ] || continue
		_NVIDIA_RUN="$_r"
		break
	done
	if [ -z "$_NVIDIA_RUN" ] && ls build/nvidia-dl/nvidia-*.run >/dev/null 2>&1; then
		_NVIDIA_RUN="$(ls build/nvidia-dl/nvidia-*.run 2>/dev/null | head -n1)"
	fi
	if [ -z "$_NVIDIA_RUN" ]; then
		_SPK_BASE="${SPK_BASE_URL:-https://huggingface.co/datasets/vgzz/spk-pkgs/resolve/main/packages}"
		_NVIDIA_MANIFEST="$(curl -sSL --max-time 60 "$_SPK_BASE/nvidia-drivers/package.json" 2>/dev/null)" || _NVIDIA_MANIFEST=""
		_NVIDIA_PARTS="$(printf '%s' "$_NVIDIA_MANIFEST" | sed -n 's/.*"parts"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
		_NVIDIA_SHA="$(printf '%s' "$_NVIDIA_MANIFEST" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p')"
		[ -n "$_NVIDIA_PARTS" ] || { echo "  ERROR cannot fetch nvidia-drivers manifest (network down?) - drop nvidia-*.run in the repo root instead"; exit 1; }
		mkdir -p build/nvidia-dl || { echo "  ERROR cannot create build/nvidia-dl"; exit 1; }
		_i=0
		while [ "$_i" -lt "$_NVIDIA_PARTS" ]; do
			_part="$(printf '%s.%03d' "nvidia-drivers.spk" "$_i")"
			curl -sSL --max-time 600 -o "build/nvidia-dl/$_part" "$_SPK_BASE/nvidia-drivers/$_part" || { echo "  ERROR download failed: $_part"; exit 1; }
			_i=$((_i + 1))
		done
		cat build/nvidia-dl/nvidia-drivers.spk.* > build/nvidia-dl/nvidia-drivers.spk || { echo "  ERROR cannot join parts"; exit 1; }
		if [ -n "$_NVIDIA_SHA" ]; then
			_got="$(sha256sum build/nvidia-dl/nvidia-drivers.spk 2>/dev/null | awk '{print $1}')"
			[ "$_got" = "$_NVIDIA_SHA" ] || { echo "  ERROR sha256 mismatch on nvidia-drivers.spk"; exit 1; }
		fi
		_NVIDIA_TMP="$(mktemp -d /tmp/silen-nvidia.XXXXXX 2>/dev/null || echo /tmp/silen-nvidia.$$)"
		tar -xzf build/nvidia-dl/nvidia-drivers.spk -C "$_NVIDIA_TMP" || { echo "  ERROR cannot unpack spk"; exit 1; }
		_NVIDIA_RUN_FILE="$(find "$_NVIDIA_TMP" -name 'nvidia-*.run' | head -n1)"
		[ -n "$_NVIDIA_RUN_FILE" ] || { echo "  ERROR no .run inside spk"; exit 1; }
		cp "$_NVIDIA_RUN_FILE" build/nvidia-dl/ || { echo "  ERROR cannot stage .run"; exit 1; }
		rm -rf "$_NVIDIA_TMP" build/nvidia-dl/nvidia-drivers.spk* 2>/dev/null || true
		_NVIDIA_RUN="$(ls build/nvidia-dl/nvidia-*.run 2>/dev/null | head -n1)"
		[ -n "$_NVIDIA_RUN" ] || { echo "  ERROR nvidia .run staging failed"; exit 1; }
	fi
	cp "$_NVIDIA_RUN" "$ISO_DIR/$(basename "$_NVIDIA_RUN")" || { echo "  ERROR cannot copy nvidia .run to ISO"; exit 1; }
	touch "$ISO_DIR/nvidia-auto" || { echo "  ERROR cannot write nvidia-auto flag"; exit 1; }
	if bash scripts/build-nvidia-kmods.sh "$KERNEL_VERSION" "$_HEADERS_TAR" "$_NVIDIA_RUN" "$ISO_DIR/nvidia-kmods-$KERNEL_VERSION.tar.zst"; then
		echo "  nvidia prebuilt kmods ready"
	else
		echo "  ! nvidia kmods prebuild failed - installer will compile on target"
		echo "  ! see build/nvidia-kmods-build.log:"
		tail -n 15 build/nvidia-kmods-build.log 2>/dev/null | sed 's/^/    /' || true
		rm -f "$ISO_DIR/nvidia-kmods-$KERNEL_VERSION.tar.zst" 2>/dev/null || true
	fi
	echo "  nvidia payload: $(du -h "$ISO_DIR/$(basename "$_NVIDIA_RUN")" | cut -f1)"
fi

if [ -d "$FIRMWARE_SOURCE" ]; then
	echo "  adding firmware to ISO at firmware"
	mkdir -p "$ISO_DIR/firmware" || { echo "  ERROR cannot create ISO firmware dir"; exit 1; }
	cp -a "$FIRMWARE_SOURCE"/. "$ISO_DIR/firmware"/ || { echo "  ERROR cannot copy firmware to ISO"; exit 1; }
	# same gpu firmware as the initramfs or installed systems go black
	for _gpu_fw in amdgpu amd-ucode intel-ucode i915 xe nouveau radeon; do
		for _fwsrc in "$FIRMWARE_SOURCE" "$HOST_FIRMWARE"; do
			[ -n "$_fwsrc" ] && [ -d "$_fwsrc/$_gpu_fw" ] || continue
			mkdir -p "$ISO_DIR/firmware/$_gpu_fw" || { echo "  ERROR cannot create ISO firmware dir $_gpu_fw"; exit 1; }
			cp -an "$_fwsrc/$_gpu_fw"/. "$ISO_DIR/firmware/$_gpu_fw"/ 2>/dev/null || \
			cp -a "$_fwsrc/$_gpu_fw"/. "$ISO_DIR/firmware/$_gpu_fw"/ || { echo "  ERROR cannot copy GPU firmware $_gpu_fw to ISO"; exit 1; }
		done
	done
fi

STAGE3_TARBALL=""
for _st in stage3-*.tar.* tarball-*.xz tarball-*.tar.*; do
	[ -f "$_st" ] || continue
	STAGE3_TARBALL="$_st"
	break
done
if [ -n "$STAGE3_TARBALL" ]; then
	echo "  copying stage3 tarball onto the ISO $STAGE3_TARBALL"
	cp "$STAGE3_TARBALL" "$ISO_DIR/" || { echo "  ERROR cannot copy $STAGE3_TARBALL to ISO (disk full?)"; exit 1; }
else
	echo
	echo "  !! WARNING no stage3/tarball found in the repo root"
	echo "  !! The ISO will boot but the installer will refuse to install"
	echo "  !! no Silen tarball found Put tarball-silen.xz or a"
	echo "  !! stage3-*.tar.*) next to this repo before building"
	echo
fi

if command -v cargo >/dev/null 2>&1; then
	echo "  building spk spk/src/get.rs"
	CARGO_ENV=()
	CARGO_AS_USER=""
	if [ -n "${SUDO_USER:-}" ]; then
		_SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
		if [ -n "$_SUDO_HOME" ]; then
			CARGO_ENV+=(RUSTUP_HOME="$_SUDO_HOME/.rustup" CARGO_HOME="$_SUDO_HOME/.cargo")
			if [ "$(id -u)" = "0" ] && command -v sudo >/dev/null 2>&1; then
				CARGO_AS_USER="$SUDO_USER"
			fi
		fi
	fi
	_CARGO_OK=0
	if [ -n "$CARGO_AS_USER" ]; then
		if sudo -u "$CARGO_AS_USER" env "${CARGO_ENV[@]}" cargo build --release --manifest-path spk/Cargo.toml; then
			_CARGO_OK=1
		fi
	else
		if env "${CARGO_ENV[@]}" cargo build --release --manifest-path spk/Cargo.toml; then
			_CARGO_OK=1
		fi
	fi
	if [ "$_CARGO_OK" = "1" ]; then
		echo "  copying spk onto the ISO and into the live initramfs"
		cp spk/target/release/spk "$ISO_DIR/spk" || echo "  ! cannot copy spk to ISO installer will fetch it another way"
		if [ -f spk/target/release/spk ]; then
			mkdir -p "$RAMROOT/usr/bin" || { echo "  ERROR cannot create usr/bin"; exit 1; }
			cp spk/target/release/spk "$RAMROOT/usr/bin/spk" || echo "  ! cannot copy spk to initramfs (live spk will rely on /mnt/spk)"
			chmod 0755 "$RAMROOT/usr/bin/spk" 2>/dev/null || true
		fi
		# spk gets built late so pack the image again with it inside
		if [ -f "$RAMROOT/usr/bin/spk" ] && [ -f "build/$INITRAMFS" ]; then
			echo "  re-packing initramfs to include spk"
			copy_libs "$RAMROOT/usr/bin/spk"
			ldconfig -r "$RAMROOT" 2>/dev/null || { echo "  ERROR ldconfig failed after spk merge"; exit 1; }
			if ! (
				cd "$RAMROOT"
				find . -print0 | cpio --null -o --format=newc --owner=0:0
			) > "$CPIO_FILE"; then
				echo "  ERROR cpio re-pack failed"
				exit 1
			fi
			if [ "$COMPRESS" = "zstd" ]; then
				zstd -19 -q -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR zstd re-pack failed"; exit 1; }
			elif [ "$COMPRESS" = "gzip" ]; then
				gzip -9 -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR gzip re-pack failed"; exit 1; }
			else
				xz -9 -c "$CPIO_FILE" > "build/$INITRAMFS" || { echo "  ERROR xz re-pack failed"; exit 1; }
			fi
			rm -f "$CPIO_FILE"
			echo "  initramfs: $(du -h "build/$INITRAMFS" | cut -f1)"
		fi
	else
		echo "  ! spk build failed installer will try to fetch it another way"
	fi
else
	echo "  ! cargo not found skipping spk build installer will try to fetch it"
fi

echo "  packing network bundle iwd/iwctl + deps for the installed system"
NETROOT="build/network-root"
rm -rf "$NETROOT"
mkdir -p "$NETROOT"
for _np in \
	usr/libexec/iwd \
	usr/bin/iwd \
	usr/bin/iwctl usr/bin/iwmon \
	usr/bin/dbus-daemon usr/bin/dbus-uuidgen \
	usr/bin/rfkill usr/bin/iw \
	usr/lib/dbus-daemon-launch-helper usr/libexec/dbus-daemon-launch-helper \
	usr/lib64 \
	etc/iwd \
	usr/share/dbus-1 \
	usr/share/terminfo \
	etc/machine-id \
; do
	[ -e "$RAMROOT/$_np" ] || [ -L "$RAMROOT/$_np" ] || continue
	mkdir -p "$NETROOT/$(dirname "$_np")" || { echo "  ERROR cannot create $NETROOT/$(dirname "$_np")"; exit 1; }
	cp -a "$RAMROOT/$_np" "$NETROOT/$_np" || { echo "  ERROR cannot copy $_np to network bundle"; exit 1; }
done
if [ -x "$NETROOT/usr/libexec/iwd" ]; then
	NETWORK_TAR="$ISO_DIR/network.tar.zst"
	tar -C "$NETROOT" -I 'zstd -19' -cf "$NETWORK_TAR" . || { echo "  ERROR network bundle creation failed"; exit 1; }
	echo "  network bundle $(du -h "$NETWORK_TAR" | cut -f1)"
else
	echo "  ! iwd missing from ramroot installed system gets no wifi stack"
fi

echo "  packing desktop bundle (instantwm Wayland stack for the installed system)"
DESKROOT="build/desktop-root"
rm -rf "$DESKROOT"
mkdir -p "$DESKROOT"
for _dp in \
	usr/bin/instantwm usr/bin/instantwmctl \
	usr/bin/instantmenu usr/bin/instantmenu_run usr/bin/instantmenu_path usr/bin/instantmenu_smartrun \
	usr/bin/seatd usr/bin/seatd-launch etc/init.d/seatd \
	usr/bin/silen-installer usr/bin/silen-live-wayland \
	usr/bin/kitty usr/bin/wofi usr/bin/waybar \
	usr/share/wayland-sessions usr/share/applications \
	usr/share/doc/instantwm \
	etc/skel \
; do
	[ -e "$RAMROOT/$_dp" ] || [ -L "$RAMROOT/$_dp" ] || continue
	mkdir -p "$DESKROOT/$(dirname "$_dp")" || { echo "  ERROR cannot create $DESKROOT/$(dirname "$_dp")"; exit 1; }
	cp -a "$RAMROOT/$_dp" "$DESKROOT/$_dp" || { echo "  ERROR cannot copy $_dp to desktop bundle"; exit 1; }
done
if [ -x "$DESKROOT/usr/bin/instantwm" ]; then
	DESKTOP_TAR="$ISO_DIR/desktop.tar.zst"
	tar -C "$DESKROOT" -I 'zstd -19' -cf "$DESKTOP_TAR" . || { echo "  ERROR desktop bundle creation failed"; exit 1; }
	echo "  desktop bundle $(du -h "$DESKTOP_TAR" | cut -f1)"
else
	echo "  ! instantwm missing from ramroot installed system gets no desktop bundle"
fi
if [ -f build/silen-installer ]; then
	cp build/silen-installer "$ISO_DIR/silen-installer" 2>/dev/null || true
fi

if [ -d grub-bundle/usr/local ]; then
	echo "  adding bundled grub EFI to ISO at grub"
	mkdir -p "$ISO_DIR/grub"
	cp -a grub-bundle/usr "$ISO_DIR/grub/" || { echo "  ERROR cannot copy grub-bundle"; exit 1; }
else
	echo "  ! no grub-bundle/ found - installer won't be able to set up GRUB"
	echo "    build it once with scripts/make-grub-bundle.sh"
fi

if [ -f branding/fastfetch_logo.txt ]; then
	echo "  adding branding to ISO at branding"
	mkdir -p "$ISO_DIR/branding"
	cp branding/fastfetch_logo.txt "$ISO_DIR/branding/" || { echo "  ERROR cannot copy branding"; exit 1; }
	[ -f branding/info.txt ] && cp branding/info.txt "$ISO_DIR/branding/" || true
fi

cp "$KERNEL_SOURCE" "$ISO_DIR/boot/vmlinuz" || { echo "  ERROR cannot copy kernel to ISO"; exit 1; }
cp "build/$INITRAMFS" "$ISO_DIR/boot/$INITRAMFS" || { echo "  ERROR cannot copy initramfs to ISO"; exit 1; }

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10

insmod part_gpt
insmod part_msdos
insmod fat
insmod ext2
insmod iso9660
insmod all_video
insmod gfxterm
insmod efi_gop
insmod efi_uga
if loadfont \$prefix/fonts/unicode.pf2; then
	set gfxmode=auto
fi
# keep console output on, a black screen here hides real errors
# no gfxpayload line, uefi chokes on it so leave it out
terminal_output gfxterm console

menuentry "Silen Linux" {
	echo "Booting Silen"
	linux /boot/vmlinuz loglevel=4 console=ttyS0 console=tty0
	initrd /boot/$INITRAMFS
}

menuentry "Silen Linux (fallback, nomodeset)" {
	echo "Booting Silen (no KMS)"
	linux /boot/vmlinuz nomodeset loglevel=4 console=ttyS0 console=tty0
	initrd /boot/$INITRAMFS
}

menuentry "Silen Linux (text installer)" {
	echo "Booting Silen (text installer)"
	linux /boot/vmlinuz loglevel=4 console=ttyS0 console=tty0 silen.tui
	initrd /boot/$INITRAMFS
}
EOF

echo "  running grub-mkrescue"
grub-mkrescue -o "$RESULT" "$ISO_DIR" || { echo "  ERROR grub-mkrescue failed (need xorriso mtools dosfstools)"; exit 1; }

echo
echo "Done"
du -sh "$RESULT"
echo
echo "initramfs  $(du -h "build/$INITRAMFS" | cut -f1)"
echo "kernel     $(du -h "$KERNEL_SOURCE" | cut -f1)"
echo "modules    $(du -sh "$MODULES_DIR" | cut -f1)"
echo "firmware   $(du -sh "$RAMROOT/lib/firmware" 2>/dev/null | cut -f1)"

if [ -n "${SUDO_USER:-}" ]; then
	_SUDO_GRP="$(id -gn "$SUDO_USER" 2>/dev/null || true)"
	if [ -n "$_SUDO_GRP" ]; then
		chown -R "$SUDO_USER:$_SUDO_GRP" build 2>/dev/null || chown -R "$SUDO_USER" build 2>/dev/null || true
	else
		chown -R "$SUDO_USER" build 2>/dev/null || true
	fi
fi