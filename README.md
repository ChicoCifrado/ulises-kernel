# Ulises Kernel

**Ulises Kernel** — Linux 7.1.3-based custom kernel, rebranded and tailored for **UlisesOS** (fork de SteamOS 3.8).

```
uname -a → Ulises hostname 1.0.0 ...
```

## Project Goal

Construir un sistema operativo completo desde el kernel hacia arriba, partiendo de Linux 7.1.3 y SteamOS 3.8 como base, con control absoluto sobre cada componente:

- Kernel personalizado con nuevas funcionalidades
- Sistema rebranded como UlisesOS
- Integración con herramientas de creación de contenido
- Despliegue en hardware real (Steam Deck y otros)

## Repository Structure

```
├── kernel/
│   ├── configs/         Archivos .config del kernel
│   └── patches/         Parches sobre Linux 7.1.3
├── system/
│   ├── etc/             Archivos de sistema rebranded (os-release, grub, etc.)
│   ├── grub/            Configuración GRUB con entradas UlisesOS
│   └── plymouth/        Tema de arranque UlisesOS
├── scripts/
│   ├── deploy-ulises.sh Script de despliegue a imagen SteamOS
│   └── ...
└── README.md
```

## Phases

| Phase | Status | Description |
|-------|--------|-------------|
| 1 | ✅ | Kernel rebrand: `"Ulises version"`, `UTS_SYSNAME="Ulises"` |
| 2 | 🚧 | System rebrand: os-release, GRUB, naming |
| 3 | ⏳ | Deploy and boot verification in QEMU |
| 4 | 📋 | Plymouth boot splash rebrand |
| 5 | 📋 | Initramfs customization |
| 6 | 📋 | QEMU guest optimization (virtio-gpu, input, net, sound) |
| 7 | 📋 | Steam Deck hardware testing |
| 8 | 📋 | Content creation tools meta-package |

## Quick Start

### Prerequisites

- Linux 7.1.3 source tree at `/mnt/d/Hermes/linux-kernel/linux-7.1.3/`
- SteamOS recovery image at `/mnt/d/Hermes/steamos/steamdeck-oobe-repair-*.img`
- QEMU, OVMF, btrfs-tools

### Build kernel

```bash
cd /mnt/d/Hermes/linux-kernel/linux-7.1.3
make -j$(nproc)
```

### Deploy to image

```bash
sudo /mnt/d/Hermes/ulises-kernel/scripts/deploy-ulises.sh
```

### Boot in QEMU

```bash
sudo qemu-system-x86_64 -m 4G -machine q35 -smp 4 \
  -drive file=/mnt/d/Hermes/steamos/steamdeck-oobe-repair-20260618.10-3.8.10.img,format=raw,if=none,id=drive0 \
  -device virtio-blk-pci,drive=drive0 \
  -device virtio-gpu-pci -device qemu-xhci -device usb-tablet \
  -display gtk \
  -kernel /mnt/d/Hermes/linux-kernel/linux-7.1.3/arch/x86/boot/bzImage \
  -append "console=ttyS0,115200 root=/dev/vda3 rootfstype=btrfs audit=0 loglevel=7 tsc=reliable steamos.efi=PARTUUID=94718a8e-2d01-44b8-913e-c662479cde38" \
  -initrd /mnt/d/Hermes/steamos/root/boot/initramfs-linux-neptune-616.img \
  -bios /usr/share/ovmf/OVMF.fd \
  -serial mon:stdio
```

## Kernel Rebrand Changes

| File | Change |
|------|--------|
| `Makefile` | `VERSION=1`, `PATCHLEVEL=0`, `SUBLEVEL=0`, `NAME="Ulises Kernel"` |
| `init/version-timestamp.c` | Banner: `"Ulises version"` instead of `"Linux version"` |
| `include/linux/uts.h` | `UTS_SYSNAME` → `"Ulises"` (affects `uname -s`) |

## System Rebrand Changes

| File | Change |
|------|--------|
| `/etc/os-release` | `ID=ulises`, `NAME="UlisesOS"`, `VERSION_ID=1.0` |
| `/etc/lsb-release` | `DISTRIB_ID="UlisesOS"` |
| `/etc/issue` | Login prompt: `UlisesOS 1.0` |
| `/etc/default/grub` | `GRUB_DISTRIBUTOR="UlisesOS"` |
| `grub.cfg` | Menu entry: `"UlisesOS 1.0 (Ulises Kernel)"` |
| Kernel filename | `vmlinuz-linux-neptune-616` → `vmlinuz-ulises` |

## License

GPL-2.0 — basado en Linux Kernel 7.1.3, copyright de sus respectivos autores.
