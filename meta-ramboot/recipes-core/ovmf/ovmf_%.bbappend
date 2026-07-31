do_install:append:class-target() {
    install -d ${D}${datadir}/ovmf
    install -m 0644 ${WORKDIR}/ovmf/ovmf.code.fd ${D}${datadir}/ovmf/OVMF_CODE.fd
    install -m 0644 ${WORKDIR}/ovmf/ovmf.vars.fd ${D}${datadir}/ovmf/OVMF_VARS.fd
}

FILES:${PN} += "${datadir}/ovmf/*.fd"
