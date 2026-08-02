# Yocto QEMU RAM Booter Documentation

This document covers the design, setup instructions, and architecture for the Yocto-based RAM Booter USB tool with dynamic GPU/VFIO passthrough capability.

---

## 1. System Architecture

The following diagram illustrates how the host system acts as a transparent, high-speed hypervisor loader:

```
+-------------------------------------------------------------------+
|                    GPT/UEFI USB Host Disk                         |
|                                                                   |
| +---------------------------------------------------------------+ |
| | Yocto Linux Host (Minimal Kernel + QEMU + KVM + Systemd)      | |
| +---------------------------------------------------------------+ |
| | Compressed Images Directory (/payloads):                       | |
| |   ├── linux.tar.xz                                            | |
| |   ├── win11.tar.xz                                            | |
| +---------------------------------------------------------------+ |
+-------------------------------------------------------------------+
                                 |
                                 v  (At Boot)
+-------------------------------------------------------------------+
| 1. Systemd starts custom launcher script on tty1                  |
| 2. Script queries user to choose OS via interactive dialog        |
| 3. User may select a non-primary AMD/NVIDIA GPU                   |
| 4. The complete isolated IOMMU group is bound to vfio-pci         |
| 5. tmpfs is mounted in RAM; guest payload decompresses into it    |
| 6. QEMU launches guest using host hardware acceleration (KVM/VFIO)|
+-------------------------------------------------------------------+
```

---

## 2. Dynamic GPU Binding and Hypervisor Stealth

To ensure near-native performance and bypass driver lockups or VM checks:
* **PCI Sub-function Isolation:** Devices like the NVIDIA RTX 3070 Ti feature multiple PCI sub-functions (graphics, audio, USB controller). The dynamic binding script scans and binds all functions under the slot simultaneously.
* **Hypervisor Concealment:** For NVIDIA cards, the KVM signature is hidden from the guest using `kvm=off` and `hv_vendor_id=null` flags in the QEMU `-cpu` arguments to avoid Code 43 driver failures.

---

## 3. Deployment & Build Guide

### Prerequisites
* A Linux build host (Ubuntu 22.04 LTS or newer) with at least 32 GB RAM, 8+ CPU cores, and 150 GB+ SSD space.
* Required packages on build host:
  ```bash
  sudo apt update && sudo apt install -y \
      gawk wget git diffstat unzip texinfo gcc build-essential \
      chrpath socat cpio python3 python3-pip python3-pexpect \
      xz-utils debianutils iputils-ping python3-git python3-jinja2 \
      python3-subunit zstd liblz4-tool file locale-gen libacl1
  ```

### Build Instructions
1. **Initialize Poky & meta-openembedded & meta-security:**
   ```bash
   git clone -b scarthgap git://git.yoctoproject.org/poky
   cd poky
   git clone -b scarthgap git://git.openembedded.org/meta-openembedded
   git clone -b scarthgap https://git.yoctoproject.org/meta-security
   ```
2. **Add Custom Layer:**
   Copy the `meta-ramboot` directory from your repository to your `poky` workspace (or place your repository in the parent folder).
3. **Initialize Build Environment:**
   ```bash
   source oe-init-build-env build
   ```
4. **Configure `conf/bblayers.conf`:**
   Add dependencies and `meta-ramboot` paths:
   ```bitbake
   BBLAYERS ?= " \
     ${TOPDIR}/../meta \
     ${TOPDIR}/../meta-poky \
     ${TOPDIR}/../meta-yocto-bsp \
     ${TOPDIR}/../meta-openembedded/meta-oe \
     ${TOPDIR}/../meta-openembedded/meta-python \
     ${TOPDIR}/../meta-security \
     ${TOPDIR}/../meta-security/meta-tpm \
     ${TOPDIR}/../yocto-qemu-ramboot/meta-ramboot \
     "
   ```
5. **Configure `conf/local.conf`:**
   Target x86-64, specify systemd init system, enable TPM features, and enable silent kernel boot + IOMMU:
   ```bitbake
   MACHINE = "qemux86-64"
   APPEND:append = " amd_iommu=on intel_iommu=on iommu=pt quiet loglevel=0 vt.global_cursor_default=0"
   DISTRO_FEATURES:append = " systemd usrmerge security tpm tpm2"
   VIRTUAL-RUNTIME_init_manager = "systemd"
   ```
6. **Compile the Image:**
   ```bash
   bitbake ramboot-image
   ```
7. **Write to USB:**
   Use the guarded deployer, which flashes the UEFI WIC and creates XP-BOOTDATA:
   ```bash
   sudo ./deploy.sh
   ```

### USB Payload Setup
`deploy.sh` appends an exFAT partition labeled `XP-BOOTDATA`. The booted host mounts it at `/media/usb` before starting the launcher:

*   **/media/usb/payloads/** — Place pre-built system archives here:
    *   `win11.tar.xz` (containing `win11.qcow2` to run Windows 11 LTSC)
    *   `linux.tar.xz` (containing `linux.img` to run Linux)
*   **/media/usb/isos/** — Place any standard bootable installer or live ISO images here (e.g., `ubuntu-24.04-desktop.iso`, `Windows11_Install.iso`). The loader will dynamically scan, display, and boot them in **Virtual Ventoy** mode (with optional temporary target disks in RAM).

---

## Transparent Bridged Networking Setup

The host OS automatically creates a bridge interface `br0` and binds the physical LAN interface (`en*` / `eth*`) to it. DHCP runs directly on `br0`, allowing the guest VM to receive a native LAN IP from the router DHCP server.

To communicate with the host's background daemon while maintaining transparent bridge access:
1. The host binds a secondary static IP of `192.168.254.1/24` to `br0`.
2. Inside your guest OS, assign a secondary/alias IP of `192.168.254.2` with subnet mask `255.255.255.0` to the network adapter.
   * **Windows Guest:** Open advanced IPv4 network adapter properties and add `192.168.254.2` to the list of IP addresses.
   * **Linux Guest:** Run `sudo ip addr add 192.168.254.2/24 dev eth0` (or setup netplan alias).
   * **macOS Guest:** Add an alias interface: `sudo ifconfig en0 alias 192.168.254.2 255.255.255.0`.

---

## VM Recapture and Auto-Persist Server

To persist any software changes or system configurations made inside your RAM-backed guest VM back to the USB drive:

### 1. Manual / Console Trigger
When you shut down the guest OS cleanly from the OS menu:
* The VM exits and returns control to the host console.
* The launcher displays a prompt: `Would you like to compress and persist changes back to the USB drive?`
* Selecting **Yes** will automatically package and overwrite the `.tar.xz` file on the USB.

### 2. Remote / Web Trigger
If you run the VM headlessly, or want to trigger the persist operation remotely:
1. Read `persist.token` from the root of `XP-BOOTDATA`.
2. Send `POST /persist` with `Authorization: Bearer TOKEN` to `192.168.254.1:8000`.
3. The host validates the token, schedules a state backup, and sends `system_powerdown` to the VM.
4. The guest OS flushes file writes and exits cleanly.
5. The host writes a temporary sparse-aware archive, atomically replaces the payload, and powers down only after persistence succeeds.
