"""Convert images to PPM (portable pixmap) for kernel compositor."""

import struct
import sys
from PIL import Image


def img_to_ppm(input_path, output_path, max_w=0, max_h=0, rgb565=False):
    img = Image.open(input_path).convert('RGBA')

    if max_w > 0 or max_h > 0:
        w, h = img.size
        if max_w > 0 and w > max_w:
            h = int(h * max_w / w)
            w = max_w
        if max_h > 0 and h > max_h:
            w = int(w * max_h / h)
            h = max_h
        img = img.resize((w, h), Image.LANCZOS)

    img = img.convert('RGB')
    w, h = img.size
    pixels = list(img.getdata())

    if rgb565:
        raw = bytearray()
        for r, g, b in pixels:
            rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            raw.extend(struct.pack('<H', rgb565))
        ext = '.rgb565'
    else:
        raw = bytearray()
        for r, g, b in pixels:
            raw.extend([r, g, b])
        ext = '.ppm'

    with open(output_path, 'wb') as f:
        f.write(f'P6\n{w} {h}\n255\n'.encode())
        f.write(raw)

    print(f"Generated {output_path}: {w}x{h}, {len(raw)}B pixels, "
          f"total {len(raw) + len(f'P6\\n{w} {h}\\n255\\n')}B")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.png/jpg> <output.ppm> [max_w] [max_h]")
        sys.exit(1)

    max_w = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    max_h = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    img_to_ppm(sys.argv[1], sys.argv[2], max_w, max_h)
