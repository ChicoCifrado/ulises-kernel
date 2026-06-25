# Referencia GUI — SteamOS (Steam Deck)

Imagen analizada: `steamdeck-oobe-repair-20260618.10-3.8.10.img`
Sistema de archivos: **BTRFS** (superbloque en +0x10000)
Formato: GPT, 5 particiones (EFI + datos MS + root + var + home)

## Stack gráfico detectado

| Componente | Rol |
|---|---|
| **gamescope** | Compositor Wayland exclusivo para gaming. Valve. Corre directamente sobre DRM/KMS sin display manager |
| **KDE Plasma** | Entorno de escritorio en modo desktop |
| **Steam Big Picture** | UI principal en modo gaming. Basada en CEF (Chromium Embedded Framework) — HTML/CSS/JS |
| **Mesa 3D** | Drivers gráficos (radv, anv para Vulkan; zink para OpenGL sobre Vulkan) |
| **Vulkan** | API de renderizado principal. Shader compiler ACO (Valve) |
| **DRM/KMS** | Direct Rendering Manager + Kernel Mode Setting — acceso directo al hardware de display |
| **PipeWire** | Audio/routing |

## Arquitectura de renderizado

1. **Boot**: systemd-boot → kernel + initramfs → gamescope-session
2. **gamescope** se lanza como el primer proceso gráfico:
   - Abre DRM directamente (`/dev/dri/card0`)
   - Crea un framebuffer Vulkan
   - Corre como compositor Wayland
   - Gestiona la rotación de pantalla, escalado, TDP, tasa de refresco
3. **Steam** se lanza dentro de gamescope como cliente Wayland:
   - Renderiza con CEF (Chromium Embedded) sobre Vulkan
   - UI en HTML/CSS/JS
   - Overlays: MangoHud, Performance overlay

## Lecciones para el kernel Ulises

- **Display inicial**: Arrancar en modo texto VGA (ya implementado en `console.zig`) y ofrecer conmutación a framebuffer simple (simple framebuffer, efifb o vesafb)
- **Compositor futuro**: Implementar un mini-compositor Wayland o un simple DRM master que pinte directamente al framebuffer
- **UI del kernel**: La shell interactiva actual (`shell.zig`) es el equivalente a la UI textual de SteamOS. Para la GUI nativa del kernel, usar:
  - Framebuffer simple (mmap `/dev/fb0` o dirección VESA 0xE0000000)
  - Renderizado directo al framebuffer para menús, diagnóstico, wallet
  - Futuro: mini-compositor con soporte Vulkan (cuando tengamos drivers de GPU)
- **Inspiración CEF**: La UI del kernel puede renderizarse con un motor HTML/CSS liviano empotrado (ej. una mini biblioteca de layout + font rasterizer) o con bindings a una capa gráfica existente

## Archivos clave identificados

- `/usr/bin/gamescope` — Compositor Wayland de Valve
- Referencias a `plasma.systemloadviewer` — KDE System Load Viewer
- `/usr/share/wayland/` — Protocolos Wayland
- Sistema de archivos BTRFS con compresión zstd
