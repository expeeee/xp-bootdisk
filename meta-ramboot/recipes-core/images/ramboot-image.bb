SUMMARY = "Seamless QEMU Dynamic GPU Passthrough & RAM-Boot Host Image"
DESCRIPTION = "A lightweight Yocto Linux live host image designed to extract OS payloads into RAM and boot them seamlessly via QEMU and VFIO passthrough."
LICENSE = "MIT"

# The host bridge is directly reachable from the LAN. Remote administration is
# intentionally opt-in; never ship development passwords in the production image.
IMAGE_FEATURES += "splash"
IMAGE_FEATURES:remove = "debug-tweaks ssh-server-openssh"
EXTRA_IMAGE_FEATURES:remove = "debug-tweaks"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    qemu-booter \
    qemu \
    qemu-system-x86-64 \
    kernel-modules \
    pciutils \
    util-linux \
    e2fsprogs \
    tar \
    xz \
    zstd \
    dialog \
    ovmf \
    swtpm \
    libtpm \
    exfatprogs \
    procps \
    bash \
"

IMAGE_FSTYPES = "wic wic.gz iso"
WKS_FILE = "ramboot-uefi.wks"
EFI_PROVIDER = "systemd-boot"
MACHINE_FEATURES:append = " efi"

inherit core-image
