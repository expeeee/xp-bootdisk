# Yocto QEMU RAM Booter Documentation

This document covers the design, setup instructions, and architecture for the Yocto-based RAM Booter USB tool with dynamic GPU/VFIO passthrough capability.

---

## 1. System Architecture

The following diagram illustrates how the host system acts as a transparent, high-speed hypervisor loader:

```
+-------------------------------------------------------------------+
|                        USB Drive / Live OS                        |
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
| 3. User is asked if they want to pass through a GPU (AMD/NVIDIA)  |
| 4. Selected GPU is isolated and bound dynamically to vfio-pci     |
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
   Flash the `.wic` file output to your target USB drive:
   ```bash
   sudo dd if=tmp/deploy/images/qemux86-64/ramboot-image-qemux86-64.wic of=/dev/sdX bs=4M status=progress
   ```

### USB Payload Setup
Create a second partition on the USB drive (or use an external USB drive) mounted at `/media/usb` with `/payloads` and `/isos` folders:

*   **/media/usb/payloads/** — Place pre-built system archives here:
    *   `win11.tar.xz` (containing `win11.qcow2` to run Windows 11 LTSC)
    *   `linux.tar.xz` (containing `linux.img` to run Linux)
*   **/media/usb/isos/** — Place any standard bootable installer or live ISO images here (e.g., `ubuntu-24.04-desktop.iso`, `Windows11_Install.iso`). The loader will dynamically scan, display, and boot them in **Virtual Ventoy** mode (with optional temporary target disks in RAM).
