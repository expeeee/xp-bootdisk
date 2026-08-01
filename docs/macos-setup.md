# macOS VM Setup Guide

This guide explains how to prepare and run a macOS virtual machine on the xp-bootdisk system. The implementation is based on the [OSX-KVM project](https://github.com/kholia/OSX-KVM) by kholia.

> ⚠️ **Legal Note:** Running macOS on non-Apple hardware may violate Apple's EULA. This is intended for development and testing purposes only.

---

## How It Works

macOS requires special treatment compared to Windows/Linux guests:

| Requirement | Reason |
|-------------|--------|
| **OpenCore EFI bootloader** | Acts as a hardware abstraction layer that tricks macOS into believing it's running on real Apple hardware |
| **Intel CPU vendor spoofing** (`vendor=GenuineIntel`) | macOS refuses to run on AMD or non-Intel-identified CPUs |
| **`-cpu Haswell-noTSX`** | Haswell-level CPU feature set with AVX2, required for Ventura/Sonoma/Sequoia |
| **`isa-applesmc`** | Emulates the Apple System Management Controller — macOS panics without this |
| **`vmxnet3` NIC** | VMware paravirt NIC — best compatibility for macOS networking |
| **`ignore_msrs=1`** | Suppresses KVM MSR access errors that cause macOS kernel panics |
| **Q35 machine** | Required PCIe chipset for macOS AHCI/SATA storage access |

---

## Supported macOS Versions

| Version | CPU Model | Notes |
|---------|-----------|-------|
| Catalina (10.15) | `Penryn` | Oldest supported |
| Big Sur (11) | `Penryn` | |
| Monterey (12) | `Penryn` or `Haswell-noTSX` | |
| Ventura (13) | `Haswell-noTSX` | AVX2 required |
| **Sonoma (14)** | `Haswell-noTSX` | ✅ Recommended |
| **Sequoia (15)** | `Haswell-noTSX` | Latest, best GPU support |

---

## Step 1 — Prepare the Payload (Run Once)

On any Linux machine with internet access, run the included helper script:

```bash
# Clone or access the xp-bootdisk repository
cd /path/to/xp-bootdisk

# Make the script executable
chmod +x fetch-macos-payload.sh

# Fetch macOS Sonoma (default):
./fetch-macos-payload.sh

# Or specify a version:
./fetch-macos-payload.sh ventura
./fetch-macos-payload.sh sequoia
```

The script will:
1. Install required tools (`qemu-utils`, `dmg2img`, `python3`)
2. Clone OSX-KVM for OpenCore EFI + OVMF firmware
3. Download macOS recovery image from Apple's servers (`BaseSystem.dmg`)
4. Convert it to a raw image (`BaseSystem.img`)
5. Create a blank `256G` sparse QCOW2 disk (`mac_hdd_ng.qcow2`)
6. Package everything into `macos.tar.xz`

### Payload Structure (inside `macos.tar.xz`)
```
macos.tar.xz
├── mac_hdd_ng.qcow2          ← macOS installation disk (sparse, ~200MB on disk)
├── BaseSystem.img            ← macOS recovery/installer media
├── opencore/
│   └── OpenCore.qcow2        ← OpenCore EFI bootloader
└── ovmf/
    ├── OVMF_CODE.fd          ← UEFI firmware (read-only)
    └── OVMF_VARS-macos.fd    ← UEFI NVRAM template (writable copy at runtime)
```

### Copy to USB Drive
```bash
cp macos.tar.xz /media/usb/payloads/
```

---

## Step 2 — Boot and Install macOS

1. Boot your machine from the xp-bootdisk USB
2. Select **macOS (OpenCore + VFIO GPU recommended)** from the menu
3. Optionally select a GPU for passthrough (AMD RX 5000/6000/7000 series recommended)
4. The system decompresses the payload into RAM and launches QEMU
5. **OpenCore boot picker** will appear — select **Install macOS**
6. In the macOS installer:
   - Open **Disk Utility** first → Erase `mac_hdd_ng.qcow2` as APFS
   - Run the installer and point it at the freshly formatted disk
   - Installation will take ~30–45 minutes and reboot several times

> 💡 Each reboot returns to the OpenCore picker — always select the **macOS Installer** option until the installation completes and the macOS setup assistant appears.

---

## Step 3 — GPU Passthrough (Recommended)

macOS has excellent native driver support for AMD GPUs (RX 5000/6000/7000 series). NVIDIA support was dropped after High Sierra.

### Recommended GPUs for macOS
| GPU Series | macOS Support |
|------------|---------------|
| AMD RX 7000 (Navi 31/32/33) | ✅ Full (add `agdpmod=pikera` boot arg) |
| AMD RX 6000 (Navi 21/22/23) | ✅ Full (add `agdpmod=pikera` boot arg) |
| AMD RX 5000 (Navi 10) | ✅ Full (add `agdpmod=pikera` boot arg) |
| AMD RX 580 / Vega 56/64 | ✅ Full |
| NVIDIA (any) | ❌ Not supported on Sonoma/Sequoia |
| Intel Arc | ⚠️ Experimental |

### Adding `agdpmod=pikera` to OpenCore
For AMD Navi (RX 5000+) GPUs, you need this OpenCore boot argument to prevent a black screen:

1. Eject the USB data partition and mount `OpenCore.qcow2` on a Linux machine:
   ```bash
   sudo modprobe nbd
   sudo qemu-nbd --connect=/dev/nbd0 opencore/OpenCore.qcow2
   sudo mount /dev/nbd0p1 /mnt
   ```
2. Edit `/mnt/EFI/OC/config.plist`:
   ```xml
   <key>boot-args</key>
   <string>agdpmod=pikera -v keepsyms=1</string>
   ```
3. Unmount and disconnect:
   ```bash
   sudo umount /mnt
   sudo qemu-nbd --disconnect /dev/nbd0
   ```

---

## Step 4 — Networking

The host bridge (`br0`) connects the macOS guest to your LAN exactly like Windows/Linux guests. The guest will appear as a native device on your router.

### Control Subnet (Host ↔ Guest)
To use the persist trigger from macOS:

1. Open **System Preferences → Network**
2. Select your Ethernet adapter
3. Click **Advanced → TCP/IP**
4. Click **+** next to **IPv4 Addresses**
5. Add: `192.168.254.2`, Subnet: `255.255.255.0`
6. Apply and open Safari → `http://192.168.254.1:8000/persist`

### App Store / iCloud Note
macOS App Store requires the LAN interface to be registered as `en0`. If after setup it shows as `en1` or higher:
1. Go to **System Preferences → Network**
2. Remove all network interfaces
3. Reboot the VM — macOS will re-detect the `vmxnet3` NIC as `en0`

---

## Step 5 — Generating Real SMBIOS Serials (Optional)

The included OpenCore EFI uses placeholder serial numbers. For App Store / iCloud sign-in, generate real-format serials using `GenSMBIOS`:

```bash
pip3 install corpnewt-gensmbios
GenSMBIOS
```

Select `iMacPro1,1` (recommended for dGPU-only setups) or `MacPro7,1` for Sonoma+.

Replace the `SystemSerialNumber`, `MLB`, and `SystemUUID` in `/mnt/EFI/OC/config.plist → PlatformInfo → Generic`.

> 🔑 Never share your generated serials publicly — each set should be unique per "machine."

---

## Persisting macOS Changes

When you're done, shut down macOS from the Apple menu. The xp-bootdisk launcher will ask:
> `Would you like to compress and persist changes back to the USB drive?`

Select **Yes** — the launcher will repackage the entire macOS payload (HDD, OpenCore, OVMF NVRAM) back to `macos.tar.xz` on the USB key, preserving all installed apps, settings, and NVRAM changes.

### Remote Persist Trigger
From inside macOS, open Terminal or Safari and access:
```
http://192.168.254.1:8000/persist
```

This sends an ACPI shutdown to the VM and triggers the automatic persist + host poweroff flow.

---

## KVM Configuration

The Yocto host image automatically installs `/etc/modprobe.d/kvm-macos.conf`:
```
options kvm ignore_msrs=1
options kvm report_ignored_msrs=0
```

This is **critical** — without `ignore_msrs=1`, macOS will kernel panic during boot when it attempts to access Apple-specific MSRs that don't exist in KVM.

The launcher also sets this at runtime via:
```bash
echo 1 > /sys/module/kvm/parameters/ignore_msrs
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Kernel panic on boot | Check `ignore_msrs=1` is active: `cat /sys/module/kvm/parameters/ignore_msrs` |
| Black screen with GPU passthrough | Add `agdpmod=pikera` to OpenCore boot-args (AMD Navi GPUs) |
| macOS won't boot from OpenCore | Ensure `-cpu` has `vendor=GenuineIntel` and `+invtsc` |
| No network in macOS | Check `br0` is up and `tap0` is attached. Try `e1000-82545em` instead of `vmxnet3` |
| App Store won't sign in | Generate unique SMBIOS serials with GenSMBIOS |
| QEMU errors with `isa-applesmc` | Ensure QEMU version ≥ 7.0 — older versions lack the Apple SMC device |
| Disk not found in installer | In Disk Utility, erase `mac_hdd_ng.qcow2` as APFS before running the installer |

---

## References

- [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) — Base project this implementation adapts
- [OpenCore Documentation](https://dortania.github.io/OpenCore-Install-Guide/) — OpenCore config reference
- [Dortania GPU Buyers Guide](https://dortania.github.io/GPU-Buyers-Guide/) — Compatible GPU list for macOS
- [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) — SMBIOS serial generator
