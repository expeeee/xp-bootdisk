# XP-Bootdisk — Yocto QEMU RAM Booter

A custom Yocto Project layer (`meta-ramboot`) that builds a **GPT/UEFI USB boot disk**. It launches a minimal Linux host from the USB and extracts a selected guest disk into tmpfs before running it with QEMU/KVM.

> **No installation to the computer's internal disks.** The host root filesystem and the explicitly persisted guest payload are writable on the USB.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🧠 **RAM-backed guest disk** | The selected guest payload decompresses into `tmpfs`; the Yocto host itself runs from the USB |
| 🎮 **Guarded GPU Passthrough** | Detects non-primary AMD or NVIDIA GPUs and permits passthrough only when their complete IOMMU group is isolated |
| 🕶️ **Hypervisor Stealth** | Hides KVM signature from NVIDIA drivers (`kvm=off`, `hv_vendor_id=null`) to prevent Code 43 errors |
| 💻 **Windows 11 + Linux Support** | Boots prebuilt `.qcow2` or raw image guests stored as compressed tarballs on the USB data partition |
| 🍎 **macOS Support** | Boots macOS Sonoma/Sequoia via OpenCore EFI with Intel CPU spoofing, Apple SMC emulation, and optional AMD GPU passthrough |
| 📀 **Virtual Ventoy Mode** | Drop any bootable `.iso` onto `/media/usb/isos/` and select it from the interactive menu to boot via QEMU |
| 🌐 **Transparent Bridged Networking** | Guest VM gets a native LAN IP directly from your router; host bridge (`br0`) is fully transparent |
| 💾 **Remote Persist Trigger** | From inside the guest, hit `http://192.168.254.1:8000/persist` to compress and save changes back to the USB |
| 🔐 **TPM 2.0 Emulation** | Software TPM (`swtpm`) presented to the guest for Windows 11 compatibility and secure boot scenarios |
| 🧩 **Modular Yocto Layer** | All customizations live in `meta-ramboot` — easy to extend, add packages, or fork |

---

## 🖥️ Host Hardware Requirements

| Component | Requirement |
|-----------|-------------|
| **CPU** | x86-64 with KVM (`vmx`/`svm`) and IOMMU (`VT-d`/`AMD-Vi`) enabled in BIOS |
| **RAM** | 32 GB minimum for the host, decompressed guest disk, and guest memory together. 64 GB recommended for Windows 11 |
| **GPU** | Discrete AMD (RDNA2+) or NVIDIA (Pascal+) in its own IOMMU group |
| **USB Drive** | USB 3.0+, 32 GB minimum. USB 3.1 Gen 2 or NVMe in USB enclosure recommended |
| **Firmware** | UEFI firmware. Secure Boot must be **disabled** |
| **Network** | Ethernet NIC (Wi-Fi bridging not supported) |

> ℹ️ **IOMMU group isolation** is critical. If your GPU shares an IOMMU group with other devices (common on consumer B-series motherboards), ACS override patches or an X-series/HEDT platform may be needed.

---

## 🚀 Quick Start

Use the included `setup.sh` to handle the full environment setup automatically:

```bash
# 1. Clone Poky, then clone its dependency layers inside poky/
git clone -b scarthgap git://git.yoctoproject.org/poky
cd poky
git clone -b scarthgap git://git.openembedded.org/meta-openembedded
git clone -b scarthgap https://git.yoctoproject.org/meta-security

# 2. Clone this repository beside poky/ (setup.sh also supports repo/poky/)
cd ..
git clone https://github.com/expeeee/xp-bootdisk.git

# 3. Run the automated setup and build
cd xp-bootdisk
./setup.sh
```

`setup.sh` will:
- Locate Poky either beside or inside the repository
- Add and validate every required layer
- Install an idempotent production `local.conf` block
- Start `bitbake ramboot-image` automatically

---

## 📁 Repository Structure

```
xp-bootdisk/
├── meta-ramboot/                  # Custom Yocto layer
│   ├── conf/layer.conf
│   ├── postinst-intercepts/       # Custom intercepts for console-only image
│   ├── recipes-core/
│   │   ├── images/
│   │   │   └── ramboot-image.bb   # Main image recipe
│   │   ├── ovmf/
│   │   │   └── ovmf_%.bbappend    # UEFI firmware packaging
│   │   └── qemu-booter/
│   │       ├── qemu-booter.bb     # Boot helper package
│   │       └── files/
│   │           ├── qemu-booter.sh        # Interactive launcher
│   │           ├── bind-gpu.sh           # Dynamic VFIO GPU isolator
│   │           ├── persist-server.py     # Host HTTP persist daemon
│   │           ├── 25-bridge.netdev      # Bridge interface definition
│   │           ├── 25-bridge.network     # Bridge physical member config
│   │           ├── 25-bridge-dhcp.network # Bridge DHCP + static alias
│   │           ├── qemu-ifup             # TAP bridge attach hook
│   │           └── qemu-ifdown           # TAP bridge detach hook
│   └── recipes-kernel/
│       └── linux/
│           ├── linux-yocto_%.bbappend
│           └── files/vfio.cfg            # VFIO kernel config fragment
├── docs/
│   └── yocto-ram-booter.md        # Detailed architecture & config guide
├── setup.sh                       # One-command build bootstrapper
├── deploy.sh                      # Interactive USB flasher
└── README.md
```

---

## ⚙️ How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                        USB Drive                             │
│  Partition 1: Yocto OS Image (WIC/ISO, UEFI bootable)       │
│  Partition 2: exFAT Data (XP-BOOTDATA)                      │
│    ├── /payloads/win11.tar.xz   ← compressed QCOW2 image    │
│    ├── /payloads/linux.tar.xz   ← compressed raw image      │
│    └── /isos/ubuntu-24.04.iso   ← Virtual Ventoy ISO        │
└─────────────────────────────────────────────────────────────┘
                              │
                    Machine boots from USB
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Yocto Linux Host (USB root; guest disk in tmpfs)           │
│                                                              │
│  1. Systemd mounts XP-BOOTDATA at /media/usb                │
│  2. qemu-booter.sh starts on tty1                           │
│  3. User selects an OS/ISO and optional isolated GPU        │
│  4. Payload .tar.xz decompresses into /tmp/guest/ (RAM)     │
│  5. persist-server.py starts on 192.168.254.1:8000          │
│  6. QEMU launches with KVM + VFIO + TAP networking          │
└─────────────────────────────────────────────────────────────┘
                              │
                    Guest OS boots at native speed
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Guest OS (Windows 11 / Linux) — full hardware access       │
│  • Direct GPU via VFIO passthrough                          │
│  • Native LAN IP via bridged TAP interface                  │
│  • Software TPM 2.0 (swtpm)                                 │
│  • Access host persist server at 192.168.254.1:8000         │
└─────────────────────────────────────────────────────────────┘
```

---

## 🌐 Networking

The host creates a **transparent bridge** (`br0`) at boot using `systemd-networkd`:

- All physical Ethernet interfaces (`en*`, `eth*`) are enslaved to `br0`
- `br0` acquires an IP via DHCP from your router — the guest gets its own native LAN IP
- A **private control subnet** `192.168.254.0/24` is also assigned to `br0`:
  - Host listens at `192.168.254.1`
  - Guest should be configured with `192.168.254.2` as a secondary/alias IP

### Configuring the Guest Secondary IP

| Guest OS | Command |
|----------|---------|
| **Windows** | Network Adapter → IPv4 Properties → Advanced → Add `192.168.254.2 / 255.255.255.0` |
| **Linux** | `sudo ip addr add 192.168.254.2/24 dev eth0` |
| **macOS** | `sudo ifconfig en0 alias 192.168.254.2 255.255.255.0` |

---

## 💾 Persist Server — Saving Guest Changes

Changes made inside the guest VM live in RAM by default. To save them back to the USB key:

### Option 1 — Shut down the guest normally
When QEMU exits, the launcher prompts:
> `Would you like to compress and persist changes back to the USB drive? [y/N]`

Selecting `y` re-compresses the RAM disk back into `.tar.xz` and writes it to the USB.

### Option 2 — Remote web trigger (headless)
Read `persist.token` from the root of XP-BOOTDATA, then make an authenticated request:
```
curl -X POST -H "Authorization: Bearer TOKEN" http://192.168.254.1:8000/persist
```
This instructs the host daemon (`persist-server.py`) to:
1. Send an ACPI shutdown (`system_powerdown`) via the QEMU monitor socket
2. Wait for the guest to exit cleanly
3. Compress the RAM disk image back to the USB payload
4. Power off the physical host

Works from any browser, `curl`, or application inside the guest on any OS.

---

## 📀 Virtual Ventoy Mode — Booting ISOs

Drop any standard bootable `.iso` file onto the USB data partition:

```bash
# After deploy.sh, the partition is mounted at /media/usb on the host
cp ubuntu-24.04-desktop.iso /media/usb/isos/
cp Win11_23H2_x64.iso       /media/usb/isos/
```

At boot, the interactive menu will display all detected ISOs. Select one to boot it inside QEMU with optional temporary disk allocation in RAM for installation or testing.


---

## 🔌 USB Deployment

Use the included `deploy.sh` script to safely flash and prepare a USB drive:

```bash
./deploy.sh
```

The script will:
1. List all attached USB block devices (never shows internal drives)
2. Prompt for confirmation before any write
3. Flash `ramboot-image-qemux86-64.rootfs.wic` as a GPT/UEFI disk image
4. Format the remaining space as **exFAT** (label: `XP-BOOTDATA`)
5. Create `/payloads/` and `/isos/` directories on the data partition

> ⚠️ Double-check the target device path. `deploy.sh` includes safety filters but cannot prevent all user error.

### USB Payload Setup

After flashing, place your guest OS payloads on the `XP-BOOTDATA` partition:

```
/payloads/
├── win11.tar.xz     ← Windows 11 LTSC QCOW2 image
├── linux.tar.xz     ← Linux raw disk image
└── macos.tar.xz     ← macOS (OpenCore + OVMF + BaseSystem + HDD disk)
/isos/
├── ubuntu-24.04.iso
└── Win11_23H2.iso
```

To prepare the macOS payload, run:
```bash
./fetch-macos-payload.sh [sonoma|ventura|sequoia]
cp macos.tar.xz /media/usb/payloads/
```

See [`docs/macos-setup.md`](file:///x:/AI/devel/Yocto-bootdisk/docs/macos-setup.md) for full macOS setup instructions.

---

## ⚠️ Known Limitations

- **Secure Boot must be disabled** — the kernel is unsigned
- **IOMMU group isolation** — the GPU must be in its own IOMMU group. Shared groups (ACS issue) require BIOS/motherboard workarounds
- **Second GPU required for dynamic binding** — the launcher refuses to detach the firmware/host-console GPU
- **Wi-Fi bridging not supported** — the transparent bridge requires a wired Ethernet interface
- **Host root is not RAM-resident** — the guest disk is RAM-backed, while the Yocto root filesystem remains on USB
- **USB 3.0+ strongly recommended** — USB 2.0 drives will be too slow for decompressing payloads into RAM
- **No Wayland on host** — the host is a minimal console-only environment (by design)
- **macOS: AMD GPU only** — NVIDIA support was dropped by Apple after High Sierra; only AMD RX/Vega/Pro GPUs work natively in macOS Sonoma/Sequoia

---

## 🛠️ Development & Extension

To rebuild after changing layer recipes:

```bash
./setup.sh          # Re-runs bitbake ramboot-image
```

To add packages to the image, edit [`meta-ramboot/recipes-core/images/ramboot-image.bb`](file:///x:/AI/devel/Yocto-bootdisk/meta-ramboot/recipes-core/images/ramboot-image.bb) and add entries to `IMAGE_INSTALL`.

To change kernel config, edit [`meta-ramboot/recipes-kernel/linux/files/vfio.cfg`](file:///x:/AI/devel/Yocto-bootdisk/meta-ramboot/recipes-kernel/linux/files/vfio.cfg) and bump `PR` in the `.bbappend`.

For full architecture details, configuration options, and advanced scenarios, see [`docs/yocto-ram-booter.md`](file:///x:/AI/devel/Yocto-bootdisk/docs/yocto-ram-booter.md).

---

## 📄 License

This project and `meta-ramboot` layer are released under the MIT License. Yocto Project components retain their respective upstream licenses.
