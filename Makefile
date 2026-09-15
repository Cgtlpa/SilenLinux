# Silen Linux - build tools
#
#   make iso     build the bootable ISO
#   make qemu    boot the ISO in QEMU (UEFI)
#   make clean   remove the build/ folder

iso:
	sudo nice -n 10 ionice -c 3 ./scripts/build.sh

qemu:
	@firmware=""; code=""; vars=""; \
	for f in /usr/share/edk2/x64/OVMF.4m.fd \
	         /usr/share/edk2-ovmf/OVMF.fd \
	         /usr/share/ovmf/OVMF.fd; do \
		[ -f "$$f" ] && firmware="$$f" && break; \
	done; \
	for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
	         /usr/share/edk2-ovmf/OVMF_CODE.fd \
	         /usr/share/ovmf/OVMF_CODE.fd; do \
		[ -f "$$f" ] && code="$$f" && break; \
	done; \
	for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd \
	         /usr/share/edk2-ovmf/OVMF_VARS.fd \
	         /usr/share/ovmf/OVMF_VARS.fd; do \
		[ -f "$$f" ] && vars="$$f" && break; \
	done; \
	if [ -n "$$firmware" ]; then \
		qemu-system-x86_64 -m 2G -cpu max -bios "$$firmware" -cdrom build/silen-linux.iso -boot d; \
	elif [ -n "$$code" ] && [ -n "$$vars" ]; then \
		cp "$$vars" /tmp/OVMF_VARS.fd && \
		qemu-system-x86_64 -m 2G -cpu max \
			-drive if=pflash,format=raw,readonly=on,file="$$code" \
			-drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
			-cdrom build/silen-linux.iso -boot d; \
	else \
		echo "ERROR: no OVMF firmware found - install the edk2-ovmf package"; exit 1; \
	fi

clean:
	rm -rf build