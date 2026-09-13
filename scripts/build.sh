#!/bin/bash
# this is for building my iso 
# and yes this is written by ai ( some stuff and making it better )

set -e
KERNEL_VERSION="7.2.0-gentoo-gentoo-dist-bin"
KERNEL_SOURCE="boot/vmlinuz"
MODULES_SOURCE="rootfs/lib/modules/$KERNEL_VERSION"
FIRMWARE_SOURCE="/lib/firmware"
BUSYBOX_SOURCE="rootfs/bin/busybox"
INIT_SOURCE="rootfs/init"

RAMROOT="build/initramfs-root"
ISO_DIR="build/iso"
RESULT="build/silen-linux.iso"

COMPRESS="${COMPRESS:-zstd}"   
AUTO_HOST="${AUTO_HOST:-1}"    
FULL="${FULL:-0}"             

ALLOW="
	ahci libahci ata_piix sd_mod sr_mod nvme nvme_core nvme_auth nvme_common
	virtio_blk virtio_scsi virtio_pci virtio_console virtio_input
	xhci-pci ehci-pci ohci-pci uhci-hcd usb-storage uas usbhid hid-generic
	virtio_net e1000 e1000e r8169 tg3 igb ixgbe r8152 ax88179_178a
	ext4 jbd2 mbcache crc32c_intel vfat fat fuse squashfs ntfs3 btrfs xfs isofs
	nls_utf8 nls_cp437 nls_iso8859-1 dm_mod md_mod
	i8042 psmouse
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
echo "compression: $COMPRESS   auto-detect host modules: $AUTO_HOST   full module tree: $FULL"
echo


# ----------------------------------------------------------------------
# Step 1: clean old build (remove the whole build/ folder)
# ----------------------------------------------------------------------

echo "[1/7] Cleaning old build (removing build/)..."

rm -rf build 2>/dev/null || true

if [ -d build ]; then
	echo "  old build files are root-owned, cleaning with sudo..."
	sudo rm -rf build
fi

echo "[2/7] Building module list..."

declare -A module_file_by_name
while IFS= read -r path; do
	name="${path##*/}"
	name="${name%.ko}"
	if [ -z "${module_file_by_name[$name]:-}" ]; then
		module_file_by_name[$name]="$path"
	fi
done < <(find "$MODULES_SOURCE" -name '*.ko')


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
		name="${path##*/}"
		name="${name%.ko}"
		queue+=("$name")
	done < <(find "$MODULES_SOURCE" -name '*.ko')
else
	queue=($ALLOW)
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


echo "[3/7] Setting up ramdisk root..."

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

for applet in $(busybox --list); do
	ln -sf busybox "$RAMROOT/bin/$applet"
done

# whiptail + its runtime libraries (needed by the installer menus)
mkdir -p "$RAMROOT/usr/bin"
cp /usr/bin/whiptail "$RAMROOT/usr/bin/whiptail"
cp --dereference /usr/lib64/libnewt.so.0.52 "$RAMROOT/usr/lib64/libnewt.so.0.52"
cp --dereference /usr/lib64/libslang.so.2  "$RAMROOT/usr/lib64/libslang.so.2"
cp --dereference /usr/lib64/libpopt.so.0   "$RAMROOT/usr/lib64/libpopt.so.0"

# terminfo entries whiptail/newt need to draw its menus
mkdir -p "$RAMROOT/usr/share/terminfo/l"
mkdir -p "$RAMROOT/usr/share/terminfo/x"
mkdir -p "$RAMROOT/usr/share/terminfo/v"
mkdir -p "$RAMROOT/usr/share/terminfo/s"
cp /usr/share/terminfo/l/linux      "$RAMROOT/usr/share/terminfo/l/linux"
cp /usr/share/terminfo/x/xterm      "$RAMROOT/usr/share/terminfo/x/xterm"
cp /usr/share/terminfo/x/xterm-256color "$RAMROOT/usr/share/terminfo/x/xterm-256color"
cp /usr/share/terminfo/v/vt100      "$RAMROOT/usr/share/terminfo/v/vt100"
cp /usr/share/terminfo/s/screen     "$RAMROOT/usr/share/terminfo/s/screen"

# the Silen installer, available at /installer/main.sh in the live environment
mkdir -p "$RAMROOT/installer"
cp installer/main.sh "$RAMROOT/installer/main.sh"
chmod 0755 "$RAMROOT/installer/main.sh"

# the kernel entry point
cp "$INIT_SOURCE" "$RAMROOT/init"
chmod 0755 "$RAMROOT/init"

echo "  $(du -sh "$RAMROOT/bin" | cut -f1) busybox + applets"



echo "[4/7] Copying modules and firmware..."

MODULES_DIR="$RAMROOT/lib/modules/$KERNEL_VERSION"
mkdir -p "$MODULES_DIR"

for name in "${chosen[@]}"; do
	path="$(module_file "$name")"
	[ -z "$path" ] && continue

	relative="${path#$MODULES_SOURCE/}"
	mkdir -p "$MODULES_DIR/$(dirname "$relative")"
	cp "$path" "$MODULES_DIR/$relative"

	for firmware in $(modinfo -F firmware "$path" 2>/dev/null); do
		if [ -f "$FIRMWARE_SOURCE/$firmware" ]; then
			mkdir -p "$RAMROOT/lib/firmware/$(dirname "$firmware")"
			cp "$FIRMWARE_SOURCE/$firmware" "$RAMROOT/lib/firmware/$firmware"
		fi
	done
done

cp "$MODULES_SOURCE/modules.builtin" "$MODULES_DIR/modules.builtin" 2>/dev/null || true
cp "$MODULES_SOURCE/modules.builtin.modinfo" "$MODULES_DIR/modules.builtin.modinfo" 2>/dev/null || true

echo "  modules:   $(du -sh "$MODULES_DIR" | cut -f1)"
echo "  firmware:  $(du -sh "$RAMROOT/lib/firmware" 2>/dev/null | cut -f1)"


echo "[5/7] Stripping debug info..."

find "$MODULES_DIR" -name '*.ko' -exec strip --strip-debug {} +

echo "  modules after strip: $(du -sh "$MODULES_DIR" | cut -f1)"

echo "  writing /etc/modules..."
printf '%s\n' "${chosen[@]}" | sort > "$RAMROOT/etc/modules"

echo "  generating modules.dep..."

if [ -x /usr/bin/depmod ]; then
	DEPMOD=/usr/bin/depmod
elif [ -x /sbin/depmod ]; then
	DEPMOD=/sbin/depmod
else
	DEPMOD=depmod
fi
$DEPMOD -b "$RAMROOT" "$KERNEL_VERSION" || echo "  ! depmod failed (modules.dep may be missing)"


echo "[6/7] Packing initramfs ($COMPRESS)..."

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


echo "[7/7] Assembling ISO..."

mkdir -p "$ISO_DIR/boot/grub"

cp "$KERNEL_SOURCE" "$ISO_DIR/boot/vmlinuz"
cp "build/$INITRAMFS" "$ISO_DIR/boot/$INITRAMFS"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

menuentry "Silen Linux" {
	echo "Booting Silen"
	linux /boot/vmlinuz
	initrd /boot/$INITRAMFS
}
EOF

echo "  running grub-mkrescue..."
grub-mkrescue -o "$RESULT" "$ISO_DIR"

echo
echo "Done!"
du -sh "$RESULT"
echo
echo "initramfs:  $(du -h "build/$INITRAMFS" | cut -f1)"
echo "kernel:     $(du -h "$KERNEL_SOURCE" | cut -f1)"
echo "modules:    $(du -sh "$MODULES_DIR" | cut -f1)"
echo "firmware:   $(du -sh "$RAMROOT/lib/firmware" | cut -f1)"