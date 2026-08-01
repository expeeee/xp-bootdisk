#!/bin/bash
# Seamless QEMU Payload Extractor & Launcher with Auto-Persist & Bridging

set -e

# Hide terminal cursor
setterm -cursor off 2>/dev/null || true

PAYLOAD_DIR="/media/usb/payloads"
ISO_DIR="/media/usb/isos"
RAMDISK="/mnt/ramdisk"
SWTPM_DIR="/tmp/swtpm"
OVMF_CODE="/usr/share/ovmf/OVMF_CODE.fd"
OVMF_VARS_TEMPLATE="/usr/share/ovmf/OVMF_VARS.fd"

# macOS-specific paths (inside extracted macos payload)
MACOS_OVMF_CODE="$RAMDISK/ovmf/OVMF_CODE.fd"
MACOS_OVMF_VARS_TEMPLATE="$RAMDISK/ovmf/OVMF_VARS-macos.fd"
MACOS_OPENCORE="$RAMDISK/opencore/OpenCore.qcow2"
MACOS_RECOVERY="$RAMDISK/BaseSystem.img"
MACOS_HDD="$RAMDISK/mac_hdd_ng.qcow2"

# Apple SMC key (required for macOS boot — from OSX-KVM project)
APPLE_OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

mkdir -p "$RAMDISK" "$ISO_DIR"

# Mount tmpfs using 80% of host RAM
if ! mountpoint -q "$RAMDISK"; then
    mount -t tmpfs -o size=80% tmpfs "$RAMDISK"
fi

# Clean up old trigger files & sockets
rm -f /tmp/auto_persist /tmp/qemu-monitor.sock

# Start background persist HTTP server
if [ -f "/usr/bin/persist-server" ]; then
    /usr/bin/persist-server &
    SERVER_PID=$!
fi

clear

CHOICE=$(dialog --backtitle "HYPERVISOR BOOT MANAGER" \
    --title " Select Target Operating System " \
    --menu "Choose an OS payload to extract into RAM and launch:" 17 65 6 \
    1 "Windows 11 LTSC (TPM 2.0 + UEFI)" \
    2 "Linux OS (Native Live Image)" \
    3 "macOS (OpenCore + VFIO GPU recommended)" \
    4 "Boot ISO (Virtual Ventoy)" \
    5 "Exit to Shell" \
    3>&1 1>&2 2>&3)

clear

if [ "$CHOICE" == "5" ] || [ -z "$CHOICE" ]; then
    echo "Exiting hypervisor launcher..."
    if [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi
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

# Common QEMU arguments
NET_ARGS="-netdev tap,id=net0,ifname=tap0,script=/etc/qemu-ifup,downscript=/etc/qemu-ifdown -device virtio-net-pci,netdev=net0"
# macOS needs vmxnet3 NIC for best compatibility
MAC_NET_ARGS="-netdev tap,id=net0,ifname=tap0,script=/etc/qemu-ifup,downscript=/etc/qemu-ifdown -device vmxnet3,netdev=net0,id=net0,mac=52:54:00:09:49:17"
MONITOR_ARGS="-monitor unix:/tmp/qemu-monitor.sock,server,nowait"

case $CHOICE in
    1)
        ARCHIVE="$PAYLOAD_DIR/win11.tar.xz"
        IMG="$RAMDISK/win11.qcow2"
        
        if [ ! -f "$ARCHIVE" ]; then
            echo "[!] Error: Win11 payload not found at $ARCHIVE"
            read -p "Press Enter to return..."
            if [ -n "$SERVER_PID" ]; then kill $SERVER_PID 2>/dev/null || true; fi
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
            $NET_ARGS \
            $MONITOR_ARGS \
            $GPU_PASSTHROUGH_ARGS
            
        kill $SWTPM_PID 2>/dev/null || true
        ;;
        
    2)
        ARCHIVE="$PAYLOAD_DIR/linux.tar.xz"
        IMG="$RAMDISK/linux.img"
        
        if [ ! -f "$ARCHIVE" ]; then
            echo "[!] Error: Linux payload not found at $ARCHIVE"
            read -p "Press Enter to return..."
            if [ -n "$SERVER_PID" ]; then kill $SERVER_PID 2>/dev/null || true; fi
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
            $NET_ARGS \
            $MONITOR_ARGS \
            $GPU_PASSTHROUGH_ARGS
        ;;

    3)
        # ── macOS via OpenCore ──────────────────────────────────────────────
        ARCHIVE="$PAYLOAD_DIR/macos.tar.xz"

        if [ ! -f "$ARCHIVE" ]; then
            dialog --title "Payload Missing" --msgbox "macOS payload not found at $ARCHIVE\n\nRun fetch-macos-payload.sh on a Linux machine to create it." 8 65
            if [ -n "$SERVER_PID" ]; then kill $SERVER_PID 2>/dev/null || true; fi
            exit 1
        fi

        echo "[+] Decompressing macOS payload into RAM disk..."
        tar -xJf "$ARCHIVE" -C "$RAMDISK"

        # Ensure KVM MSR ignore is set (required for macOS)
        echo 1 > /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || true

        echo "[+] Preparing macOS OVMF NVRAM (writable copy)..."
        cp "$MACOS_OVMF_VARS_TEMPLATE" "$RAMDISK/OVMF_VARS-macos-run.fd"

        # macOS must use Haswell-noTSX (AVX2) with Intel vendor spoof
        MAC_CPU_ARGS="Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,check"

        # macOS GPU passthrough: replace software VGA with VFIO args if user selected GPU
        if echo "$GPU_PASSTHROUGH_ARGS" | grep -q "vfio-pci"; then
            MAC_GPU_ARGS="-vga none -display none $PASSTHROUGH_CMD_ARGS"
        else
            # macOS cannot use virtio-vga; fall back to vmware SVGA for software rendering
            MAC_GPU_ARGS="-vga vmware -display default,show-cursor=on"
        fi

        echo "[+] Booting macOS in RAM via OpenCore..."
        qemu-system-x86_64 \
            -enable-kvm \
            -m 8G \
            -cpu "$MAC_CPU_ARGS" \
            -machine q35 \
            -smp 8,sockets=1,cores=4,threads=2 \
            -device usb-ehci,id=ehci \
            -device qemu-xhci,id=xhci \
            -device usb-kbd,bus=xhci.0 \
            -device usb-tablet,bus=xhci.0 \
            -device isa-applesmc,osk="$APPLE_OSK" \
            -drive if=pflash,format=raw,readonly=on,file="$MACOS_OVMF_CODE" \
            -drive if=pflash,format=raw,file="$RAMDISK/OVMF_VARS-macos-run.fd" \
            -smbios type=2 \
            -device ich9-intel-hda \
            -device hda-duplex \
            -device ich9-ahci,id=sata \
            -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$MACOS_OPENCORE" \
            -device ide-hd,bus=sata.2,drive=OpenCoreBoot \
            -drive id=InstallMedia,if=none,file="$MACOS_RECOVERY",format=raw \
            -device ide-hd,bus=sata.3,drive=InstallMedia \
            -drive id=MacHDD,if=none,file="$MACOS_HDD",format=qcow2 \
            -device ide-hd,bus=sata.4,drive=MacHDD \
            $MAC_NET_ARGS \
            $MONITOR_ARGS \
            $MAC_GPU_ARGS
        ;;

    4)
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
            if [ -n "$SERVER_PID" ]; then kill $SERVER_PID 2>/dev/null || true; fi
            exit 1
        fi
        
        ISO_CHOICE=$(dialog --backtitle "VIRTUAL VENTOY" \
            --title " Select ISO to Boot " \
            --menu "Choose an installer/live ISO to boot:" 15 65 6 \
            "${ISO_MENU[@]}" \
            3>&1 1>&2 2>&3)
            
        if [ -z "$ISO_CHOICE" ]; then
            echo "No ISO selected. Exiting..."
            if [ -n "$SERVER_PID" ]; then kill $SERVER_PID 2>/dev/null || true; fi
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
            $NET_ARGS \
            $MONITOR_ARGS \
            $GPU_PASSTHROUGH_ARGS
        ;;
esac

# Reassign ISO Ventoy to case 4 (menu item renumbered from 3 to 4)

# Kill HTTP server daemon
if [ -n "$SERVER_PID" ]; then
    kill $SERVER_PID 2>/dev/null || true
fi

# Determine whether to save changes
RUN_PERSIST=0
if [ -f "/tmp/auto_persist" ]; then
    RUN_PERSIST=1
    rm -f "/tmp/auto_persist"
    echo "[+] Auto-persist triggered by guest VM."
else
    clear
    # Check if console environment is present and query the user
    if dialog --backtitle "PERSIST CHANGES" --yesno "Would you like to compress and persist changes back to the USB drive?" 7 60; then
        RUN_PERSIST=1
    fi
fi

if [ "$RUN_PERSIST" -eq 1 ]; then
    echo "[+] Persisting changes to USB drive... Please do not unplug the drive."
    case $CHOICE in
        1)
            echo "[+] Compressing Windows 11 image back to USB payloads (this may take a few minutes)..."
            tar -cJf "$PAYLOAD_DIR/win11.tar.xz" -C "$RAMDISK" win11.qcow2
            ;;
        2)
            echo "[+] Compressing Linux image back to USB payloads (this may take a few minutes)..."
            tar -cJf "$PAYLOAD_DIR/linux.tar.xz" -C "$RAMDISK" linux.img
            ;;
        3)
            echo "[+] Compressing macOS HDD image back to USB payloads (this may take several minutes)..."
            # Repackage all macOS components back — preserves OpenCore EFI and OVMF changes
            tar -cJf "$PAYLOAD_DIR/macos.tar.xz" \
                -C "$RAMDISK" \
                mac_hdd_ng.qcow2 \
                BaseSystem.img \
                opencore/ \
                ovmf/
            ;;
        4)
            if [ -f "$RAMDISK/temp_target.qcow2" ]; then
                echo "[+] Compressing Virtual Ventoy installation disk back to USB payloads..."
                tar -cJf "$PAYLOAD_DIR/ventoy_install.tar.xz" -C "$RAMDISK" temp_target.qcow2
            fi
            ;;
    esac
    echo "[+] Persist complete."
    sleep 2
fi

echo "[+] Cleaning up RAM disk..."
umount "$RAMDISK" || true
setterm -cursor on 2>/dev/null || true