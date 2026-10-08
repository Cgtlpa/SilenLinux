.PHONY: iso nvidia-iso qemu clean

# make iso builds it, make qemu boots it
iso:
	sudo nice -n 10 ionice -c 3 ./scripts/build.sh

nvidia-iso:
	sudo NVIDIA=1 nice -n 10 ionice -c 3 ./scripts/build.sh

qemu:
	# hunts down whatever ovmf firmware your distro ships
	@test -f build/silen-linux.iso || { echo "ERROR: build/silen-linux.iso missing run make iso first"; exit 1; }
	@command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "ERROR: qemu-system-x86_64 not found"; exit 1; }
	@if [ ! -f build/disk.img ]; then \
		echo "creating 8G install disk at build/disk.img"; \
		if command -v qemu-img >/dev/null 2>&1; then \
			qemu-img create -f qcow2 build/disk.img 8G; \
		else \
			truncate -s 8G build/disk.img; \
		fi; \
	fi; \
	diskfmt=qcow2; \
	if command -v qemu-img >/dev/null 2>&1; then diskfmt=qcow2; else diskfmt=raw; fi; \
	cpu="qemu64"; [ -e /dev/kvm ] && cpu="host"; \
	kvm=""; [ -e /dev/kvm ] && kvm="-enable-kvm"; \
	firmware=""; code=""; vars=""; \
	for f in /usr/share/edk2/x64/OVMF.4m.fd \
	         /usr/share/edk2-ovmf/OVMF.fd \
	         /usr/share/ovmf/OVMF.fd \
	         /usr/share/OVMF/OVMF.fd \
	         /usr/share/edk2/ovmf/OVMF.fd; do \
		[ -f "$$f" ] && firmware="$$f" && break; \
	done; \
	for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd \
	         /usr/share/edk2-ovmf/OVMF_CODE.fd \
	         /usr/share/ovmf/OVMF_CODE.fd \
	         /usr/share/OVMF/OVMF_CODE.fd \
	         /usr/share/edk2/ovmf/OVMF_CODE.fd; do \
		[ -f "$$f" ] && code="$$f" && break; \
	done; \
	for f in /usr/share/edk2/x64/OVMF_VARS.4m.fd \
	         /usr/share/edk2-ovmf/OVMF_VARS.fd \
	         /usr/share/ovmf/OVMF_VARS.fd \
	         /usr/share/OVMF/OVMF_VARS.fd \
	         /usr/share/edk2/ovmf/OVMF_VARS.fd; do \
		[ -f "$$f" ] && vars="$$f" && break; \
	done; \
	if [ -n "$$firmware" ]; then \
		qemu-system-x86_64 -m 4G -cpu "$$cpu" $$kvm -M q35 -bios "$$firmware" -vga std -serial stdio -cdrom build/silen-linux.iso -drive file=build/disk.img,format=$$diskfmt,if=virtio -boot d; \
	elif [ -n "$$code" ] && [ -n "$$vars" ]; then \
		rm -f /tmp/OVMF_VARS.fd && cp "$$vars" /tmp/OVMF_VARS.fd && \
		qemu-system-x86_64 -m 4G -cpu "$$cpu" $$kvm -M q35 \
			-drive if=pflash,format=raw,readonly=on,file="$$code" \
			-drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
			-vga std -serial stdio -cdrom build/silen-linux.iso -drive file=build/disk.img,format=$$diskfmt,if=virtio -boot d; \
	else \
		echo "ERROR: no OVMF firmware found - install the edk2-ovmf package"; exit 1; \
	fi

clean:
	rm -rf build /tmp/OVMF_VARS.fd