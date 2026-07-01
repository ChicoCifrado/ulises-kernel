#!/bin/bash
# Asset conversion pipeline for Ulises kernel GUI.
# Usage: ./tools/convert-assets.sh [source_dir]
#   source_dir: path to SteamOS root filesystem (optional, for SteamOS mode)
#
# To rebrand:
#   1. Place your assets in src/gfx/assets/:
#      - font.psf      (optional, will generate from DejaVuSans.ttf if present)
#      - wallpaper.ppm  (320x200 PPM recommended)
#      - cursor.ppm     (64x64 PPM)
#      - spinner.ppm    (64x64 PPM)
#   2. Edit src/gfx/rebrand.zig (colors, title, subtitle)
#   3. Run this script
#   4. Rebuild with: zig build -Dtarget=x86_64-freestanding

set -euo pipefail

ASSETS="src/gfx/assets"
TOOLS="tools"

echo "=== Ulises Kernel Asset Converter ==="

# Font
if [ -f "$ASSETS/DejaVuSans.ttf" ] && [ ! -f "$ASSETS/font.psf" ]; then
    echo "[font] Generating PSF from DejaVuSans.ttf..."
    python3 "$TOOLS/font2psf.py" "$ASSETS/DejaVuSans.ttf" "$ASSETS/font.psf"
elif [ -f "$ASSETS/font.psf" ]; then
    echo "[font] font.psf exists, skipping"
else
    echo "[font] WARNING: No font source found. Provide DejaVuSans.ttf or font.psf"
fi

# Wallpaper (resize to 320x200 for kernel)
if [ -f "$ASSETS/wallpaper.jpg" ] && [ ! -f "$ASSETS/wallpaper.ppm" ]; then
    echo "[wallpaper] Converting wallpaper.jpg -> wallpaper.ppm (320x200)..."
    python3 "$TOOLS/img2ppm.py" "$ASSETS/wallpaper.jpg" "$ASSETS/wallpaper.ppm" 320 200
elif [ -f "$ASSETS/wallpaper.ppm" ]; then
    echo "[wallpaper] wallpaper.ppm exists, skipping"
else
    echo "[wallpaper] WARNING: No wallpaper source found."
fi

# Cursor
if [ -f "$ASSETS/cursor.png" ] && [ ! -f "$ASSETS/cursor.ppm" ]; then
    echo "[cursor] Converting cursor.png -> cursor.ppm (64x64)..."
    python3 "$TOOLS/img2ppm.py" "$ASSETS/cursor.png" "$ASSETS/cursor.ppm" 64 64
elif [ -f "$ASSETS/cursor.ppm" ]; then
    echo "[cursor] cursor.ppm exists, skipping"
else
    echo "[cursor] WARNING: No cursor source found."
fi

# Spinner
if [ -f "$ASSETS/spinner.png" ] && [ ! -f "$ASSETS/spinner.ppm" ]; then
    echo "[spinner] Converting spinner.png -> spinner.ppm (64x64)..."
    python3 "$TOOLS/img2ppm.py" "$ASSETS/spinner.png" "$ASSETS/spinner.ppm" 64 64
elif [ -f "$ASSETS/spinner.ppm" ]; then
    echo "[spinner] spinner.ppm exists, skipping"
else
    echo "[spinner] WARNING: No spinner source found."
fi

echo "=== Done ==="
ls -lh "$ASSETS"/*.psf "$ASSETS"/*.ppm 2>/dev/null || true
