#!/bin/bash
# xp-bootdisk Build Environment Setup Script
# Run this script to restore symlinks and initialize/run the Yocto build.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POKY_DIR="$PROJECT_ROOT/poky"
OLD_REPO_PATH="$POKY_DIR/yocto-qemu-ramboot"

echo "[+] Initializing xp-bootdisk setup..."

if [ ! -d "$POKY_DIR" ]; then
    echo "[!] Error: 'poky' directory not found. Please ensure you have cloned Poky."
    exit 1
fi

# Re-create compatibility symlink
if [ -e "$OLD_REPO_PATH" ] || [ -L "$OLD_REPO_PATH" ]; then
    rm -rf "$OLD_REPO_PATH"
fi
ln -sf "$PROJECT_ROOT" "$OLD_REPO_PATH"
echo "[+] Created compatibility symlink: $OLD_REPO_PATH -> $PROJECT_ROOT"

# Check if build environment is configured
cd "$POKY_DIR"
source oe-init-build-env build

echo "[+] Build environment initialized."
echo "[+] Starting ramboot-image compilation..."
bitbake ramboot-image
