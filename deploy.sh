#!/bin/bash
# xp-bootdisk Safe Interactive USB Deployer
# Requires root privileges to execute raw disk flashing and partitioning.

set -e

# Force root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[!] Error: Please run this script with sudo or as root."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIC_IMAGE="$PROJECT_ROOT/poky/build/tmp/deploy/images/qemux86-64/ramboot-image-qemux86-64.wic"

echo "=========================================="
echo "      XP-BOOTDISK USB DEPLOYMENT TOOL     "
echo "=========================================="

# 1. Verify WIC image existence
if [ ! -f "$WIC_IMAGE" ]; then
    echo "[!] Error: Yocto build image not found at:"
    echo "    $WIC_IMAGE"
    echo "    Please run a build first (e.g. using ./setup.sh)."
    exit 1
fi

echo "[+] Found build image: $(basename "$WIC_IMAGE")"
echo ""

# 2. Identify USB drives
echo "[+] Scanning for connected USB storage drives..."
echo "--------------------------------------------------"
# Find block devices filtered by USB transport type or removable properties
USB_DEVICES=$(lsblk -d -n -o NAME,SIZE,TRAN,RM | grep -E 'usb|1$' || true)

if [ -z "$USB_DEVICES" ]; then
    echo "[!] Error: No USB storage drives detected."
    echo "    Please plug in your target USB key and try again."
    exit 1
fi

# Print header and devices
printf "%-10s %-10s %-10s\n" "DEVICE" "SIZE" "TYPE"
echo "--------------------------------------------------"
echo "$USB_DEVICES" | while read -r name size tran rm; do
    printf "%-10s %-10s %-10s\n" "/dev/$name" "$size" "USB Key"
done
echo "--------------------------------------------------"
echo ""

# 3. Solicit target drive choice
read -p "[?] Enter the target device name to flash (e.g. sdb, sdc): " TARGET_NAME
TARGET_NAME=$(echo "$TARGET_NAME" | sed 's|^/dev/||')

# Validate choice exists in usb list
if ! echo "$USB_DEVICES" | grep -q "^$TARGET_NAME "; then
    echo "[!] Error: Invalid selection '/dev/$TARGET_NAME'. Device is not in the USB list."
    exit 1
fi

TARGET_DEV="/dev/$TARGET_NAME"
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE ERASED!"
echo "This includes all partitions and filesystem structures."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "[?] Are you absolutely sure you want to write to $TARGET_DEV? (type 'yes' to confirm): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "[-] Deployment aborted by user."
    exit 0
fi

# 4. Unmount any active partitions on the target drive
echo "[+] Unmounting any active partitions on $TARGET_DEV..."
for part in ${TARGET_DEV}*; do
    if mountpoint -q "$part" 2>/dev/null || grep -q "$part" /proc/mounts; then
        echo "    Unmounting $part..."
        umount -f "$part" || true
    fi
done

# 5. Burn WIC Image
echo "[+] Flashing Yocto OS partitions to $TARGET_DEV..."
dd if="$WIC_IMAGE" of="$TARGET_DEV" bs=4M status=progress conv=fsync
echo "[+] OS flashing complete."

# 6. Re-scan partition table
partprobe "$TARGET_DEV" || true
sleep 1

# 7. Create payloads & isos data partition
echo "[+] Provisioning secondary data partition on remaining USB space..."
# Create a primary partition starting at 3GB (after OS partitions) extending to 100%
parted -s "$TARGET_DEV" mkpart primary exfat 3GiB 100%
partprobe "$TARGET_DEV" || true
sleep 1

# Format as exFAT
PART_DATA="${TARGET_DEV}2"
# Handle NVMe style partition naming (e.g. nvme0n1p2) if USB identifies as nvme (rare but possible)
if [[ "$TARGET_DEV" =~ nvme || "$TARGET_DEV" =~ mmcblk ]]; then
    PART_DATA="${TARGET_DEV}p2"
fi

echo "[+] Formatting $PART_DATA partition as exFAT (Label: XP-BOOTDATA)..."
mkfs.exfat -L "XP-BOOTDATA" "$PART_DATA"

# 8. Create folder structure on data partition
echo "[+] Creating /payloads and /isos directory structures..."
MNT_DIR="/tmp/mnt_xp_usb"
mkdir -p "$MNT_DIR"

if mount "$PART_DATA" "$MNT_DIR" 2>/dev/null; then
    mkdir -p "$MNT_DIR/payloads" "$MNT_DIR/isos"
    echo "    Success: folders '/payloads' and '/isos' created."
    umount "$MNT_DIR"
else
    echo "[!] Warning: Could not auto-mount $PART_DATA to create directories."
    echo "    Please mount the partition manually and create /payloads and /isos."
fi

rm -rf "$MNT_DIR"
echo ""
echo "=========================================="
echo "SUCCESS: xp-bootdisk has been deployed!"
echo "You can now copy OS payloads or ISOs to the USB data partition."
echo "=========================================="
