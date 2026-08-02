#!/bin/bash
# Reproducible XP-Bootdisk Yocto environment setup and build.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$PROJECT_ROOT/poky" ]; then
    POKY_DIR="$PROJECT_ROOT/poky"
elif [ -d "$PROJECT_ROOT/../poky" ]; then
    POKY_DIR="$(cd "$PROJECT_ROOT/../poky" && pwd)"
else
    echo "[!] Poky was not found at $PROJECT_ROOT/poky or beside this repository."
    exit 1
fi

REQUIRED_LAYERS=(
    "$POKY_DIR/meta-openembedded/meta-oe"
    "$POKY_DIR/meta-openembedded/meta-python"
    "$POKY_DIR/meta-openembedded/meta-networking"
    "$POKY_DIR/meta-openembedded/meta-filesystems"
    "$POKY_DIR/meta-security"
    "$POKY_DIR/meta-security/meta-tpm"
    "$PROJECT_ROOT/meta-ramboot"
)

for layer in "${REQUIRED_LAYERS[@]}"; do
    if [ ! -d "$layer/conf" ]; then
        echo "[!] Required Yocto layer is missing: $layer"
        exit 1
    fi
done

cd "$POKY_DIR"
# oe-init-build-env intentionally changes the working directory to build/.
source oe-init-build-env build

for layer in "${REQUIRED_LAYERS[@]}"; do
    if [ "$layer" = "$PROJECT_ROOT/meta-ramboot" ]; then
        # Accept the legacy compatibility path when upgrading an existing tree;
        # adding the same layer through two paths creates duplicate collections.
        grep -Fq "meta-ramboot" conf/bblayers.conf && continue
    fi
    if ! grep -Fq -- "$layer" conf/bblayers.conf; then
        bitbake-layers add-layer "$layer"
    fi
done

if ! grep -Fq "# BEGIN XP-BOOTDISK" conf/local.conf; then
    printf '%s\n' \
        '' \
        '# BEGIN XP-BOOTDISK' \
        'MACHINE = "qemux86-64"' \
        'APPEND:append = " amd_iommu=on intel_iommu=on iommu=pt quiet loglevel=2 vt.global_cursor_default=0"' \
        'DISTRO_FEATURES:append = " systemd usrmerge security tpm tpm2"' \
        'VIRTUAL-RUNTIME_init_manager = "systemd"' \
        'EXTRA_IMAGE_FEATURES = ""' \
        '# END XP-BOOTDISK' \
        >> conf/local.conf
fi

echo "[+] Validating layer and recipe configuration..."
bitbake-layers show-layers
bitbake -p

if [ "${RAMBOOT_PARSE_ONLY:-0}" = "1" ]; then
    echo "[+] Parse-only validation completed."
    exit 0
fi

echo "[+] Building ramboot-image..."
bitbake ramboot-image
