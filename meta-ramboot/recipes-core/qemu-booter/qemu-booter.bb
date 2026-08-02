SUMMARY = "QEMU Dynamic VFIO GPU Passthrough & RAM Boot Manager"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://qemu-booter.sh \
    file://bind-gpu.sh \
    file://qemu-booter.service \
    file://media-usb.mount \
    file://25-bridge.netdev \
    file://25-bridge.network \
    file://25-bridge-dhcp.network \
    file://qemu-ifup \
    file://qemu-ifdown \
    file://persist-server.py \
    file://kvm-macos.conf \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "media-usb.mount qemu-booter.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    bash \
    tar \
    xz \
    zstd \
    qemu \
    qemu-system-x86-64 \
    dialog \
    pciutils \
    ovmf \
    swtpm \
    kmod \
    python3-core \
    python3-netserver \
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/qemu-booter.sh ${D}${bindir}/qemu-booter
    install -m 0755 ${WORKDIR}/bind-gpu.sh ${D}${bindir}/bind-gpu
    install -m 0755 ${WORKDIR}/persist-server.py ${D}${bindir}/persist-server

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/qemu-booter.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/media-usb.mount ${D}${systemd_system_unitdir}/

    install -d ${D}/media/usb

    # Install systemd-networkd configurations
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${WORKDIR}/25-bridge.netdev ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/25-bridge.network ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${WORKDIR}/25-bridge-dhcp.network ${D}${sysconfdir}/systemd/network/

    # Install QEMU TAP scripts
    install -d ${D}${sysconfdir}
    install -m 0755 ${WORKDIR}/qemu-ifup ${D}${sysconfdir}/qemu-ifup
    install -m 0755 ${WORKDIR}/qemu-ifdown ${D}${sysconfdir}/qemu-ifdown

    # Install KVM module config for macOS MSR compatibility
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/kvm-macos.conf ${D}${sysconfdir}/modprobe.d/kvm-macos.conf
}

FILES:${PN} += "/media/usb"
