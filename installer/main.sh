set -e

title="Silen Linux"
ROOT_PATH="/silen"

if [[ ! -d /sys/firmware/efi ]]; then
				printf "Powering off system...\n"
				sleep 0.1

				poweroff -f
fi


partition() {
	umount -R /mnt >/dev/null || true
	read -p "Select disk (e.g. /dev/nvme0n1): " DISK

	umount -R /mnt 2>/dev/null || true

	parted -s "$DISK" mklabel gpt
	parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
	parted -s "$DISK" set 1 esp on
	parted -s "$DISK" mkpart root ext4 513MiB 100%
	udevadm settle

	if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
		BOOT_PART="${DISK}p1"
		ROOT_PART="${DISK}p2"
	else
		BOOT_PART="${DISK}1"
		ROOT_PART="${DISK}2"
	fi

	mkfs.fat -F32 "$BOOT_PART"
	if [[ "$FILESYSTEM" == "BTRFS" ]]; then
		mkfs.btrfs "$ROOT_PART"
	elif [[ "$FILESYSTEM" == "ext4" ]]; then
		mkfs.ext4 "$ROOT_PART"
	elif [[ "$FILESYSTEM" == "FAT32" ]]; then
		mkfs.fat -F32 "$ROOT_PART"
	else
		echo "Wtf is that?"
		exit
	fi
	mount "$ROOT_PART" /$ROOT_PATH
	
	filesystem_create
}

filesystem_create() {
	mv /tarball-silen.xz /$ROOT_PATH
	tar -xpvf /$ROOT_PATH/tarball-silen.xz -C /$ROOT_PATH/ --strip-components=1

	mount $BOOT_PART /$ROOT_path/boot/efi

	arch-chroot /$ROOT_PATH <<EOF

grub-install --target=x86_64 --boot-directory=/boot --efi-directory=/boot/efi --bootloader-id=LINUX
grub-mkconfig -o /boot/grub/grub.cfg

echo "$user_username:$user_password" | chpasswd
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/10-silen
EOF
}

greeting() {
	filesystems=(
		"BTRFS" "The most modern filesystem that includes rollbacks."
		"ext4" "The most stable filesystem. It's just a OG"
		"FAT32" "Idk why u would use this in the modern world."
	)

	whiptail --title "$title" --msgbox "welcome to the Silen Linux installer!" 10 40
	user_username=$(whiptail --title "$title" --inputbox "Enter in the username for the acc: " 10 40)
	user_password=$(whiptail --title "$title" --passwordbox "Enter in the password for the acc: " 10 40)
	FILESYSTEM=$(whiptail --title "$title" --menu "Choose an filesystem: " 10 40 3 "${filesystems[@]}" 3>&1 1>&2 2>&3)

	partition
}

greeting

echo "Installed Silen Linux succesfully!"

cat << 'EOF' | tee /$ROOT_PATH/home/$user_username/.ascii
      
         ⢀⢔⢐⢔⢐⢔⢐⢔⢐⢔⢐⠔⡐⢌⠢⡑⢌
⠀        ⡑⠔⢅⠢⡑⠔⢅⠢⡑⢔⠡⡑⢌⢌⠢⡑⢌
         ⡑⠔⢅⠢⡑⠔⢅⠢⡑⢔⠡⡑⢌⢌⠢⡑⢌
    
   ⢠⢐⢔⢐⢔⢐⢔⢐⢔⢐⢔⠰⡨⢌⠢⡑⢌⠀⠀
   ⢌⠢⡑⠔⢅⠢⡑⠔⢅⠢⡑⢔⢑⢌⠢⡑⢌
   ⢌⠢⡑⠔⢅⠢⡑⠔⢅⠢⡑⢔⢑⢌⠢⡑⢌

         ⢪⢘⢌⡠⡑⠔⢅⠢⡑⠔⢅⠢⡑⢌⠢⡑⢌
      ⠀  ⢅⠣⢢⢑⠔⢅⢕⢐⠕⢌⠢⡑⢌⢌⠢⡑⢌
     ⠀   ⢅⠣⢢⢑⠔⢅⢕⢐⠕⢌⠢⡑⢌⢌⠢⡑⢌
EOF

echo "alias silenfetch='fastfetch -l ~/.ascii'" >> /$ROOT_path/home/$user_username/.bashrc
exit
