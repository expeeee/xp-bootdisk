#!/bin/bash
# Seamless QEMU Payload Extractor & Launcher

set -e

# Hide terminal cursor
setterm -cursor off 2>/dev/null || true

PAYLOAD_DIR="/media/usb/payloads"
ISO_DIR="/media/usb/isos"
RAMDISK="/mnt/ramdisk"
SWTPM_DIR="/tmp/swtpm"
OVMF_CODE="/usr/share/ovmf/OVMF_CODE.fd"
OVMF_VARS_TEMPLATE="/usr/share/ovmf/OVMF_VARS.fd"

mkdir -p "$RAMDISK" "$ISO_DIR"

# Mount tmpfs using 80% of host RAM
if ! mountpoint -q "$RAMDISK"; then
    mount -t tmpfs -o size=80% tmpfs "$RAMDISK"
fi

clear

CHOICE=$(dialog --backtitle "HYPERVISOR BOOT MANAGER" \
    --title " Select Target Operating System " \
    --menu "Choose an OS payload to extract into RAM and launch:" 15 60 4 \
    1 "Windows 11 LTSC (TPM 2.0 + UEFI)" \
    2 "Linux OS (Native Live Image)" \
    3 "Boot ISO (Virtual Ventoy)" \
    4 "Exit to Shell" \
    3>&1 1>&2 2>&3)

clear

if [ "$CHOICE" == "4" ] || [ -z "$CHOICE" ]; then
    echo "Exiting hypervisor launcher..."
    setterm -cursor on 2>/dev/null || true
    exit 0
fi

# Query user for GPU Passthrough
GPU_PASSTHROUGH_ARGS="-vga virtio"
CPU_EXTRA_FLAGS=""

if dialog --backtitle "HARDWARE PASSTHROUGH" --yesno "Would you like to pass through a physical GPU (AMD/NVIDIA) to the guest VM?" 7 60; then
    clear
    source /usr/bin/bind-gpu
    if [ -n "$PASSTHROUGH_CMD_ARGS" ]; then
        GPU_PASSTHROUGH_ARGS="-nographic -display none $PASSTHROUGH_CMD_ARGS"
        CPU_EXTRA_FLAGS="$GPU_CPU_FLAGS"
    fi
fi

clear

case $CHOICE in
    1)
        ARCHIVE="$PAYLOAD_DIR/win11.tar.xz"
        IMG="$RAMDISK/win11.qcow2"
        
        if [ ! -f "$ARCHIVE" ]; then
            echo "[!] Error: Win11 payload not found at $ARCHIVE"
            read -p "Press Enter to return..."
            exit 1
        fi
        
        echo "[+] Decompressing Windows 11 payload into RAM disk..."
        tar -xJf "$ARCHIVE" -C "$RAMDISK"
        
        echo "[+] Initializing software TPM 2.0 interface..."
        mkdir -p "$SWTPM_DIR"
        swtpm socket --tpmstate dir="$SWTPM_DIR" \
                     --ctrl type=unixio,path="$SWTPM_DIR/swtpm-sock" \
                     --tpm2 &
        SWTPM_PID=$!
        sleep 1
        
        echo "[+] Preparing UEFI storage..."
        cp "$OVMF_VARS_TEMPLATE" "$RAMDISK/OVMF_VARS.fd"
        
        # Build CPU arguments cleanly
        if [ -n "$CPU_EXTRA_FLAGS" ]; then
            CPU_ARGS="host,${CPU_EXTRA_FLAGS},hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_synic,hv_stimer"
        else
            CPU_ARGS="host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_synic,hv_stimer"
        fi
        
        echo "[+] Booting Windows 11 in RAM..."
        qemu-system-x86_64 \
            -enable-kvm -machine q35,accel=kvm \
            -m 16G -smp 8,sockets=1,cores=4,threads=2 \
            -cpu "$CPU_ARGS" \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$RAMDISK/OVMF_VARS.fd" \
            -chardev socket,id=chrtpm,path="$SWTPM_DIR/swtpm-sock" \
            -tpmdev emulator,id=tpm0,chardev=chrtpm \
            -device tpm-tis,tpmdev=tpm0 \
            -drive file="$IMG",format=qcow2,if=virtio,aio=io_uring \
            -net nic,model=virtio -net user \
            $GPU_PASSTHROUGH_ARGS
            
        kill $SWTPM_PID 2>/dev/null || true
        ;;
        
    2)
        ARCHIVE="$PAYLOAD_DIR/linux.tar.xz"
        IMG="$RAMDISK/linux.img"
        
        if [ ! -f "$ARCHIVE" ]; then
            echo "[!] Error: Linux payload not found at $ARCHIVE"
            read -p "Press Enter to return..."
            exit 1
        fi
        
        echo "[+] Decompressing Linux payload into RAM disk..."
        tar -xJf "$ARCHIVE" -C "$RAMDISK"
        
        # Build CPU arguments cleanly
        if [ -n "$CPU_EXTRA_FLAGS" ]; then
            CPU_ARGS="host,${CPU_EXTRA_FLAGS}"
        else
            CPU_ARGS="host"
        fi
        
        echo "[+] Booting Linux VM in RAM..."
        qemu-system-x86_64 \
            -enable-kvm -machine q35,accel=kvm \
            -m 16G -smp 8 \
            -cpu "$CPU_ARGS" \
            -drive file="$IMG",format=raw,if=virtio,aio=io_uring \
            -net nic,model=virtio -net user \
            $GPU_PASSTHROUGH_ARGS
        ;;

    3)
        # Scan directory for ISOs
        declare -a ISO_MENU
        declare -A ISO_MAP
        index=1
        
        while read -r file_path; do
            if [ -n "$file_path" ]; then
                file_name=$(basename "$file_path")
                ISO_MENU+=("$index" "$file_name")
                ISO_MAP[$index]="$file_path"
                index=$((index+1))
            fi
        done < <(find "$ISO_DIR" -maxdepth 1 -type f -name "*.iso" 2>/dev/null)
        
        if [ ${#ISO_MENU[@]} -eq 0 ]; then
            dialog --title "No ISOs Found" --msgbox "Please place bootable .iso files in $ISO_DIR" 6 50
            exit 1
        fi
        
        ISO_CHOICE=$(dialog --backtitle "VIRTUAL VENTOY" \
            --title " Select ISO to Boot " \
            --menu "Choose an installer/live ISO to boot:" 15 65 6 \
            "${ISO_MENU[@]}" \
            3>&1 1>&2 2>&3)
            
        if [ -z "$ISO_CHOICE" ]; then
            echo "No ISO selected. Exiting..."
            exit 0
        fi
        
        SELECTED_ISO="${ISO_MAP[$ISO_CHOICE]}"
        
        # Ask if the user wants to attach a temporary virtual hard disk in RAM
        ATTACH_DISK=""
        if dialog --title "Virtual Disk" --yesno "Create a temporary 20GB virtual disk in RAM to install to?" 7 60; then
            TEMP_DISK="$RAMDISK/temp_target.qcow2"
            echo "[+] Creating 20GB temporary sparse virtual disk..."
            qemu-img create -f qcow2 "$TEMP_DISK" 20G
            ATTACH_DISK="-drive file=$TEMP_DISK,format=qcow2,if=virtio"
        fi
        
        # Build CPU arguments cleanly
        if [ -n "$CPU_EXTRA_FLAGS" ]; then
            CPU_ARGS="host,${CPU_EXTRA_FLAGS}"
        else
            CPU_ARGS="host"
        fi
        
        echo "[+] Preparing UEFI storage..."
        cp "$OVMF_VARS_TEMPLATE" "$RAMDISK/OVMF_VARS.fd"
        
        echo "[+] Booting $SELECTED_ISO in QEMU..."
        qemu-system-x86_64 \
            -enable-kvm -machine q35,accel=kvm \
            -m 8G -smp 4 \
            -cpu "$CPU_ARGS" \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$RAMDISK/OVMF_VARS.fd" \
            -drive file="$SELECTED_ISO",media=cdrom,readonly=on \
            -boot d \
            $ATTACH_DISK \
            -net nic,model=virtio -net user \
            $GPU_PASSTHROUGH_ARGS
        ;;
esac

echo "[+] Guest VM terminated. Cleaning up RAM disk..."
umount "$RAMDISK" || true
setterm -cursor on 2>/dev/null || true\n