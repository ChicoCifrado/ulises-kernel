"""Convert TTF/OTF to PSF v2 bitmap font for kernel framebuffer console."""

import struct
import sys
from PIL import Image, ImageDraw, ImageFont

def ttf_to_psf(ttf_path, psf_path, point_size=16, width=8, height=16,
               first_char=0x20, last_char=0x7f):
    font = ImageFont.truetype(ttf_path, point_size)

    num_glyphs = last_char - first_char + 1
    char_size = (width + 7) // 8 * height

    glyph_data = bytearray()
    unicode_table = []

    for cp in range(first_char, last_char + 1):
        img = Image.new('1', (width, height), 0)
        draw = ImageDraw.Draw(img)
        try:
            draw.text((0, 1), chr(cp), font=font, fill=1)
        except (ValueError, OSError):
            pass

        pixels = bytearray()
        for y in range(height):
            byte = 0
            for x in range(width):
                px = img.getpixel((x, y))
                if px:
                    byte |= 1 << (7 - x)
            pixels.append(byte)
        glyph_data.extend(pixels[:char_size].ljust(char_size, b'\x00'))

        unicode_table.append(cp)

    header = struct.pack(
        '<IIIIIIII',
        0x864ab572,
        0,
        32,
        0,
        num_glyphs,
        char_size,
        height,
        width,
    )

    with open(psf_path, 'wb') as f:
        f.write(header)
        f.write(glyph_data)

    print(f"Generated {psf_path}: {num_glyphs} glyphs, {char_size}B each, "
          f"total {len(header) + len(glyph_data)}B")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.ttf> <output.psf> [point_size]")
        sys.exit(1)

    point_size = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    ttf_to_psf(sys.argv[1], sys.argv[2], point_size)
