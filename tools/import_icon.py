#!/usr/bin/env python3
"""Turns artwork into a macOS .icns on Apple's icon grid.

Two source shapes are handled:
  full-bleed  square art; we apply the squircle ourselves
  baked       the art already contains a rounded shape on a background we crop

Apple's grid: a 1024 canvas with the rounded rect occupying 824 px and a
corner radius of ~22.5% of that. Matching it keeps the icon the same visual
size as every other icon in the Dock.
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
SHAPE = 824
RADIUS = int(SHAPE * 0.2237)


def squircle_mask(size, radius, ss=4):
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * ss - 1, size * ss - 1],
                                        radius=radius * ss, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def saturated_bbox(img, threshold=40):
    """Bounding box of colourful pixels, used to find art sitting on a neutral
    checkerboard or flat backdrop."""
    rgb = img.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    minx, miny, maxx, maxy = w, h, 0, 0
    step = max(1, w // 400)
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b = px[x, y]
            if max(r, g, b) - min(r, g, b) > threshold:
                minx = min(minx, x); maxx = max(maxx, x)
                miny = min(miny, y); maxy = max(maxy, y)
    if maxx <= minx:
        return (0, 0, w, h)
    return (minx, miny, maxx + 1, maxy + 1)


def build(source, mode):
    img = Image.open(source).convert("RGBA")

    if mode == "baked":
        box = saturated_bbox(img)
        side = max(box[2] - box[0], box[3] - box[1])
        cx = (box[0] + box[2]) // 2
        cy = (box[1] + box[3]) // 2
        half = side // 2
        img = img.crop((cx - half, cy - half, cx + half, cy + half))

    art = img.resize((SHAPE, SHAPE), Image.LANCZOS)
    art.putalpha(squircle_mask(SHAPE, RADIUS))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - SHAPE) // 2

    # A soft contact shadow, the way system icons sit on the desktop.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (offset, offset + 10), squircle_mask(SHAPE, RADIUS))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(12)))
    canvas.paste(art, (offset, offset), art)
    return canvas


def main():
    source, mode, out = sys.argv[1], sys.argv[2], sys.argv[3]
    master = build(source, mode)
    iconset = out + ".iconset"
    os.makedirs(iconset, exist_ok=True)
    for size, name in [(16, "icon_16x16"), (32, "icon_16x16@2x"),
                       (32, "icon_32x32"), (64, "icon_32x32@2x"),
                       (128, "icon_128x128"), (256, "icon_128x128@2x"),
                       (256, "icon_256x256"), (512, "icon_256x256@2x"),
                       (512, "icon_512x512"), (1024, "icon_512x512@2x")]:
        master.resize((size, size), Image.LANCZOS).save(
            os.path.join(iconset, name + ".png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out + ".icns"],
                   check=True)
    master.save(out + "_preview.png")
    print("wrote", out + ".icns")


if __name__ == "__main__":
    main()
