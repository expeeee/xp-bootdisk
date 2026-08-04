#!/bin/bash
# Seamless QEMU Payload Extractor & Launcher with Auto-Persist & Bridging

set -Eeo pipefail

# Hide terminal cursor
setterm -cursor off 2>/dev/null || true

PAYLOAD_DIR="/media/usb/payloads"
ISO_DIR="/media/usb/isos"
RAMDISK="/mnt/ramdisk"
SWTPM_DIR="$RAMDISK/state/swtpm"
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

SERVER_PID=""
SWTPM_PID=""
QEMU_STATUS=0
REMOTE_PERSIST=0

cleanup() {
    if [ -n "$SWTPM_PID" ]; then
        kill "$SWTPM_PID" 2>/dev/null || true
    fi
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    if mountpoint -q "$RAMDISK"; then
        umount "$RAMDISK" 2>/dev/null || true
    fi
    setterm -cursor on 2>/dev/null || true
}

persist_payload() {
    local destination="$1"
    shift
    local temporary="${destination}.tmp.$$"

    rm -f "$temporary"
    if tar --sparse -cJf "$temporary" -C "$RAMDISK" "$@"; then
        sync
        mv -f "$temporary" "$destination"
        sync
    else
        rm -f "$temporary"
        echo "[!] Persistence failed; the previous payload was left unchanged."
        return 1
    fi
}

# load_payload NAME DEST_FILENAME
#   Supports three payload formats, tried in order:
#     /payloads/NAME.tar.xz  — compressed archive  (extracted into ramdisk)
#     /payloads/NAME.qcow2   — bare QCOW2 image    (symlinked into ramdisk)
#     /payloads/NAME.img     — bare raw image       (symlinked into ramdisk)
#
#   After a successful call:
#     PAYLOAD_FILE   = full path of the image inside RAMDISK
#     PAYLOAD_FORMAT = "archive" | "qcow2" | "raw"
load_payload() {
    local name="$1"       # e.g. "win11"
    local dest="$2"       # e.g. "win11.qcow2"  (filename expected inside ramdisk)

    local archive="$PAYLOAD_DIR/${name}.tar.xz"
    local bare_qcow2="$PAYLOAD_DIR/${name}.qcow2"
    local bare_img="$PAYLOAD_DIR/${name}.img"

    if [ -f "$archive" ]; then
        echo "[+] Loading ${name} from compressed archive (.tar.xz)..."
        tar -xJf "$archive" -C "$RAMDISK"
        PAYLOAD_FORMAT="archive"
        PAYLOAD_FILE="$RAMDISK/${dest}"
    elif [ -f "$bare_qcow2" ]; then
        echo "[+] Loading ${name} from bare qcow2 image (no decompression needed)..."
        ln -sf "$bare_qcow2" "$RAMDISK/${dest}"
        PAYLOAD_FORMAT="qcow2"
        PAYLOAD_FILE="$RAMDISK/${dest}"
    elif [ -f "$bare_img" ]; then
        echo "[+] Loading ${name} from bare raw image (no decompression needed)..."
        ln -sf "$bare_img" "$RAMDISK/${dest}"
        PAYLOAD_FORMAT="raw"
        PAYLOAD_FILE="$RAMDISK/${dest}"
    else
        echo "[!] No payload found for '${name}'."
        echo "    Tried:"
        echo "      $archive"
        echo "      $bare_qcow2"
        echo "      $bare_img"
        return 1
    fi
}

trap cleanup EXIT INT TERM

if ! mountpoint -q /media/usb; then
    echo "[!] XP-BOOTDATA is not mounted at /media/usb."
    echo "    Check: systemctl status media-usb.mount"
    exit 1
fi

mkdir -p "$RAMDISK" "$ISO_DIR" "$PAYLOAD_DIR"

# Mount tmpfs using 80% of host RAM
if ! mountpoint -q "$RAMDISK"; then
    mount -t tmpfs -o size=80% tmpfs "$RAMDISK"
fi

# Clean up old trigger files & sockets
rm -f /tmp/auto_persist /tmp/qemu-monitor.sock

# The token is generated once on XP-BOOTDATA. Requests are accepted only on
# the private bridge address and require an Authorization: Bearer header.
TOKEN_FILE="/media/usb/persist.token"
if [ ! -s "$TOKEN_FILE" ]; then
    umask 077
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$TOKEN_FILE"
    sync
fi
PERSIST_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
export PERSIST_TOKEN
export PERSIST_BIND_ADDRESS="192.168.254.1"

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
    if source /usr/bin/bind-gpu; then
        if [ -n "$PASSTHROUGH_CMD_ARGS" ]; then
            GPU_PASSTHROUGH_ARGS="-nographic -display none $PASSTHROUGH_CMD_ARGS"
            CPU_EXTRA_FLAGS="$GPU_CPU_FLAGS"
        fi
    else
        dialog --title "GPU Passthrough Unavailable" --msgbox "The selected GPU could not be isolated safely. Continuing with a virtual display." 7 68
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
        # ── Windows 11 ──────────────────────────────────────────────────────────
        # Supports: win11.tar.xz (compressed) OR win11.qcow2 (bare image)
        PAYLOAD_FILE=""; PAYLOAD_FORMAT=""
        if ! load_payload "win11" "win11.qcow2"; then
            dialog --title "Payload Missing" --msgbox \
                "Windows 11 payload not found.\n\nPlace one of these on the USB XP-BOOTDATA partition:\n  /payloads/win11.tar.xz  (compressed archive)\n  /payloads/win11.qcow2   (bare QCOW2 image)" \
                10 65
            exit 1
        fi
        IMG="$PAYLOAD_FILE"

        echo "[+] Initializing software TPM 2.0 interface..."
        mkdir -p "$SWTPM_DIR"
        swtpm socket --tpmstate dir="$SWTPM_DIR" \
                     --ctrl type=unixio,path="$SWTPM_DIR/swtpm-sock" \
                     --tpm2 &
        SWTPM_PID=$!
        sleep 1

        echo "[+] Preparing UEFI storage..."
        if [ ! -f "$RAMDISK/OVMF_VARS.fd" ]; then
            cp "$OVMF_VARS_TEMPLATE" "$RAMDISK/OVMF_VARS.fd"
        fi

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
            $GPU_PASSTHROUGH_ARGS || QEMU_STATUS=$?

        kill $SWTPM_PID 2>/dev/null || true
        SWTPM_PID=""
        ;;

    2)
        # ── Linux ───────────────────────────────────────────────────────────────
        # Supports: linux.tar.xz (compressed) OR linux.qcow2 OR linux.img (bare)
        PAYLOAD_FILE=""; PAYLOAD_FORMAT=""
        if ! load_payload "linux" "linux.qcow2" 2>/dev/null && \
           ! load_payload "linux" "linux.img"; then
            dialog --title "Payload Missing" --msgbox \
                "Linux payload not found.\n\nPlace one of these on the USB XP-BOOTDATA partition:\n  /payloads/linux.tar.xz  (compressed archive)\n  /payloads/linux.qcow2   (bare QCOW2 image)\n  /payloads/linux.img     (bare raw image)" \
                11 65
            exit 1
        fi
        IMG="$PAYLOAD_FILE"

        # Auto-detect disk format
        if [ "$PAYLOAD_FORMAT" = "qcow2" ] || [[ "$IMG" == *.qcow2 ]]; then
            LINUX_FMT="qcow2"
        else
            LINUX_FMT="raw"
        fi

        # Build CPU arguments
        if [ -n "$CPU_EXTRA_FLAGS" ]; then
            CPU_ARGS="host,${CPU_EXTRA_FLAGS}"
        else
            CPU_ARGS="host"
        fi

        echo "[+] Booting Linux VM..."
        qemu-system-x86_64 \
            -enable-kvm -machine q35,accel=kvm \
            -m 16G -smp 8 \
            -cpu "$CPU_ARGS" \
            -drive file="$IMG",format="$LINUX_FMT",if=virtio,aio=io_uring \
            $NET_ARGS \
            $MONITOR_ARGS \
            $GPU_PASSTHROUGH_ARGS || QEMU_STATUS=$?
        ;;

    3)
        # ── macOS via OpenCore ─────────────────────────────────────────────────
        # Supports: macos.tar.xz (full archive)
        #       OR: mac_hdd_ng.qcow2 + BaseSystem.img + opencore/ + ovmf/ (bare)
        ARCHIVE="$PAYLOAD_DIR/macos.tar.xz"
        BARE_HDD="$PAYLOAD_DIR/mac_hdd_ng.qcow2"

        if [ -f "$ARCHIVE" ]; then
            echo "[+] Decompressing macOS payload into RAM disk..."
            tar -xJf "$ARCHIVE" -C "$RAMDISK"
        elif [ -f "$BARE_HDD" ]; then
            echo "[+] Loading macOS from bare components (no decompression needed)..."
            ln -sf "$BARE_HDD"                       "$RAMDISK/mac_hdd_ng.qcow2"
            [ -f "$PAYLOAD_DIR/BaseSystem.img" ]     && ln -sf "$PAYLOAD_DIR/BaseSystem.img" "$RAMDISK/BaseSystem.img"
            [ -d "$PAYLOAD_DIR/opencore" ]           && ln -sfn "$PAYLOAD_DIR/opencore"      "$RAMDISK/opencore"
            [ -d "$PAYLOAD_DIR/ovmf" ]               && ln -sfn "$PAYLOAD_DIR/ovmf"          "$RAMDISK/ovmf"
        else
            dialog --title "Payload Missing" --msgbox \
                "macOS payload not found.\n\nExpected one of:\n  /payloads/macos.tar.xz   (compressed archive)\n  /payloads/mac_hdd_ng.qcow2 + opencore/ + ovmf/ + BaseSystem.img\n\nRun ./fetch-macos-payload.sh to create it." \
                12 65
            exit 1
        fi

        # Ensure KVM MSR ignore is set (required for macOS)
        echo 1 > /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || true

        echo "[+] Using persistent macOS OVMF NVRAM..."
        test -f "$MACOS_OVMF_VARS_TEMPLATE"

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
            -drive if=pflash,format=raw,file="$MACOS_OVMF_VARS_TEMPLATE" \
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
            $MAC_GPU_ARGS || QEMU_STATUS=$?
        ;;

    4)
        # ── Virtual Ventoy (ISO boot) ────────────────────────────────────────
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

        # Build CPU arguments
        if [ -n "$CPU_EXTRA_FLAGS" ]; then
            CPU_ARGS="host,${CPU_EXTRA_FLAGS}"
        else
            CPU_ARGS="host"
        fi

        echo "[+] Preparing UEFI storage..."
        if [ ! -f "$RAMDISK/OVMF_VARS.fd" ]; then
            cp "$OVMF_VARS_TEMPLATE" "$RAMDISK/OVMF_VARS.fd"
        fi

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
            $GPU_PASSTHROUGH_ARGS || QEMU_STATUS=$?
        ;;
esac

if [ "$QEMU_STATUS" -ne 0 ]; then
    echo "[!] QEMU exited with status $QEMU_STATUS. Cleanup will still run."
fi

# Kill HTTP server daemon
if [ -n "$SERVER_PID" ]; then
    kill $SERVER_PID 2>/dev/null || true
fi

# Determine whether to save changes
RUN_PERSIST=0
if [ -f "/tmp/auto_persist" ]; then
    REMOTE_PERSIST=1
    RUN_PERSIST=1
    rm -f "/tmp/auto_persist"
    echo "[+] Auto-persist triggered by guest VM."
else
    clear
    if dialog --backtitle "PERSIST CHANGES" --yesno "Would you like to compress and persist changes back to the USB drive?" 7 60; then
        RUN_PERSIST=1
    fi
fi

if [ "$RUN_PERSIST" -eq 1 ]; then
    echo "[+] Persisting changes to USB drive... Please do not unplug the drive."
    case $CHOICE in
        1)
            if [ "${PAYLOAD_FORMAT:-archive}" = "archive" ]; then
                echo "[+] Compressing Windows 11 image back to USB payloads..."
                persist_payload "$PAYLOAD_DIR/win11.tar.xz" win11.qcow2 OVMF_VARS.fd state/swtpm
            else
                echo "[+] Bare qcow2 in use — writes went directly to USB, no re-compress needed."
            fi
            ;;
        2)
            if [ "${PAYLOAD_FORMAT:-archive}" = "archive" ]; then
                echo "[+] Compressing Linux image back to USB payloads..."
                if [ -f "$RAMDISK/linux.qcow2" ]; then
                    persist_payload "$PAYLOAD_DIR/linux.tar.xz" linux.qcow2
                else
                    persist_payload "$PAYLOAD_DIR/linux.tar.xz" linux.img
                fi
            else
                echo "[+] Bare image in use — writes went directly to USB, no re-compress needed."
            fi
            ;;
        3)
            # Only repack if files are real ramdisk copies, not symlinks to USB
            if [ -f "$RAMDISK/mac_hdd_ng.qcow2" ] && [ ! -L "$RAMDISK/mac_hdd_ng.qcow2" ]; then
                echo "[+] Compressing macOS HDD image back to USB payloads (this may take several minutes)..."
                persist_payload "$PAYLOAD_DIR/macos.tar.xz" \
                    mac_hdd_ng.qcow2 BaseSystem.img opencore/ ovmf/
            else
                echo "[+] Bare components in use — writes went directly to USB, no re-compress needed."
            fi
            ;;
        4)
            if [ -f "$RAMDISK/temp_target.qcow2" ]; then
                echo "[+] Compressing Virtual Ventoy installation disk back to USB payloads..."
                persist_payload "$PAYLOAD_DIR/ventoy_install.tar.xz" temp_target.qcow2
            fi
            ;;
    esac
    echo "[+] Persist complete."
    sleep 2
fi

echo "[+] Cleaning up RAM disk..."
umount "$RAMDISK" || true
trap - EXIT INT TERM
setterm -cursor on 2>/dev/null || true

if [ "$REMOTE_PERSIST" -eq 1 ]; then
    echo "[+] Remote persistence completed; powering off the host."
    sync
    systemctl poweroff
fi
