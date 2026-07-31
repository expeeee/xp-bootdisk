#!/bin/bash
# Universal AMD & NVIDIA Dynamic GPU Finder and VFIO Isolator

set -e

echo "[*] Scanning PCI bus for discrete GPUs (NVIDIA 10de / AMD 1002)..."

# Scan for both NVIDIA (10de) and AMD (1002) display/VGA controllers
GPUS=$(lspci -nn | grep -iE '10de:|1002:' | grep -iE 'VGA|3D|Display')

if [ -z "$GPUS" ]; then
    echo "[!] No discrete AMD or NVIDIA GPUs detected on the host system."
    exit 1
fi

declare -a GPU_LIST
while read -r line; do
    BUS_ID=$(echo "$line" | awk '{print $1}')
    DEV_NAME=$(echo "$line" | sed -E 's/^[0-9a-f:]+ //')
    GPU_LIST+=("$BUS_ID" "$DEV_NAME")
done <<< "$GPUS"

# Present menu to user
SELECTED_BUS=$(dialog --clear --backtitle "AUTO HARDWARE PASSTHROUGH CONFIGURATOR" \
    --title " Select GPU for Passthrough " \
    --menu "Choose a detected GPU to isolate and bind to VFIO:" 15 75 4 \
    "${GPU_LIST[@]}" 3>&1 1>&2 2>&3)

if [ -z "$SELECTED_BUS" ]; then
    echo "[!] No GPU selected. Returning to caller..."
    exit 1
fi

# Extract base slot ID (e.g. 0000:01:00)
BASE_PCI_SLOT="0000:${SELECTED_BUS%.*}"
PRIMARY_ADDR="${BASE_PCI_SLOT}.0"

# Determine Vendor Type
VENDOR_ID=$(cat "/sys/bus/pci/devices/$PRIMARY_ADDR/vendor" 2>/dev/null || true)

PASSTHROUGH_CMD_ARGS=""

echo "[+] Auto-detected Vendor ID: $VENDOR_ID for device slot $BASE_PCI_SLOT"

# Loop through all PCI sub-functions (.0 graphics, .1 audio, .2 USB, .3 serial)
for FUNC in 0 1 2 3; do
    ADDR="${BASE_PCI_SLOT}.${FUNC}"
    if [ -d "/sys/bus/pci/devices/$ADDR" ]; then
        echo "[*] Rebinding $ADDR to vfio-pci..."
        
        # Override driver target
        echo "vfio-pci" > "/sys/bus/pci/devices/$ADDR/driver_override"
        
        # Unbind from host driver (e.g. nvidia, amdgpu, snd_hda_intel) if active
        if [ -e "/sys/bus/pci/devices/$ADDR/driver/unbind" ]; then
            echo "$ADDR" > "/sys/bus/pci/devices/$ADDR/driver/unbind" 2>/dev/null || true
        fi
        
        # Bind to vfio-pci
        echo "$ADDR" > "/sys/bus/pci/drivers/vfio-pci/bind" 2>/dev/null || true
        echo "" > "/sys/bus/pci/devices/$ADDR/driver_override"

        # Build QEMU arguments for all functions
        if [ "$FUNC" -eq 0 ]; then
            PASSTHROUGH_CMD_ARGS="$PASSTHROUGH_CMD_ARGS -device vfio-pci,host=$ADDR,x-vga=on,multifunction=on"
        else
            PASSTHROUGH_CMD_ARGS="$PASSTHROUGH_CMD_ARGS -device vfio-pci,host=$ADDR"
        fi
    fi
done

# If NVIDIA is detected, append necessary Hypervisor Concealment flags for CPU
if [ "$VENDOR_ID" == "0x10de" ]; then
    echo "[+] NVIDIA GPU detected: Appending KVM stealth parameters to avoid Code 43."
    GPU_CPU_FLAGS="kvm=off,hv_vendor_id=null"
else
    GPU_CPU_FLAGS=""
fi

export PASSTHROUGH_CMD_ARGS
export GPU_CPU_FLAGS
echo "[+] Successfully bound $BASE_PCI_SLOT.* to vfio-pci."
