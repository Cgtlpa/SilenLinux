#!/bin/bash
# Adds WiFi drivers (+ a few extra modules) and their firmware from the host
# kernel's module tree into rootfs/ so they get shipped on the ISO. The ISO
# build picks the initramfs modules from the ALLOW list in build.sh, but the
# FULL tree under rootfs/lib/modules is what the installer copies to the
# installed system (/mnt/modules), so both need the drivers.
#
# It also pulls the firmware for EVERY module already shipped in the tree, so
# once this has been run (and the results committed) the ISO build is fully
# self-contained: wifi + wired NICs work from boot with no build-time scripts
# and no host /lib/firmware needed.
#
# Usage:  ./scripts/add-wifi.sh [KERNEL_VERSION]
# Default kernel version = the one already in rootfs/lib/modules.

set -e

KVER="${KVER:-$(ls rootfs/lib/modules 2>/dev/null | grep '^[0-9]' | head -n1)}"
if [ -z "$KVER" ]; then
    echo "ERROR: no kernel module tree found in rootfs/lib/modules." >&2
    echo "Set KVER=<version> or copy a module tree into rootfs/lib/modules first." >&2
    exit 1
fi

HOST=/usr/lib/modules/$KVER
DST=rootfs/lib/modules/$KVER
FW_SRC=/lib/firmware
FW_DST=rootfs/lib/firmware

if [ ! -d "$HOST" ]; then
    echo "ERROR: host module tree not found: $HOST" >&2
    exit 1
fi

echo "== Syncing modules from $HOST -> $DST"

# top-level drivers; every dependency is pulled in automatically below
WIFI_MODS="
	iwlwifi iwlmvm iwlmld iwldvm iwlegacy
	ath9k ath9k_htc ath5k
	ath10k_core ath10k_pci ath10k_sdio ath10k_usb
	ath11k ath11k_pci ath12k
	mt7601u
	mt7921e mt7921u mt7921s mt7925e mt7925u
	mt7915e mt7615e mt7663u mt7663s mt7603e mt7996e
	mt76x0u mt76x2u
	rtl8xxxu
	rtw88_pci rtw88_usb rtw88_sdio
	rtw88_8822be rtw88_8822ce rtw88_8822bu rtw88_8822cu
	rtw88_8821ce rtw88_8821cu
	rtw88_8723d rtw88_8723de rtw88_8723ds rtw88_8723du
	rtw88_8703b rtw88_8812au rtw88_8814ae rtw88_8814au
	rtw89_pci rtw89_usb
	rtw89_8851be rtw89_8851bu
	rtw89_8852ae rtw89_8852au rtw89_8852be rtw89_8852bu rtw89_8852ce rtw89_8852cu
	rtw89_8922ae rtw89_8922au
	rtlwifi rtl_pci rtl_usb
	rtl8192ce rtl8192cu rtl8192de rtl8192se
	rtl8188ee rtl8723ae rtl8723be rtl8821ae
	brcmfmac brcmsmac b43 b43legacy bcma ssb
	rt2400pci rt2500pci rt61pci rt2800pci
	rt2500usb rt73usb rt2800usb
	cfg80211 mac80211
"

# a few small extra modules (cheap USB ethernet, exfat, some legacy NICs)
EXTRA_MODS="
	exfat
	cdc_ether rndis_host rndis_wlan
	alx 8139too via-rhine
"

# firmware that drivers request at runtime but don't advertise via modinfo
EXTRA_FW="
	iwlwifi:iwlwifi-*.ucode*
	rtw88_core:rtw88/*
	rtw89_core:rtw89/*
	cfg80211:regulatory.db
	cfg80211:regulatory.db.p7s
"

# ---------------------------------------------------------------------------
# index the host tree by module basename
# ---------------------------------------------------------------------------

declare -A file_by_name
while IFS= read -r path; do
    name="${path##*/}"
    name="${name%.ko.zst}"
    name="${name%.ko}"
    if [ -z "${file_by_name[$name]:-}" ]; then
        file_by_name[$name]="$path"
    fi
done < <(find "$HOST" \( -name '*.ko' -o -name '*.ko.zst' \))

mod_file() {
    local name="$1"
    if [ -n "${file_by_name[$name]:-}" ]; then
        printf '%s\n' "${file_by_name[$name]}"
    else
        printf '%s\n' "${file_by_name[${name//_/-}]:-}"
    fi
}

# ---------------------------------------------------------------------------
# copy modules + dependency closure
# ---------------------------------------------------------------------------

seen=" "
copied=" "
queue=()
for m in $WIFI_MODS $EXTRA_MODS; do
    queue+=("$m")
done

while [ ${#queue[@]} -gt 0 ]; do
    name="${queue[0]}"
    queue=("${queue[@]:1}")

    path="$(mod_file "$name")"
    [ -z "$path" ] && continue

    case " $seen " in
        *" $name "*) continue ;;
    esac
    seen="$seen $name "

    relative="${path#$HOST/}"
    mkdir -p "$DST/$(dirname "$relative")"
    if [ ! -f "$DST/$relative" ]; then
        cp "$path" "$DST/$relative"
        echo "  module: $relative"
    fi
    copied="$copied $path "

    deps="$(modinfo -F depends "$path" 2>/dev/null)"
    for dep in ${deps//,/ }; do
        [ -n "$dep" ] && queue+=("$dep")
    done
done

# ---------------------------------------------------------------------------
# firmware for each copied module (glob + .zst aware)
# ---------------------------------------------------------------------------

fw_from_module() {
    local path="$1" fw
    modinfo -F firmware "$path" 2>/dev/null | while IFS= read -r fw; do
        [ -n "$fw" ] || continue
        copy_fw "$fw"
    done
}

fw_copy_from_src() {
    local src="$1" rel="$2"
    local target="$FW_DST/$rel"
    mkdir -p "$(dirname "$target")"
    if [ ! -f "$target" ]; then
        cp "$src" "$target"
        echo "  firmware: $rel"
    fi
}

copy_fw() {
    local fw="$1" f matched=0
    set -- $FW_SRC/$fw
    for f in "$@"; do
        [ -e "$f" ] || continue
        matched=1
        local rel="${f#$FW_SRC/}"
        if [ -d "$f" ]; then
            if [ ! -d "$FW_DST/$rel" ]; then
                mkdir -p "$FW_DST/$(dirname "$rel")"
                cp -a "$f" "$FW_DST/$rel"
                echo "  firmware: $rel/"
            fi
        else
            fw_copy_from_src "$f" "$rel"
        fi
    done
    if [ "$matched" = 0 ]; then
        copy_fw_zst "$fw"
    fi
}

copy_fw_zst() {
    local fw="$1"
    [ -f "$FW_SRC/$fw.zst" ] || return 0
    fw_copy_from_src "$FW_SRC/$fw.zst" "${fw}.zst"
}

echo "  copying firmware..."
while IFS= read -r path; do
    fw_from_module "$path"
done < <(printf '%s\n' $copied)

# firmware for every module that ships in the tree (the base storage/NIC
# drivers like r8169/tg3/r8152 too), so the ISO build is fully self-contained
# and never depends on the host firmware tree at build time.
echo "  copying firmware for all shipped modules..."
while IFS= read -r path; do
    fw_from_module "$path"
done < <(find "$DST" \( -name '*.ko' -o -name '*.ko.zst' \))

echo "  copying extra firmware..."
while IFS=':' read -r mod fwlist; do
    [ -n "$mod" ] && [ -n "$fwlist" ] || continue
    case " $seen " in
        *" $mod "*) ;;
        *) continue ;;
    esac
    IFS=',' read -r -a extras <<<"$fwlist"
    for fw in "${extras[@]}"; do
        [ -n "$fw" ] && copy_fw "$fw"
    done
done <<EOF
$EXTRA_FW
EOF

# ---------------------------------------------------------------------------
# refresh the metadata so the installed system's modprobe/depmod works
# ---------------------------------------------------------------------------

for meta in modules.builtin modules.builtin.alias.bin modules.builtin.bin \
            modules.builtin.modinfo; do
    [ -f "$HOST/$meta" ] && cp "$HOST/$meta" "$DST/$meta" 2>/dev/null || true
done

echo "  regenerating modules.dep / modules.alias ..."
depmod -b rootfs "$KVER" 2>/dev/null || true

echo
echo "Done. Now make sure the same driver names are on the ALLOW list in"
echo "scripts/build.sh so the live initramfs gets them too."