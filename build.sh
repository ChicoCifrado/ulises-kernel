#!/bin/bash
set -euo pipefail
cd /mnt/d/Hermes/linux-kernel

SRC="linux-7.1"
ARCH_CONFIG="arch.config"

if [ ! -d "$SRC/scripts" ]; then
    echo "[*] Source not extracted. Downloading snapshot..."
    curl -L --progress-bar \
        "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-7.1.tar.gz" \
        -o linux-7.1.tar.gz
    echo "[*] Extracting (this may take a few minutes)..."
    tar xzf linux-7.1.tar.gz
    rm -f linux-7.1.tar.gz
fi

if [ ! -f "$SRC/scripts/Kbuild.include" ]; then
    echo "ERROR: Extraction incomplete or failed"
    exit 1
fi

echo "[*] Setting up kernel config..."
cp "$K_CONFIG" "$SRC/.config" 2>/dev/null || true

cd "$SRC"
make olddefconfig
rm -f ../build.log

echo "[*] Building kernel (logs: ../build.log)..."
make -j$(nproc) 2>&1 | tee ../build.log

echo "[*] Building modules..."
make modules_install INSTALL_MOD_PATH=/mnt/d/Hermes/linux-kernel/modules 2>&1 | tee -a ../build.log

echo "[*] Done! Kernel at: $SRC/arch/x86/boot/bzImage"
ls -lh arch/x86/boot/bzImage