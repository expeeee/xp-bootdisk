# Yocto QEMU RAM Booter

This repository contains a custom Yocto Project layer (`meta-ramboot`) designed to build a live USB boot image. The image boots a minimal Linux host that runs entirely in RAM (`tmpfs`), scans for AMD or NVIDIA GPUs, isolates them for VFIO PCI passthrough, and launches a guest OS (Windows 11 or Linux) inside QEMU with native-like performance.

## Repository Structure

*   [meta-ramboot/](file:///x:/AI/devel/Yocto-bootdisk/meta-ramboot) — Custom Yocto layer housing custom images, systemd services, kernel config fragments, and GPU passthrough/RAM booting scripts.
*   [docs/yocto-ram-booter.md](file:///x:/AI/devel/Yocto-bootdisk/docs/yocto-ram-booter.md) — Comprehensive guide on system design, host requirements, and compilation/deployment commands.

## Build Setup

To set up and run the build on your Linux compilation server:

1.  **Clone Poky, meta-openembedded, and meta-security dependencies:**
    ```bash
    git clone -b scarthgap git://git.yoctoproject.org/poky
    cd poky
    git clone -b scarthgap git://git.openembedded.org/meta-openembedded
    git clone -b scarthgap https://git.yoctoproject.org/meta-security
    ```

2.  **Pull this repository (`yocto-qemu-ramboot`) into the poky folder:**
    ```bash
    git clone <your-repo-url>
    ```

3.  **Initialize the build environment:**
    ```bash
    source oe-init-build-env build
    ```

4.  **Add the layers to `conf/bblayers.conf`:**
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

5.  **Compile the image:**
    ```bash
    bitbake ramboot-image
    ```

Once flashed to a USB key, create the following folders on the data partition:
*   `/payloads/` — for prebuilt system tarballs (`win11.tar.xz`, `linux.tar.xz`).
*   `/isos/` — for raw bootable installer/live `.iso` files (Virtual Ventoy mode).

For detailed configuration steps, system requirements, and post-build USB installation guidelines, check the detailed documentation at [docs/yocto-ram-booter.md](file:///x:/AI/devel/Yocto-bootdisk/docs/yocto-ram-booter.md).
