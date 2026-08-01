# macOS VM Setup & Deployment Guide

This guide covers the complete workflow for deploying a macOS virtual machine on the xp-bootdisk system — from preparing the payload on a Linux machine to your first macOS desktop session.

The implementation is based on the [OSX-KVM project](https://github.com/kholia/OSX-KVM) by kholia.

> ⚠️ **Legal Note:** Running macOS on non-Apple hardware may violate Apple's EULA. This is intended for development and testing on Apple-licensed hardware or by licensed developers only.

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Supported macOS Versions](#supported-macos-versions)
3. [Host Requirements](#host-requirements)
4. [Boot Chain Diagram](#boot-chain-diagram)
5. [Step 1 — Prepare the Payload](#step-1--prepare-the-payload-run-once-on-linux)
6. [Step 2 — Copy Payload to USB](#step-2--copy-payload-to-usb)
7. [Step 3 — First Boot & macOS Installation](#step-3--first-boot--macos-installation)
8. [Step 4 — GPU Passthrough](#step-4--gpu-passthrough-recommended)
9. [Step 5 — Networking & Control Subnet](#step-5--networking--control-subnet)
10. [Step 6 — Post-Install Optimisation](#step-6--post-install-optimisation)
11. [Step 7 — Generating Real SMBIOS Serials](#step-7--generating-real-smbios-serials-optional)
12. [Persisting Changes Back to USB](#persisting-changes-back-to-usb)
13. [KVM Configuration Details](#kvm-configuration-details)
14. [Sequoia-Specific Notes](#sequoia-specific-notes)
15. [Troubleshooting](#troubleshooting)
16. [References](#references)

---

## How It Works

macOS requires special treatment compared to Windows/Linux guests because it performs deep hardware validation at boot.

| Requirement | Reason |
|-------------|--------|
| **OpenCore EFI bootloader** | Hardware abstraction layer that presents a valid Apple hardware identity to macOS |
| **Intel CPU vendor spoofing** (`vendor=GenuineIntel`) | macOS refuses to run on CPUs not identified as Intel |
| **`-cpu Haswell-noTSX`** | Haswell-level feature set with AVX2; required for Ventura, Sonoma, and Sequoia |
| **`isa-applesmc`** | Emulates the Apple System Management Controller; macOS panics without it |
| **`vmxnet3` NIC** | VMware paravirt NIC with best macOS driver compatibility |
| **`ignore_msrs=1`** | Suppresses KVM MSR access errors that cause macOS kernel panics |
| **Q35 machine** | Modern PCIe chipset required for macOS AHCI/SATA storage |
| **OVMF per-VM NVRAM copy** | `OpenCore.qcow2` is mounted read-only (`snapshot=on`); a writable copy of `OVMF_VARS-macos.fd` is made at each boot to persist UEFI/NVRAM state |

---

## Supported macOS Versions

| Version | CPU Model | Fetch Arg | Notes |
|---------|-----------|-----------|-------|
| Catalina (10.15) | `Penryn` | `catalina` | Oldest supported |
| Big Sur (11) | `Penryn` | `bigsur` | |
| Monterey (12) | `Penryn` or `Haswell-noTSX` | `monterey` | |
| Ventura (13) | `Haswell-noTSX` | `ventura` | AVX2 required |
| **Sonoma (14)** | `Haswell-noTSX` | `sonoma` | ✅ Recommended |
| **Sequoia (15)** | `Haswell-noTSX` | `sequoia` | Latest; see [Sequoia notes](#sequoia-specific-notes) |

---

## Host Requirements

| Component | Requirement |
|-----------|-------------|
| **CPU** | Intel or AMD with KVM + IOMMU enabled |
| **RAM** | 16 GB minimum (8 GB allocated to macOS guest + host overhead) |
| **GPU** | AMD RX 5000/6000/7000 series for passthrough; NVIDIA **not** supported on Sonoma+ |
| **USB** | USB 3.0+, 32 GB minimum for the xp-bootdisk drive |
| **macOS HDD space** | ~25 GB used after a clean install; 256 GB sparse disk created by default |

---

## Boot Chain Diagram

```
USB Drive (XP-BOOTDATA partition)
└── /payloads/macos.tar.xz
      │
      │  decompressed into RAM on boot
      ▼
/mnt/ramdisk/
├── mac_hdd_ng.qcow2        ← macOS main disk (read-write)
├── BaseSystem.img          ← recovery/installer (read-only)
├── opencore/OpenCore.qcow2 ← EFI bootloader (snapshot=on, read-only)
├── ovmf/OVMF_CODE.fd       ← UEFI firmware (read-only)
└── OVMF_VARS-macos-run.fd  ← writable NVRAM copy (per-session)
      │
      │  QEMU launches with Q35 + KVM + isa-applesmc + Haswell-noTSX
      ▼
OpenCore Boot Picker
├── [macOS Installer]       ← first boot: run the installer
├── [macOS]                 ← after install: boot normally
└── [Recovery]              ← for disk repair / reinstall
      │
      ▼
macOS (Sonoma / Sequoia)
├── LAN IP via br0 bridge   (native router DHCP)
├── Control IP: 192.168.254.2 → host at 192.168.254.1:8000
└── GPU via VFIO passthrough (AMD only)
```

---

## Step 1 — Prepare the Payload (Run Once, on Linux)

Run `fetch-macos-payload.sh` on **any Linux machine with internet access**. You do not need the xp-bootdisk USB connected for this step.

```bash
# Make the script executable
chmod +x fetch-macos-payload.sh

# Fetch macOS Sonoma (default):
./fetch-macos-payload.sh

# Or a specific version:
./fetch-macos-payload.sh ventura
./fetch-macos-payload.sh sequoia
```

### What the Script Does

| Step | Action |
|------|--------|
| 1 | Checks and installs prerequisites (`qemu-utils`, `dmg2img`, `python3`, `git`) |
| 2 | Clones `kholia/OSX-KVM` (shallow, for OpenCore EFI + OVMF firmware) |
| 3 | Runs `fetch-macOS-v2.py` to download `BaseSystem.dmg` from Apple's servers |
| 4 | Converts `BaseSystem.dmg` → `BaseSystem.img` using `dmg2img` |
| 5 | Creates a blank `256G` sparse QCOW2 disk (`mac_hdd_ng.qcow2`) |
| 6 | Copies `OpenCore.qcow2` and `OVMF_CODE.fd` / `OVMF_VARS.fd` from OSX-KVM |
| 7 | Sets `ignore_msrs=1` on the preparation host (harmless) |
| 8 | Packages everything into `macos.tar.xz` |

### Resulting Payload Structure

```
macos.tar.xz
├── mac_hdd_ng.qcow2          ← macOS HDD (sparse ~200 MB on disk initially)
├── BaseSystem.img            ← macOS recovery / installer media
├── opencore/
│   └── OpenCore.qcow2        ← OpenCore EFI bootloader (pre-built)
└── ovmf/
    ├── OVMF_CODE.fd          ← UEFI firmware (read-only at runtime)
    └── OVMF_VARS-macos.fd    ← NVRAM template (copied to a writable file at each boot)
```

> 💡 **Disk size:** `mac_hdd_ng.qcow2` is sparse — it only occupies actual used space. A 256G virtual disk uses roughly 200 MB before installation and ~25 GB after a full macOS install.

### Estimated Times

| Step | Duration |
|------|----------|
| Cloning OSX-KVM | ~1 minute |
| Downloading BaseSystem.dmg from Apple | 1–5 minutes (varies by connection) |
| DMG → IMG conversion | ~30 seconds |
| tar.xz packaging | 1–3 minutes |

---

## Step 2 — Copy Payload to USB

After `fetch-macos-payload.sh` completes, copy the archive to the USB data partition:

```bash
# Mount the XP-BOOTDATA partition (if not already mounted)
sudo mount /dev/sdX2 /media/usb   # replace sdX2 with your USB data partition

# Copy the payload
cp macos.tar.xz /media/usb/payloads/

# Verify it's there
ls -lh /media/usb/payloads/
# macos.tar.xz   ~2-3 GB
```

Your USB payloads directory should now look like:
```
/media/usb/payloads/
├── win11.tar.xz    (optional)
├── linux.tar.xz    (optional)
└── macos.tar.xz    ← newly added
```

---

## Step 3 — First Boot & macOS Installation

### 3a. Boot from the USB

1. Insert the xp-bootdisk USB into the target machine
2. Boot and select the USB drive in your BIOS/UEFI boot menu
3. The Yocto launcher will start automatically on `tty1`

### 3b. Select macOS in the Launcher

```
┌──────────────────────────────────────────────┐
│       HYPERVISOR BOOT MANAGER                │
│                                              │
│  1. Windows 11 LTSC (TPM 2.0 + UEFI)        │
│  2. Linux OS (Native Live Image)             │
│  3. macOS (OpenCore + VFIO GPU recommended)  │  ← select this
│  4. Boot ISO (Virtual Ventoy)                │
│  5. Exit to Shell                            │
└──────────────────────────────────────────────┘
```

### 3c. GPU Passthrough Prompt

```
Would you like to pass through a physical GPU (AMD/NVIDIA) to the guest VM?
  [Yes]  → AMD GPU bound via VFIO, macOS gets native metal acceleration
  [No]   → vmware SVGA software rendering (functional but slow)
```

> ⚠️ Only AMD GPUs (RX 5000/6000/7000, Vega, RX 580) are supported. See [Step 4](#step-4--gpu-passthrough-recommended) for details.

### 3d. Payload Decompression

The launcher will decompress `macos.tar.xz` into `/mnt/ramdisk/`. This takes **3–8 minutes** depending on RAM speed. You will see:

```
[+] Decompressing macOS payload into RAM disk...
[+] Preparing macOS OVMF NVRAM (writable copy)...
[+] Booting macOS in RAM via OpenCore...
```

### 3e. OpenCore Boot Picker

The OpenCore picker will appear. Use the arrow keys to navigate:

```
┌─────────────────────────────────────────────────┐
│                                                 │
│  [EFI Boot]  [Install macOS Sonoma]  [Recovery] │
│                                                 │
│  Press SPACE for options  |  ENTER to boot      │
└─────────────────────────────────────────────────┘
```

- **On first boot:** Select **`Install macOS Sonoma`** (or your version)
- **Verbose mode:** Press `Cmd+V` (or add `-v` to boot-args) to see kernel messages

### 3f. First Boot Install Checklist

Follow this sequence carefully — the installer reboots 2–3 times:

```
① macOS Installer loads
   └─ Open Disk Utility (top menu bar or Utilities menu)
      ├─ Select "mac_hdd_ng Media" in the sidebar
      ├─ Click Erase
      ├─ Name: "Macintosh HD"
      ├─ Format: APFS
      ├─ Scheme: GUID Partition Map
      └─ Click Erase, then Done

② Close Disk Utility → "Install macOS Sonoma"
   └─ Select "Macintosh HD" as the destination
   └─ Click Continue / Agree / Install

③ Installation begins (~20–30 minutes)
   └─ System reboots automatically → returns to OpenCore picker
      └─ Select "macOS Installer" (NOT "EFI Boot")

④ Installer continues (~10–15 more minutes)
   └─ System reboots again → OpenCore picker
      └─ Select "macOS" (the installed system — no longer labelled "Installer")

⑤ macOS Setup Assistant appears
   └─ Choose country, keyboard layout
   └─ Skip Apple ID sign-in for now (serial numbers are placeholders)
   └─ Create a local user account
   └─ macOS desktop loads ✓
```

> 💡 **If the picker shows the same options after reboot:** The installation is progressing normally. Always select the option that says "macOS" or "macOS Installer" — never "EFI Boot" during installation.

> ⚠️ **If you see a black screen after OpenCore:** The GPU passthrough display is active. Connect your monitor to the **passed-through GPU's** output port, not the motherboard video output.

---

## Step 4 — GPU Passthrough (Recommended)

macOS has excellent native Metal driver support for AMD GPUs. No additional drivers need to be installed.

### Supported GPUs

| GPU Series | macOS Support | Boot Arg Needed |
|------------|---------------|-----------------|
| AMD RX 7900 / 7800 / 7700 (Navi 31/32/33) | ✅ Full Metal | `agdpmod=pikera` |
| AMD RX 6900 / 6800 / 6700 / 6600 (Navi 21/22/23) | ✅ Full Metal | `agdpmod=pikera` |
| AMD RX 5700 / 5600 / 5500 (Navi 10/12/14) | ✅ Full Metal | `agdpmod=pikera` |
| AMD RX 580 / 570 / 480 (Polaris) | ✅ Full Metal | None |
| AMD Vega 56 / 64 / Vega VII | ✅ Full Metal | None |
| AMD Radeon Pro W6800 / W6600 | ✅ Full Metal | `agdpmod=pikera` |
| NVIDIA GTX 10xx and older | ❌ Dropped by Apple (High Sierra was last) | — |
| NVIDIA RTX (any) | ❌ Not supported | — |
| Intel Arc | ⚠️ Experimental | — |

### Adding `agdpmod=pikera` for Navi GPUs

If your GPU is an AMD Navi card (RX 5000/6000/7000 series), you need this boot argument to prevent a black screen at the macOS lock screen / after login.

**On a Linux machine, mount the OpenCore QCOW2:**

```bash
sudo modprobe nbd max_part=8
sudo qemu-nbd --connect=/dev/nbd0 /media/usb/payloads/opencore/OpenCore.qcow2
# or if already extracted: sudo qemu-nbd --connect=/dev/nbd0 opencore/OpenCore.qcow2
sudo mount /dev/nbd0p1 /mnt
```

**Edit the boot arguments in `config.plist`:**

```bash
sudo nano /mnt/EFI/OC/config.plist
```

Find the `boot-args` key and update the string:

```xml
<key>boot-args</key>
<string>agdpmod=pikera keepsyms=1</string>
```

Remove the `-v` verbose flag once you have confirmed the system boots correctly.

**Unmount:**

```bash
sudo umount /mnt
sudo qemu-nbd --disconnect /dev/nbd0
sudo rmmod nbd
```

> 💡 After editing `config.plist`, repackage `macos.tar.xz` so the change persists:
> ```bash
> cd /media/usb/payloads
> tar -cJf macos-new.tar.xz mac_hdd_ng.qcow2 BaseSystem.img opencore/ ovmf/
> mv macos-new.tar.xz macos.tar.xz
> ```

---

## Step 5 — Networking & Control Subnet

The macOS guest connects to your LAN via the host bridge (`br0`) — it gets a native router-assigned IP, not NAT.

### LAN Connectivity (Automatic)

No configuration needed. The `vmxnet3` NIC is presented to macOS and should auto-configure via DHCP. Verify in **System Settings → Network → Ethernet**.

### App Store / iCloud Note

macOS binds App Store and iCloud tokens to the primary network interface (`en0`). If your interface shows as `en1` or higher after initial setup:

1. Open **System Settings → Network**
2. Remove all listed network adapters
3. Shut down and reboot the VM — macOS will re-enumerate the `vmxnet3` NIC as `en0`

### Control Subnet Setup (Host ↔ Guest)

The host listens at `192.168.254.1` for the persist trigger. To reach it from macOS, add a secondary IP:

**System Settings → Network → (your Ethernet adapter) → Details → TCP/IP:**

| Field | Value |
|-------|-------|
| Configure IPv4 | Manually (add additional address) |
| IP Address | `192.168.254.2` |
| Subnet Mask | `255.255.255.0` |

> On **Ventura and later** (macOS 13+), the app is called **System Settings** (not System Preferences).
> On **Monterey and earlier**, it is **System Preferences → Network**.

**Test the connection:**

```bash
# From macOS Terminal
curl http://192.168.254.1:8000/
# Should respond: "xp-bootdisk persist server"

# Trigger a persist (will shut down the VM)
curl http://192.168.254.1:8000/persist
```

---

## Step 6 — Post-Install Optimisation

### Enable HiDPI / Retina Resolution

macOS defaults to a low resolution under vmware SVGA. To enable HiDPI:

```bash
# From macOS Terminal (one-time setup)
sudo defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES
```

Then log out and back in. In **System Settings → Displays**, scaled resolution options will appear.

For GPU passthrough, the GPU's native resolution and refresh rate are available automatically — no extra steps needed.

### Audio

The `ich9-intel-hda` + `hda-duplex` devices are included in the QEMU launch. macOS should detect the audio device automatically as "Intel HD Audio". If you hear no sound:

1. Open **System Settings → Sound**
2. Select **Output → Intel HD Audio** (or similar)
3. Adjust volume

For GPU passthrough with an AMD GPU, the GPU's HDMI/DisplayPort audio output is also passed through — macOS will see it as a separate audio device.

### Disable Verbose Boot (after confirming stability)

Once macOS boots reliably, edit `config.plist` (see [Step 4](#step-4--gpu-passthrough-recommended) for mount instructions) and remove `-v` from `boot-args`:

```xml
<key>boot-args</key>
<string>agdpmod=pikera keepsyms=1</string>
```

### Network Time Sync

macOS uses Apple's NTP servers. Ensure your host has working internet via `br0` so the guest can reach `time.apple.com`.

---

## Step 7 — Generating Real SMBIOS Serials (Optional)

The pre-built OpenCore EFI uses placeholder serial numbers. These work for running macOS but **will not work for App Store, iCloud, or Activation Lock**. To use those services, generate valid-format serials.

### Using GenSMBIOS

```bash
# Install GenSMBIOS
pip3 install corpnewt-gensmbios

# Run it
GenSMBIOS
```

1. Select **1** → Install/Update MacSerial
2. Select **3** → Generate SMBIOS data
3. Enter a model: `iMacPro1,1` (recommended for dGPU-only / GPU passthrough)
   - Or `MacPro7,1` for Sonoma/Sequoia with a Radeon Pro-class GPU
4. Copy the **SystemSerialNumber**, **Board Serial (MLB)**, and **SmUUID**

### Applying to config.plist

Mount `OpenCore.qcow2` (see [Step 4](#step-4--gpu-passthrough-recommended)) and edit:

```xml
<key>PlatformInfo</key>
<dict>
    <key>Generic</key>
    <dict>
        <key>SystemProductName</key>
        <string>iMacPro1,1</string>

        <key>SystemSerialNumber</key>
        <string>YOUR_SERIAL_HERE</string>

        <key>MLB</key>
        <string>YOUR_MLB_HERE</string>

        <key>SystemUUID</key>
        <string>YOUR-UUID-HERE</string>

        <key>ROM</key>
        <data>ESIzRFVm</data>
    </dict>
    ...
</dict>
```

> 🔑 **Keep serials private.** Never commit them to git or share them publicly. Each macOS installation should use a unique serial set.

---

## Persisting Changes Back to USB

### Option 1 — Shut Down Normally

Shut down macOS from the **Apple Menu → Shut Down**. The xp-bootdisk launcher will ask:

```
Would you like to compress and persist changes back to the USB drive?
  [Yes] / [No]
```

Select **Yes** — the launcher repackages the entire macOS payload:

```bash
tar -cJf /media/usb/payloads/macos.tar.xz \
    -C /mnt/ramdisk \
    mac_hdd_ng.qcow2 \
    BaseSystem.img \
    opencore/ \
    ovmf/
```

This preserves:
- All installed apps and data on `mac_hdd_ng.qcow2`
- Any changes to OpenCore EFI (if OpenCore snapshot is disabled)
- OVMF NVRAM changes (boot order, secure boot state)

### Option 2 — Remote Persist Trigger

From inside macOS, open **Terminal** and run:

```bash
curl http://192.168.254.1:8000/persist
```

Or open **Safari** and navigate to `http://192.168.254.1:8000/persist`.

The host daemon will:
1. Send `system_powerdown` via the QEMU monitor socket → graceful macOS shutdown
2. Wait for QEMU to exit
3. Repackage the RAM disk back to `macos.tar.xz` on the USB
4. Power off the physical host

> ⏱️ Repacking a macOS disk after a full installation takes **10–20 minutes** depending on how much data was written and the compression ratio. Do not unplug the USB during this time.

---

## KVM Configuration Details

The Yocto host image installs `/etc/modprobe.d/kvm-macos.conf` automatically:

```ini
options kvm ignore_msrs=1
options kvm report_ignored_msrs=0
```

The launcher also enforces this at runtime:

```bash
echo 1 > /sys/module/kvm/parameters/ignore_msrs
```

**Why this is critical:** macOS reads Apple-specific Model Specific Registers (MSRs) during boot. KVM does not implement these registers and would normally inject a `#GP` fault, causing a kernel panic. `ignore_msrs=1` tells KVM to silently return `0` for unknown MSRs instead.

`report_ignored_msrs=0` suppresses the resulting kernel log spam (without it, the host kernel log fills with thousands of `kvm: ignored rdmsr` lines).

---

## Sequoia-Specific Notes

macOS 15 (Sequoia) introduced some changes relevant to KVM/QEMU:

| Area | Change | Action Required |
|------|---------|-----------------|
| **CPU Requirements** | Continues to require AVX2 | Use `Haswell-noTSX` (already set) |
| **SMBIOS** | `MacPro7,1` preferred over `iMacPro1,1` for Sequoia | Update `SystemProductName` if using newer services |
| **Gatekeeper** | Stricter notarisation checks | No action; this only affects app installation from internet |
| **iCloud** | Requires valid SMBIOS for activation | Generate real serials if you need iCloud |
| **AMD GPU** | Navi 3x (RX 7000 series) fully supported | Use `agdpmod=pikera` boot arg |
| **Boot-args** | `-no_compat_check` may be needed | Add to `boot-args` if Sequoia rejects your SMBIOS model |

```xml
<!-- Sequoia-compatible boot-args -->
<key>boot-args</key>
<string>agdpmod=pikera keepsyms=1 -no_compat_check</string>
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Kernel panic on boot | `ignore_msrs` not set | `cat /sys/module/kvm/parameters/ignore_msrs` — should be `1` |
| Black screen after login (with GPU) | Navi GPU needs `agdpmod=pikera` | Edit `config.plist` boot-args; see [Step 4](#step-4--gpu-passthrough-recommended) |
| Black screen (no GPU passthrough) | vmware SVGA not initialized | Try adding `-vga std` instead of `-vga vmware` temporarily |
| OpenCore picker doesn't appear | OVMF not loading from pflash | Check that `OVMF_CODE.fd` exists in `ovmf/` inside the extracted payload |
| "This Mac can't run macOS Sonoma" | SMBIOS model too old | Change `SystemProductName` to `iMacPro1,1` or `MacPro7,1` |
| Installer hangs at "About 1 minute remaining" | Normal — wait 10+ minutes | Installer is copying to APFS container |
| Disk not found in Disk Utility | Disk not formatted yet | Open Disk Utility → select `mac_hdd_ng` → Erase as APFS |
| No network in macOS | TAP/bridge not set up | Check `ip link show br0` and `ip link show tap0` on host |
| Network shows as `en1` not `en0` | Previous network config cached | Delete all interfaces in System Settings → Network, reboot |
| App Store won't sign in | Placeholder SMBIOS serials | Generate valid serials with GenSMBIOS; see [Step 7](#step-7--generating-real-smbios-serials-optional) |
| QEMU error: `isa-applesmc` unknown device | QEMU version too old | Ensure QEMU ≥ 7.0 is installed on the Yocto host |
| `vmxnet3` device not recognized in macOS | Driver not loaded | Boot with `-device e1000-82545em` as fallback (slower) |
| Persist takes very long | Large QCOW2 with lots of data | Normal — 256G sparse QCOW2 with 25GB installed data takes ~15 mins to compress |

---

## References

- [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) — Base project this implementation adapts
- [Dortania OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/) — Comprehensive OpenCore configuration reference
- [Dortania GPU Buyers Guide](https://dortania.github.io/GPU-Buyers-Guide/) — macOS-compatible GPU list
- [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) — SMBIOS serial number generator
- [OpenCore Releases](https://github.com/acidanthera/OpenCorePkg/releases) — Latest OpenCore builds (for manual updates to `OpenCore.qcow2`)
- [Lilu + WhateverGreen](https://github.com/acidanthera/WhateverGreen) — GPU patching kext documentation
