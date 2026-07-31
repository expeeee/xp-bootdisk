SUMMARY = "Seamless QEMU Dynamic GPU Passthrough & RAM-Boot Host Image"
DESCRIPTION = "A lightweight Yocto Linux live host image designed to extract OS payloads into RAM and boot them seamlessly via QEMU and VFIO passthrough."
LICENSE = "MIT"

IMAGE_FEATURES += "splash ssh-server-openssh"

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

inherit core-image
