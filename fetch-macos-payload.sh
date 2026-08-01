#!/bin/bash
# macOS Payload Preparation Script for xp-bootdisk
# Run this on a Linux machine with internet access to prepare the macOS payload
# that will be placed on the USB XP-BOOTDATA partition.
#
# Usage:
#   ./fetch-macos-payload.sh [ventura|sonoma|sequoia|monterey|bigsur|catalina]
#
# Output:
#   macos.tar.xz — ready to copy to /media/usb/payloads/macos.tar.xz

set -e

MACOS_VERSION="${1:-sonoma}"
OUTPUT_DIR="$(pwd)/macos-payload-build"
OCSOURCE="https://github.com/kholia/OSX-KVM.git"
DISK_SIZE="256G"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[X]${NC} $1"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# 1. Check Prerequisites
# ──────────────────────────────────────────────────────────────────────────────
for cmd in git qemu-img python3 pip3 dmg2img; do
    if ! command -v "$cmd" &>/dev/null; then
        warn "$cmd not found. Installing dependencies..."
        sudo apt-get install -y qemu-utils python3 python3-pip dmg2img git 2>/dev/null || \
        sudo pacman -S --noconfirm qemu-full python python-pip git 2>/dev/null || \
        err "Please install: git qemu-img python3 pip3 dmg2img"
    fi
done

log "All prerequisites found."

# ──────────────────────────────────────────────────────────────────────────────
# 2. Clone OSX-KVM for OpenCore EFI and OVMF firmware
# ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

if [ ! -d "OSX-KVM" ]; then
    log "Cloning OSX-KVM repository (OpenCore EFI + OVMF)..."
    git clone --depth 1 --recursive "$OCSOURCE" OSX-KVM
else
    log "OSX-KVM already cloned. Pulling updates..."
    git -C OSX-KVM pull --rebase
fi

log "Installing Python dependencies..."
pip3 install -r OSX-KVM/requirements.txt --quiet

# ──────────────────────────────────────────────────────────────────────────────
# 3. Fetch macOS Recovery Image from Apple
# ──────────────────────────────────────────────────────────────────────────────
log "Fetching macOS $MACOS_VERSION recovery image from Apple..."
python3 OSX-KVM/fetch-macOS-v2.py --version "$MACOS_VERSION"

log "Converting BaseSystem.dmg to raw image..."
dmg2img -i BaseSystem.dmg BaseSystem.img || qemu-img convert BaseSystem.dmg -O raw BaseSystem.img

# ──────────────────────────────────────────────────────────────────────────────
# 4. Create blank macOS installation disk
# ──────────────────────────────────────────────────────────────────────────────
if [ ! -f "mac_hdd_ng.qcow2" ]; then
    log "Creating blank $DISK_SIZE macOS installation disk..."
    qemu-img create -f qcow2 mac_hdd_ng.qcow2 "$DISK_SIZE"
else
    warn "mac_hdd_ng.qcow2 already exists — skipping creation."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. Copy OpenCore EFI and OVMF firmware
# ──────────────────────────────────────────────────────────────────────────────
log "Copying OpenCore EFI bootloader..."
mkdir -p opencore
cp -f "OSX-KVM/OpenCore/OpenCore.qcow2" opencore/

log "Copying OVMF firmware (code + vars)..."
mkdir -p ovmf
cp -f "OSX-KVM/OVMF/OVMF_CODE.fd" ovmf/
cp -f "OSX-KVM/OVMF/OVMF_VARS.fd"  ovmf/OVMF_VARS-macos.fd

# ──────────────────────────────────────────────────────────────────────────────
# 6. Enable KVM ignore_msrs (required for macOS)
# ──────────────────────────────────────────────────────────────────────────────
warn "Checking KVM ignore_msrs setting (required for macOS guests)..."
if [ "$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null)" != "1" ]; then
    warn "Setting ignore_msrs=1 temporarily..."
    echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs > /dev/null || true
fi

if [ ! -f /etc/modprobe.d/kvm-macos.conf ]; then
    log "Installing persistent KVM module config..."
    echo -e "options kvm ignore_msrs=1\noptions kvm report_ignored_msrs=0" | \
        sudo tee /etc/modprobe.d/kvm-macos.conf > /dev/null
    log "KVM config installed to /etc/modprobe.d/kvm-macos.conf"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 7. Package everything into a tar.xz payload
# ──────────────────────────────────────────────────────────────────────────────
log "Packaging macOS payload archive..."
log "  mac_hdd_ng.qcow2 (${DISK_SIZE} sparse disk)"
log "  BaseSystem.img   (macOS $MACOS_VERSION recovery)"
log "  opencore/OpenCore.qcow2"
log "  ovmf/OVMF_CODE.fd + OVMF_VARS-macos.fd"

PAYLOAD_ARCHIVE="${OUTPUT_DIR}/../macos.tar.xz"
tar -cJf "$PAYLOAD_ARCHIVE" \
    --transform "s|^\./||" \
    ./mac_hdd_ng.qcow2 \
    ./BaseSystem.img \
    ./opencore/ \
    ./ovmf/

log "Done! Payload archive: $(realpath "$PAYLOAD_ARCHIVE")"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Copy macos.tar.xz to your USB XP-BOOTDATA partition:"
echo "     cp $(realpath "$PAYLOAD_ARCHIVE") /media/usb/payloads/"
echo ""
echo "  2. Boot from the USB drive. macOS will appear in the launcher menu."
echo ""
echo "  3. On first launch, select 'Install macOS' in the OpenCore menu,"
echo "     then format and install to the main disk (mac_hdd_ng.qcow2)."
echo ""
echo "  4. After installation, re-run with 'persist' from inside the VM"
echo "     or from the launcher prompt to save back to the USB drive."
echo ""
warn "LEGAL NOTE: Running macOS on non-Apple hardware may violate Apple's EULA."
warn "This script is intended for development and testing purposes only."
