#!/bin/bash
set -e

trap 'echo; echo "!! Build stopped with an error See the message above"; echo "   Remove build/ if needed rm -rf build" >&2' ERR
DEFAULT_KVER="$(ls rootfs/lib/modules 2>/dev/null | grep '^[0-9]' | head -n1)"
KERNEL_VERSION="${KERNEL_VERSION:-${DEFAULT_KVER:-7.2.4-zen2-1-zen}}"
KERNEL_SOURCE="${KERNEL_SOURCE:-boot/vmlinuz}"
MODULES_SOURCE="${MODULES_SOURCE:-rootfs/lib/modules/$KERNEL_VERSION}"
FIRMWARE_SOURCE="${FIRMWARE_SOURCE:-rootfs/lib/firmware}"
HOST_FIRMWARE="${HOST_FIRMWARE:-/lib/firmware}"
BUSYBOX_SOURCE="${BUSYBOX_SOURCE:-rootfs/bin/busybox}"
INIT_SOURCE="${INIT_SOURCE:-rootfs/init}"

RAMROOT="build/initramfs-root"
ISO_DIR="build/iso"
RESULT="build/silen-linux.iso"

COMPRESS="${COMPRESS:-zstd}"   
AUTO_HOST="${AUTO_HOST:-0}"    
FULL="${FULL:-0}"             
FORCE="${FORCE:-0}"            
MIN_RAM_MB="${MIN_RAM_MB:-2048}"
MIN_DISK_MB="${MIN_DISK_MB:-500}"             

ALLOW="
	ahci libahci ata_piix sd_mod sr_mod cdrom nvme nvme_core nvme_auth nvme_common vmd
	mmc_block sdhci sdhci-pci sdhci-acpi
	virtio_blk virtio_scsi virtio_pci virtio_console virtio_input
	xhci-pci ehci-pci ohci-pci uhci-hcd usb-storage uas usbhid hid-generic
	virtio_net e1000 e1000e r8169 tg3 igb ixgbe r8152 ax88179_178a
	ext4 jbd2 mbcache crc32c_intel vfat fat fuse squashfs ntfs3 btrfs xfs isofs
	nls_utf8 nls_cp437 nls_iso8859-1 dm_mod md_mod loop
	i8042 psmouse
	exfat cdc_ether rndis_host rndis_wlan alx 8139too via-rhine
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
	[ -d "$1" ] && find "$1" \( -name '*.ko' -o -name '*.ko.zst' \) 2>/dev/null | grep -q .
}

if ! modules_ok "$MODULES_SOURCE"; then
	echo "  kernel module tree not found $MODULES_SOURCE"
	echo "  auto-detecting host kernel instead"
	HOST_VER="$(uname -r 2>/dev/null)"
	HOST_MODS="/usr/lib/modules/$HOST_VER"
	if [ -n "$HOST_VER" ] && modules_ok "$HOST_MODS"; then
		echo "  using host kernel $HOST_VER"
		echo "     modules from $HOST_MODS"
		KERNEL_VERSION="$HOST_VER"
		MODULES_SOURCE="$HOST_MODS"
		[ -f "$HOST_MODS/vmlinuz" ] && KERNEL_SOURCE="$HOST_MODS/vmlinuz"
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

AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
if [ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt "$MIN_RAM_MB" ] && [ "$FORCE" != "1" ]; then
	echo "  ERROR only ${AVAIL_MB}MB RAM available need ${MIN_RAM_MB}MB"
	echo "  Close heavy apps first or rerun with FORCE=1 to try anyway"
	exit 1
fi


echo "[1/7] Cleaning old build"

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

FREE_KB=$(df -Pk . | awk 'NR==2 {print $4}')
if [ "$FREE_KB" -lt $((MIN_DISK_MB * 1024)) ]; then
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
	local name="$1"
	if [ -n "${module_file_by_name[$name]:-}" ]; then
		printf '%s\n' "${module_file_by_name[$name]}"
	else
		printf '%s\n' "${module_file_by_name[${name//_/-}]:-}"
	fi
}

is_blacklisted() {
	local name="$1"
	for bad in $BLACKLIST; do
		if [ "$name" = "$bad" ]; then
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
		for name in $(ls /sys/module); do
			queue+=("$name")
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

	path="$(module_file "$name")"
	[ -z "$path" ] && continue

	chosen+=("$name")

	deps="$(modinfo -F depends "$path" 2>/dev/null)"
	for dep in ${deps//,/ }; do
		[ -n "$dep" ] && queue+=("$dep")
	done
done

echo "  $(printf '%s\n' "${chosen[@]}" | wc -l) modules selected"


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

cp --dereference /lib64/ld-linux-x86-64.so.2 "$RAMROOT/lib64/ld-linux-x86-64.so.2"
cp --dereference /usr/lib64/libc.so.6        "$RAMROOT/usr/lib64/libc.so.6"
cp --dereference /usr/lib64/libm.so.6        "$RAMROOT/usr/lib64/libm.so.6"
cp --dereference /usr/lib64/libresolv.so.2   "$RAMROOT/usr/lib64/libresolv.so.2"

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

for applet in $("$BUSYBOX_SOURCE" --list); do
	ln -sf busybox "$RAMROOT/bin/$applet"
done

libs_seen=" "
copy_libs() {
	local bin="$1" lib
	[ -f "$bin" ] || return 0
	mkdir -p "$RAMROOT/usr/lib64"
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		case " $libs_seen " in
			*" $lib "*) continue ;;
		esac
		libs_seen="$libs_seen $lib "
		cp --dereference "$lib" "$RAMROOT/usr/lib64/" 2>/dev/null
		copy_libs "$lib"
	done < <(ldd "$bin" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p')
}

copy_app() {
	local dest="$1"
	local src="$2"
	mkdir -p "$RAMROOT/usr/bin"
	cp --dereference "$src" "$RAMROOT/usr/bin/$dest"
	copy_libs "$src"
}

copy_app whiptail /usr/bin/whiptail
copy_app nmtui /usr/bin/nmtui
for _nmtui_link in nmtui-connect nmtui-edit nmtui-hostname; do
	ln -sf nmtui "$RAMROOT/usr/bin/$_nmtui_link"
done
copy_app nmcli /usr/bin/nmcli
copy_app nm-online /usr/bin/nm-online
copy_app dbus-uuidgen /usr/bin/dbus-uuidgen

copy_app mkfs.ext4 /usr/sbin/mkfs.ext4
copy_app mkfs.vfat /usr/sbin/mkfs.vfat
copy_app blkid   /usr/sbin/blkid
copy_app sfdisk  /usr/bin/sfdisk
copy_app tar     /usr/bin/tar
ln -sf /usr/bin/tar "$RAMROOT/bin/tar"
ln -sf /usr/bin/blkid    "$RAMROOT/bin/blkid"
ln -sf /usr/bin/mkfs.vfat "$RAMROOT/bin/mkfs.vfat"
ln -sf /usr/bin/mkfs.ext4 "$RAMROOT/bin/mkfs.ext4"
copy_app zstd    /usr/bin/zstd
ln -sf /usr/bin/zstd "$RAMROOT/bin/zstd"

copy_app git  /usr/bin/git
copy_app curl /usr/bin/curl

mkdir -p "$RAMROOT/usr/lib/git-core"
cp -a /usr/lib/git-core/. "$RAMROOT/usr/lib/git-core/"
for helper in git-remote-http git-http-fetch git-http-push git-http-backend git-imap-send git-daemon; do
	copy_libs "/usr/lib/git-core/$helper"
done

mkdir -p "$RAMROOT/usr/share/git-core"
cp -a /usr/share/git-core/templates "$RAMROOT/usr/share/git-core/"

mkdir -p "$RAMROOT/etc/ssl/certs"
cp /etc/ca-certificates/extracted/tls-ca-bundle.pem "$RAMROOT/etc/ssl/certs/ca-certificates.crt"
cp /etc/ssl/openssl.cnf "$RAMROOT/etc/ssl/openssl.cnf"

copy_app NetworkManager /usr/sbin/NetworkManager
copy_app dbus-daemon  /usr/bin/dbus-daemon
copy_app wpa_supplicant /usr/sbin/wpa_supplicant
mkdir -p "$RAMROOT/usr/sbin"
ln -sf /usr/bin/wpa_supplicant "$RAMROOT/usr/sbin/wpa_supplicant"
[ -f /usr/bin/wpa_cli ] && copy_app wpa_cli /usr/bin/wpa_cli
[ -f /usr/bin/rfkill ] && copy_app rfkill /usr/bin/rfkill
[ -f /usr/bin/iw ] && copy_app iw /usr/bin/iw
[ -f /usr/sbin/rfkill ] && { copy_app rfkill /usr/sbin/rfkill; ln -sf /usr/bin/rfkill "$RAMROOT/usr/sbin/rfkill" 2>/dev/null || true; }
[ -f /usr/sbin/iw ] && { copy_app iw /usr/sbin/iw; ln -sf /usr/bin/iw "$RAMROOT/usr/sbin/iw" 2>/dev/null || true; }
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

if [ -d /usr/lib/NetworkManager ]; then
	mkdir -p "$RAMROOT/usr/lib/NetworkManager"
	cp -a /usr/lib/NetworkManager/. "$RAMROOT/usr/lib/NetworkManager/"
fi
mkdir -p "$RAMROOT/usr/lib"
for _nm_helper in /usr/lib/nm-dispatcher /usr/lib/nm-priv-helper \
		/usr/lib/nm-daemon-helper /usr/lib/nm-dhcp-helper \
		/usr/lib/nm-libnm-helper; do
	[ -f "$_nm_helper" ] || continue
	cp --dereference "$_nm_helper" "$RAMROOT/usr/lib/"
	copy_libs "$_nm_helper"
done
while IFS= read -r _nm_plugin; do
	copy_libs "$_nm_plugin"
done < <(find "$RAMROOT/usr/lib/NetworkManager" -name '*.so' 2>/dev/null)

mkdir -p "$RAMROOT/var/lib/dbus"
printf 'deadbeef000000000000000000000001\n' > "$RAMROOT/etc/machine-id"
cp "$RAMROOT/etc/machine-id" "$RAMROOT/var/lib/dbus/machine-id"

mkdir -p "$RAMROOT/usr/share/dbus-1/system.d"
cp /usr/share/dbus-1/system.d/org.freedesktop.NetworkManager.conf "$RAMROOT/usr/share/dbus-1/system.d/"
for _wpa_conf in /usr/share/dbus-1/system.d/wpa_supplicant.conf \
		/etc/dbus-1/system.d/wpa_supplicant.conf; do
	if [ -f "$_wpa_conf" ]; then
		cp "$_wpa_conf" "$RAMROOT/usr/share/dbus-1/system.d/"
		break
	fi
done
[ -f /usr/share/dbus-1/system.d/nm-dispatcher.conf ] && \
	cp /usr/share/dbus-1/system.d/nm-dispatcher.conf "$RAMROOT/usr/share/dbus-1/system.d/"
if [ -f /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service ]; then
	mkdir -p "$RAMROOT/usr/share/dbus-1/system-services"
	cp /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service \
		"$RAMROOT/usr/share/dbus-1/system-services/"
fi
sed -e '/<user>.*<\/user>/d' -e '/<fork\/>/d' /usr/share/dbus-1/system.conf > "$RAMROOT/usr/share/dbus-1/system.conf"

mkdir -p "$RAMROOT/etc/NetworkManager"
cat > "$RAMROOT/etc/NetworkManager/NetworkManager.conf" <<'EOF'
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
cp /usr/share/terminfo/l/linux      "$RAMROOT/usr/share/terminfo/l/linux"
cp /usr/share/terminfo/x/xterm      "$RAMROOT/usr/share/terminfo/x/xterm"
cp /usr/share/terminfo/x/xterm-256color "$RAMROOT/usr/share/terminfo/x/xterm-256color"
cp /usr/share/terminfo/v/vt100      "$RAMROOT/usr/share/terminfo/v/vt100"
cp /usr/share/terminfo/s/screen     "$RAMROOT/usr/share/terminfo/s/screen"

printf '/lib64\n/usr/lib64\n' > "$RAMROOT/etc/ld.so.conf"
ldconfig -r "$RAMROOT" 2>/dev/null || echo "  ! ldconfig failed (dynamic apps may not load)"

mkdir -p "$RAMROOT/installer"
cp installer/main.sh "$RAMROOT/installer/main.sh"
chmod 0755 "$RAMROOT/installer/main.sh"

if [ -f scripts/wifi-check.sh ]; then
	cp scripts/wifi-check.sh "$RAMROOT/usr/bin/silen-wifi-check"
	chmod 0755 "$RAMROOT/usr/bin/silen-wifi-check"
fi

cp "$INIT_SOURCE" "$RAMROOT/init"
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
				[ -d "$RAMROOT/lib/firmware/$rel" ] || {
					mkdir -p "$RAMROOT/lib/firmware/$(dirname "$rel")"
					cp -a "$f" "$RAMROOT/lib/firmware/$rel"
				}
			else
				local target="$RAMROOT/lib/firmware/$rel"
				mkdir -p "$(dirname "$target")"
				[ -f "$target" ] || cp "$f" "$target"
			fi
		done
		if [ "$found" = 0 ]; then
			set -- "$src/$fw.zst"
			for f in "$@"; do
				[ -e "$f" ] || continue
				found=1
				local rel="${f#$src/}"
				local target="$RAMROOT/lib/firmware/$rel"
				mkdir -p "$(dirname "$target")"
				[ -f "$target" ] || cp "$f" "$target"
			done
		fi
		if [ "$found" = 0 ] && [ -f "$src/$fw.zst" ]; then
			local target="$RAMROOT/lib/firmware/$fw.zst"
			mkdir -p "$(dirname "$target")"
			[ -f "$target" ] || cp "$src/$fw.zst" "$target"
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
	path="$(module_file "$name")"
	[ -z "$path" ] && continue

	relative="${path#$MODULES_SOURCE/}"
	mkdir -p "$MODULES_DIR/$(dirname "$relative")"
	cp "$path" "$MODULES_DIR/$relative"
	if [ "${relative##*.}" = "zst" ]; then
		zstd -d -f -q "$MODULES_DIR/$relative"
		rm "$MODULES_DIR/$relative"
	fi

	for firmware in $(modinfo -F firmware "$path" 2>/dev/null); do
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
	cp -a "$FIRMWARE_SOURCE" "$RAMROOT/lib/firmware" 2>/dev/null || true
fi

cp "$MODULES_SOURCE/modules.builtin" "$MODULES_DIR/modules.builtin" 2>/dev/null || true
cp "$MODULES_SOURCE/modules.builtin.modinfo" "$MODULES_DIR/modules.builtin.modinfo" 2>/dev/null || true
cp "$MODULES_SOURCE/modules.order" "$MODULES_DIR/modules.order" 2>/dev/null || true

echo "  modules   $(du -sh "$MODULES_DIR" | cut -f1)"
echo "  firmware  $(du -sh "$RAMROOT/lib/firmware" 2>/dev/null | cut -f1)"


echo "[5/7] Stripping debug info"

find "$MODULES_DIR" -name '*.ko' -exec strip --strip-debug {} +

echo "  modules after strip $(du -sh "$MODULES_DIR" | cut -f1)"

echo "  writing /etc modules"
printf '%s\n' "${chosen[@]}" | sort > "$RAMROOT/etc/modules"

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
$DEPMOD -b "$RAMROOT" "$KERNEL_VERSION" || echo "  ! depmod failed modules dep may be missing"


echo "[6/7] Packing initramfs ($COMPRESS)"

AVAIL_MB="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
if [ -n "$AVAIL_MB" ] && [ "$AVAIL_MB" -gt 0 ] && [ "$AVAIL_MB" -lt "$MIN_RAM_MB" ] && [ "$FORCE" != "1" ]; then
	echo "  ERROR only ${AVAIL_MB}MB RAM available need ${MIN_RAM_MB}MB at compression time"
	echo "  Rerun with FORCE=1 to try anyway"
	exit 1
fi

for cmd in cpio; do
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

(
	cd "$RAMROOT"
	find . -print0 | cpio --null -o --format=newc 2>/dev/null
) > "$CPIO_FILE"

if [ "$COMPRESS" = "zstd" ]; then
	zstd -19 -q -c "$CPIO_FILE" > "build/$INITRAMFS"
elif [ "$COMPRESS" = "gzip" ]; then
	gzip -9 -c "$CPIO_FILE" > "build/$INITRAMFS"
else
	xz -9 -c "$CPIO_FILE" > "build/$INITRAMFS"
fi

rm -f "$CPIO_FILE"

echo "  initramfs: $(du -h "build/$INITRAMFS" | cut -f1)"


echo "[7/7] Assembling ISO"

mkdir -p "$ISO_DIR/boot/grub"

if modules_ok "$MODULES_SOURCE"; then
	echo "  packing kernel + module tree for the installed system"
	KROOT="build/kernel-root"
	rm -rf "$KROOT"
	mkdir -p "$KROOT/boot" "$KROOT/lib/modules"
	cp "$KERNEL_SOURCE" "$KROOT/boot/vmlinuz"
	cp -a "$MODULES_SOURCE" "$KROOT/lib/modules/$KERNEL_VERSION"
	rm -rf "$KROOT/lib/modules/$KERNEL_VERSION/build" \
	       "$KROOT/lib/modules/$KERNEL_VERSION/source" \
	       "$KROOT/lib/modules/$KERNEL_VERSION/vmlinuz"
	find "$KROOT/lib/modules" -name '*.ko' -exec strip --strip-debug {} +
	KERNEL_TAR="$ISO_DIR/kernel-$KERNEL_VERSION.tar.zst"
	tar -C "$KROOT" --exclude='./lib/modules/*/build' --exclude='./lib/modules/*/source' \
		--exclude='./lib/modules/*/vmlinuz' -I 'zstd -19' -cf "$KERNEL_TAR" .
	echo "  kernel bundle: $(du -h "$KERNEL_TAR" | cut -f1)"
else
	echo "  no module tree found to add to ISO installed system gets the initramfs set"
fi

if [ -d rootfs/lib/firmware ]; then
	echo "  adding firmware to ISO at firmware"
	cp -a rootfs/lib/firmware "$ISO_DIR/firmware"
fi

STAGE3_TARBALL="$(ls stage3-*.tar.* tarball-*.xz tarball-*.tar.* 2>/dev/null | head -n1)"
if [ -n "$STAGE3_TARBALL" ]; then
	echo "  copying stage3 tarball onto the ISO $STAGE3_TARBALL"
	cp "$STAGE3_TARBALL" "$ISO_DIR/"
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
	if [ -n "$SUDO_USER" ]; then
		CARGO_ENV+=(RUSTUP_HOME=/home/$SUDO_USER/.rustup CARGO_HOME=/home/$SUDO_USER/.cargo)
	fi
	if env "${CARGO_ENV[@]}" cargo build --release --manifest-path spk/Cargo.toml; then
		echo "  copying spk onto the ISO"
		cp spk/target/release/spk "$ISO_DIR/spk"
	else
		echo "  ! spk build failed installer will try to fetch it another way"
	fi
else
	echo "  ! cargo not found skipping spk build installer will try to fetch it"
fi

echo "  packing network bundle NetworkManager/nmtui + deps for the installed system"
NETROOT="build/network-root"
rm -rf "$NETROOT"
mkdir -p "$NETROOT"
for _np in \
	usr/bin/NetworkManager \
	usr/bin/nmtui usr/bin/nmtui-connect usr/bin/nmtui-edit usr/bin/nmtui-hostname \
	usr/bin/nmcli usr/bin/nm-online \
	usr/bin/dbus-daemon usr/bin/dbus-uuidgen \
	usr/bin/wpa_supplicant usr/bin/wpa_cli \
	usr/bin/rfkill usr/bin/iw \
	usr/sbin/wpa_supplicant usr/sbin/rfkill usr/sbin/iw \
	usr/lib/NetworkManager \
	usr/lib/nm-dispatcher usr/lib/nm-priv-helper \
	usr/lib/nm-daemon-helper usr/lib/nm-dhcp-helper usr/lib/nm-libnm-helper \
	usr/lib/dbus-daemon-launch-helper usr/libexec/dbus-daemon-launch-helper \
	usr/lib64 \
	etc/NetworkManager \
	usr/share/dbus-1 \
	usr/share/terminfo \
	etc/machine-id \
; do
	[ -e "$RAMROOT/$_np" ] || [ -L "$RAMROOT/$_np" ] || continue
	mkdir -p "$NETROOT/$(dirname "$_np")"
	cp -a "$RAMROOT/$_np" "$NETROOT/$_np"
done
if [ -d "$NETROOT/usr/bin" ]; then
	NETWORK_TAR="$ISO_DIR/network.tar.zst"
	tar -C "$NETROOT" -I 'zstd -19' -cf "$NETWORK_TAR" .
	echo "  network bundle $(du -h "$NETWORK_TAR" | cut -f1)"
else
	echo "  ! network stack missing from ramroot installed system gets no NetworkManager"
fi

if [ -d grub-bundle/usr/local ]; then
	echo "  adding bundled grub EFI to ISO at grub"
	mkdir -p "$ISO_DIR/grub"
	cp -a grub-bundle/usr "$ISO_DIR/grub/"
else
	echo "  ! no grub-bundle/ found - installer won't be able to set up GRUB"
	echo "    build it once with scripts/make-grub-bundle.sh"
fi

if [ -f branding/fastfetch_logo.txt ]; then
	echo "  adding branding to ISO at branding"
	mkdir -p "$ISO_DIR/branding"
	cp branding/fastfetch_logo.txt "$ISO_DIR/branding/"
	[ -f branding/info.txt ] && cp branding/info.txt "$ISO_DIR/branding/"
fi

cp "$KERNEL_SOURCE" "$ISO_DIR/boot/vmlinuz"
cp "build/$INITRAMFS" "$ISO_DIR/boot/$INITRAMFS"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

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
terminal_output gfxterm
set gfxpayload=keep

menuentry "Silen Linux" {
	echo "Booting Silen"
	linux /boot/vmlinuz quiet loglevel=3
	initrd /boot/$INITRAMFS
}
EOF

echo "  running grub-mkrescue"
grub-mkrescue -o "$RESULT" "$ISO_DIR"

echo
echo "Done"
du -sh "$RESULT"
echo
echo "initramfs  $(du -h "build/$INITRAMFS" | cut -f1)"
echo "kernel     $(du -h "$KERNEL_SOURCE" | cut -f1)"
echo "modules    $(du -sh "$MODULES_DIR" | cut -f1)"
echo "firmware   $(du -sh "$RAMROOT/lib/firmware" 2>/dev/null | cut -f1)"

if [ -n "${SUDO_USER:-}" ]; then
	chown -R "$SUDO_USER" build 2>/dev/null || true
fi