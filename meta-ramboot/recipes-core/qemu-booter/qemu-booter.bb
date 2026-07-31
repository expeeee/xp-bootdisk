SUMMARY = "QEMU Dynamic VFIO GPU Passthrough & RAM Boot Manager"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://qemu-booter.sh \
    file://bind-gpu.sh \
    file://qemu-booter.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "qemu-booter.service"
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
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/qemu-booter.sh ${D}${bindir}/qemu-booter
    install -m 0755 ${WORKDIR}/bind-gpu.sh ${D}${bindir}/bind-gpu

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/qemu-booter.service ${D}${systemd_system_unitdir}/
}
