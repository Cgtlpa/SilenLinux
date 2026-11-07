#!/bin/sh
# Silen Linux Hardware Diagnostic Script
# Collects information for troubleshooting Wi-Fi, Rofi, TTY, and NVIDIA issues
# Does NOT collect passwords, personal files, or unrelated system information
#
# Usage: sudo sh silen-hw-diagnostic.sh > silen-hw-diagnostic.txt 2>&1
# Then share the output file with the Silen maintainers.

OUTPUT="${1:-/tmp/silen-hw-diagnostic.txt}"

{
echo "================================================================================"
echo "Silen Linux Hardware Diagnostic Report"
echo "Generated: $(date 2>/dev/null || echo unknown)"
echo "================================================================================"
echo

#-------------------------------------------------------------------------------
# 1. SYSTEM INFORMATION
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "1. SYSTEM INFORMATION"
echo "-------------------------------------------------------------------------------"
echo "Kernel: $(uname -r 2>/dev/null || echo unknown)"
echo "Arch: $(uname -m 2>/dev/null || echo unknown)"
echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
echo "Uptime: $(uptime 2>/dev/null || echo unknown)"
echo

#-------------------------------------------------------------------------------
# 2. WI-FI / NETWORK HARDWARE
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "2. WI-FI / NETWORK HARDWARE"
echo "-------------------------------------------------------------------------------"
echo "--- lspci -nnk (network controllers) ---"
lspci -nnk 2>/dev/null | grep -A3 -i "network\|wireless\|wlan\|wifi\|802.11" || echo "No network controllers found via lspci"
echo
echo "--- lsusb (USB wireless adapters) ---"
lsusb 2>/dev/null | grep -i "wireless\|wlan\|wifi\|802.11\|realtek\|intel\|atheros\|broadcom\|mediatek" || echo "No USB wireless adapters found via lsusb"
echo
echo "--- ip link ---"
ip link 2>/dev/null || echo "ip command not available"
echo
echo "--- iw dev ---"
iw dev 2>/dev/null || echo "iw command not available or no wireless devices"
echo
echo "--- rfkill list ---"
rfkill list 2>/dev/null || echo "rfkill command not available"
echo

#-------------------------------------------------------------------------------
# 3. KERNEL DRIVERS AND FIRMWARE
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "3. KERNEL DRIVERS AND FIRMWARE"
echo "-------------------------------------------------------------------------------"
echo "--- dmesg (firmware/driver errors, last 50 lines) ---"
dmesg 2>/dev/null | grep -i "firmware\|iwlwifi\|ath\|rtl\|brcm\|rtw\|mt76\|iwlwifi\|iwlwifi\|firmware:.*fail\|firmware:.*error\|direct firmware load" | tail -50 || echo "dmesg not available or no relevant messages"
echo
echo "--- Loaded wireless kernel modules ---"
lsmod 2>/dev/null | grep -i "iwl\|ath\|rtl\|brcm\|rtw\|mt76\|mac80211\|cfg80211" || echo "No wireless modules loaded"
echo
echo "--- Firmware directory check ---"
ls /lib/firmware/ 2>/dev/null | head -5 || echo "/lib/firmware not found"
ls /lib/firmware/iwlwifi/ 2>/dev/null | head -5 || echo "No iwlwifi firmware"
ls /lib/firmware/ath10k/ 2>/dev/null | head -5 || echo "No ath10k firmware"
ls /lib/firmware/rtlwifi/ 2>/dev/null | head -5 || echo "No rtlwifi firmware"
ls /lib/firmware/brcm/ 2>/dev/null | head -5 || echo "No brcm firmware"
ls /lib/firmware/mt76/ 2>/dev/null | head -5 || echo "No mt76 firmware"
echo

#-------------------------------------------------------------------------------
# 4. IWD STATUS
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "4. IWD (Wi-Fi Daemon) STATUS"
echo "-------------------------------------------------------------------------------"
echo "--- iwd binary location ---"
command -v iwd 2>/dev/null || echo "iwd binary not found"
command -v iwctl 2>/dev/null || echo "iwctl binary not found"
echo
echo "--- iwd process ---"
ps aux 2>/dev/null | grep -i iwd | grep -v grep || echo "iwd process not running"
echo
echo "--- iwctl device list ---"
iwctl device list 2>/dev/null || echo "iwctl device list failed (iwd may not be running)"
echo
echo "--- iwd D-Bus service ---"
dbus-send --system --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -i iwd || echo "iwd not found on D-Bus (dbus-send not available or iwd not registered)"
echo
echo "--- /etc/iwd/main.conf ---"
cat /etc/iwd/main.conf 2>/dev/null || echo "/etc/iwd/main.conf not found"
echo

#-------------------------------------------------------------------------------
# 5. D-BUS STATUS
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "5. D-BUS STATUS"
echo "-------------------------------------------------------------------------------"
echo "--- dbus-daemon process ---"
ps aux 2>/dev/null | grep -i dbus | grep -v grep || echo "dbus-daemon not running"
echo
echo "--- D-Bus system bus socket ---"
ls -la /run/dbus/system_bus_socket 2>/dev/null || echo "D-Bus system bus socket not found"
echo

#-------------------------------------------------------------------------------
# 6. INSTANTWM / ROFI / KEYBOARD
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "6. INSTANTWM / ROFI / KEYBOARD"
echo "-------------------------------------------------------------------------------"
echo "--- InstantWM binary ---"
command -v instantwm 2>/dev/null || echo "instantwm not found"
ls -la /usr/bin/instantwm 2>/dev/null || echo "/usr/bin/instantwm not found"
echo
echo "--- Rofi binary ---"
command -v rofi 2>/dev/null || echo "rofi not found"
ls -la /usr/bin/rofi 2>/dev/null || echo "/usr/bin/rofi not found"
echo
echo "--- InstantWM config ---"
cat /root/.config/instantwm/config.toml 2>/dev/null || cat /etc/skel/.config/instantwm/config.toml 2>/dev/null || echo "InstantWM config not found"
echo
echo "--- InstantWM running? ---"
ps aux 2>/dev/null | grep -i instantwm | grep -v grep || echo "InstantWM not running"
echo
echo "--- seatd socket ---"
ls -la /run/seatd.sock 2>/dev/null || echo "seatd socket not found"
echo
echo "--- udevd socket ---"
ls -la /run/udev/control 2>/dev/null || echo "udevd control socket not found"
echo
echo "--- libinput devices ---"
libinput list-devices 2>/dev/null || echo "libinput not available"
echo

#-------------------------------------------------------------------------------
# 7. TTY / GETTY STATUS
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "7. TTY / GETTY STATUS"
echo "-------------------------------------------------------------------------------"
echo "--- /dev/tty* devices ---"
ls -la /dev/tty[0-9] 2>/dev/null || echo "No /dev/tty* devices found"
echo
echo "--- agetty binary ---"
command -v agetty 2>/dev/null || echo "agetty not found"
ls -la /usr/sbin/agetty /usr/bin/agetty /bin/agetty /sbin/agetty 2>/dev/null || echo "agetty binary not found in standard locations"
echo
echo "--- getty processes ---"
ps aux 2>/dev/null | grep -i agetty | grep -v grep || echo "No getty processes running"
echo
echo "--- /etc/inittab ---"
cat /etc/inittab 2>/dev/null || echo "/etc/inittab not found"
echo
echo "--- OpenRC getty services ---"
ls /etc/init.d/agetty* 2>/dev/null || echo "No agetty OpenRC services found"
rc-status 2>/dev/null | grep -i agetty || echo "rc-status not available or no agetty services"
echo

#-------------------------------------------------------------------------------
# 8. NVIDIA / GRAPHICS
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "8. NVIDIA / GRAPHICS STATUS"
echo "-------------------------------------------------------------------------------"
echo "--- GPU devices ---"
lspci -nnk 2>/dev/null | grep -A3 -i "vga\|3d\|nvidia\|nouveau\|amd\|radeon\|intel.*graphics" || echo "No GPU devices found via lspci"
echo
echo "--- NVIDIA driver modules ---"
lsmod 2>/dev/null | grep -i "nvidia\|nouveau" || echo "No NVIDIA/nouveau modules loaded"
echo
echo "--- NVIDIA .run file ---"
ls /nvidia-*.run 2>/dev/null || echo "No NVIDIA .run file in root"
ls /boot/nvidia-*.run 2>/dev/null || echo "No NVIDIA .run file in /boot"
echo
echo "--- /etc/modprobe.d/nvidia* ---"
ls /etc/modprobe.d/nvidia* 2>/dev/null || echo "No NVIDIA modprobe config"
echo
echo "--- DRM devices ---"
ls /dev/dri/ 2>/dev/null || echo "No /dev/dri devices"
echo

#-------------------------------------------------------------------------------
# 9. INSTALLED PACKAGES (CRES)
#-------------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "9. CRESC PACKAGE MANAGER"
echo "-------------------------------------------------------------------------------"
echo "--- cres binary ---"
command -v cres 2>/dev/null || echo "cres not found"
ls -la /usr/bin/cres 2>/dev/null || echo "/usr/bin/cres not found"
echo
echo "--- cres list (if available) ---"
cres list 2>/dev/null || echo "cres list failed or cres not installed"
echo
echo "--- spk (should NOT be present) ---"
command -v spk 2>/dev/null && echo "WARNING: spk is still installed!" || echo "spk not found (correct - removed in favor of cres)"
echo

echo "================================================================================"
echo "End of diagnostic report"
echo "================================================================================"

} > "$OUTPUT" 2>&1

echo "Diagnostic report saved to: $OUTPUT"
echo "Please share this file with the Silen maintainers for troubleshooting."
