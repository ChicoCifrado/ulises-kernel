#!/bin/bash
# Deploy Ulises Kernel + UlisesOS rebrand to SteamOS image
# Run with sudo, from the ulises-kernel repo root

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="/mnt/d/Hermes/linux-kernel/linux-7.1.3"
IMG="/mnt/d/Hermes/steamos/steamdeck-oobe-repair-20260618.10-3.8.10.img"
ROOT_MNT="/mnt/d/Hermes/steamos/root"
EFI_MNT="/mnt/d/Hermes/steamos/p2"

echo "=== Step 1: Cleaning up stale loops ==="
for l in /dev/loop*; do
    losetup -d "$l" 2>/dev/null || true
done
btrfs device scan --forget 2>/dev/null || true

echo "=== Step 2: Mount image ==="
LOOP=$(losetup -P --show -f "$IMG")
echo "Loop device: $LOOP"
mount -t btrfs -o ro "${LOOP}p3" "$ROOT_MNT"
mount "${LOOP}p2" "$EFI_MNT"

echo "=== Step 3: Make rootfs writable ==="
btrfs property set "$ROOT_MNT" ro false
mount -o remount,rw "$ROOT_MNT"

echo "=== Step 4: Copy kernel ==="
cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$ROOT_MNT/boot/vmlinuz-ulises"

echo "=== Step 5: Rebrand system files ==="
cp "$REPO_DIR/system/etc/os-release" "$ROOT_MNT/etc/os-release"
cp "$REPO_DIR/system/etc/lsb-release" "$ROOT_MNT/etc/lsb-release"
cp "$REPO_DIR/system/etc/issue" "$ROOT_MNT/etc/issue"
cp "$REPO_DIR/system/etc/default/grub" "$ROOT_MNT/etc/default/grub"

echo "=== Step 6: Rebrand GRUB ==="
cp "$REPO_DIR/system/grub/grub.cfg" "$EFI_MNT/EFI/steamos/grub.cfg"

echo "=== Step 7: Done ==="
echo "LOOP=$LOOP"
echo "Run QEMU with:"
echo "  qemu-system-x86_64 -m 4G -machine q35 -smp 4 \\"
echo "    -drive file=$IMG,format=raw,if=none,id=drive0 \\"
echo "    -device virtio-blk-pci,drive=drive0 \\"
echo "    -device virtio-gpu-pci -device qemu-xhci -device usb-tablet \\"
echo "    -display gtk \\"
echo "    -kernel $KERNEL_DIR/arch/x86/boot/bzImage \\"
echo "    -append \"console=ttyS0,115200 root=/dev/vda3 rootfstype=btrfs audit=0 loglevel=7 tsc=reliable steamos.efi=PARTUUID=94718a8e-2d01-44b8-913e-c662479cde38\" \\"
echo "    -initrd $ROOT_MNT/boot/initramfs-linux-neptune-616.img \\"
echo "    -bios /usr/share/ovmf/OVMF.fd \\"
echo "    -serial mon:stdio"
