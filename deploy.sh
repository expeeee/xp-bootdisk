#!/bin/bash
# XP-Bootdisk safe interactive USB deployer.

set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[!] Run this script with sudo or as root."
    exit 1
fi

for cmd in lsblk awk grep dd parted partprobe sgdisk blockdev mkfs.exfat mount umount mountpoint sync; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[!] Missing required command: $cmd"
        exit 1
    }
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIC_IMAGE="${WIC_IMAGE:-$PROJECT_ROOT/poky/build/tmp/deploy/images/qemux86-64/ramboot-image-qemux86-64.rootfs.wic}"

if [ ! -f "$WIC_IMAGE" ]; then
    echo "[!] Yocto WIC image not found:"
    echo "    $WIC_IMAGE"
    echo "    Run ./setup.sh first, or set WIC_IMAGE to an explicit .wic file."
    exit 1
fi

echo "=========================================="
echo "      XP-BOOTDISK USB DEPLOYMENT TOOL"
echo "=========================================="
echo "[+] Image: $WIC_IMAGE"
echo
echo "[+] USB disks detected:"
USB_DEVICES="$(lsblk -dnpo NAME,SIZE,TRAN,RM,TYPE | awk '$3 == "usb" && $5 == "disk" {print}')"
if [ -z "$USB_DEVICES" ]; then
    echo "[!] No whole-disk block device with TRAN=usb was detected."
    exit 1
fi
printf '%s\n' "$USB_DEVICES"
echo

read -r -p "[?] Enter the complete target path (for example /dev/sdb): " TARGET_DEV
if ! printf '%s\n' "$USB_DEVICES" | awk '{print $1}' | grep -Fxq -- "$TARGET_DEV"; then
    echo "[!] $TARGET_DEV is not one of the USB disks listed above."
    exit 1
fi

echo
echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE ERASED."
read -r -p "[?] Type the complete device path again to confirm: " CONFIRM
if [ "$CONFIRM" != "$TARGET_DEV" ]; then
    echo "[-] Confirmation did not match; deployment aborted."
    exit 0
fi

echo "[+] Unmounting mounted partitions on $TARGET_DEV..."
mapfile -t MOUNTED_PARTS < <(lsblk -lnpo NAME,MOUNTPOINT "$TARGET_DEV" | awk 'NR > 1 && $2 != "" {print $1}')
for ((i=${#MOUNTED_PARTS[@]}-1; i>=0; i--)); do
    umount "${MOUNTED_PARTS[$i]}"
done

echo "[+] Writing the GPT/UEFI host image..."
dd if="$WIC_IMAGE" of="$TARGET_DEV" bs=4M status=progress conv=fsync
partprobe "$TARGET_DEV" || true
sgdisk -e "$TARGET_DEV"
partprobe "$TARGET_DEV" || true

LAST_END="$(parted -m "$TARGET_DEV" unit s print | awk -F: '/^[0-9]+:/{gsub(/s/, "", $3); if ($3 > max) max=$3} END{print max+0}')"
DISK_SECTORS="$(blockdev --getsz "$TARGET_DEV")"
DATA_START=$((LAST_END + 2048))
if [ $((DISK_SECTORS - DATA_START)) -lt 2097152 ]; then
    echo "[!] Less than 1 GiB remains for XP-BOOTDATA; use a larger USB disk."
    exit 1
fi

echo "[+] Creating XP-BOOTDATA after sector $LAST_END..."
parted -s "$TARGET_DEV" unit s mkpart XP-BOOTDATA exfat "${DATA_START}s" 100%
partprobe "$TARGET_DEV" || true

DATA_NUM="$(parted -m "$TARGET_DEV" unit s print | awk -F: '/^[0-9]+:/{if ($1 > max) max=$1} END{print max+0}')"
if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    PART_DATA="${TARGET_DEV}p${DATA_NUM}"
else
    PART_DATA="${TARGET_DEV}${DATA_NUM}"
fi

for _ in {1..20}; do
    [ -b "$PART_DATA" ] && break
    sleep 0.25
done
if [ ! -b "$PART_DATA" ]; then
    echo "[!] The new partition device did not appear: $PART_DATA"
    exit 1
fi

echo "[+] Formatting $PART_DATA as exFAT..."
mkfs.exfat -L XP-BOOTDATA "$PART_DATA"

MNT_DIR="$(mktemp -d /tmp/xp-bootdata.XXXXXX)"
cleanup() {
    if mountpoint -q "$MNT_DIR"; then
        umount "$MNT_DIR" || true
    fi
    rmdir "$MNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mount "$PART_DATA" "$MNT_DIR"
mkdir -p "$MNT_DIR/payloads" "$MNT_DIR/isos"
sync
umount "$MNT_DIR"
rmdir "$MNT_DIR"
trap - EXIT

echo
echo "=========================================="
echo "SUCCESS: XP-Bootdisk was deployed."
echo "Data partition: $PART_DATA (XP-BOOTDATA)"
echo "=========================================="
