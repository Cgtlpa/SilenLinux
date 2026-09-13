# Silen Linux - build tools
#
#   make iso     build the bootable ISO
#   make qemu    boot the ISO in QEMU (UEFI)
#   make clean   remove the build/ folder

iso:
	sudo ./scripts/build.sh

qemu:
	qemu-system-x86_64 -m 2G -cpu max -bios /usr/share/edk2-ovmf/OVMF_CODE.fd -cdrom build/silen-linux.iso -boot d

clean:
	rm -rf build