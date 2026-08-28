#!/usr/bin/env python3
"""Generates the app icon: an isometric part with a hole, drawn in the same
palette the viewer uses, with an amber measurement annotation across it."""
import math, os, subprocess, sys
from PIL import Image, ImageDraw

SS = 4  # supersample factor; PIL has no antialiased polygon fill
CANVAS = 1024


def iso(x, y, z, scale, ox, oy):
    """Isometric projection matching the viewer's default camera feel."""
    c = math.cos(math.radians(30)); s = math.sin(math.radians(30))
    return (ox + (x - y) * c * scale, oy + ((x + y) * s - z) * scale)


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    return mask


def draw_icon(size):
    n = size * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))

    # macOS icons sit in a squircle inset from the canvas edge.
    inset = int(n * 0.098)
    plate = n - inset * 2
    radius = int(plate * 0.2237)

    bg = Image.new("RGBA", (plate, plate))
    d = ImageDraw.Draw(bg)
    for row in range(plate):  # vertical gradient, viewport colours
        t = row / max(plate - 1, 1)
        d.line([(0, row), (plate, row)],
               fill=(int(46 + (22 - 46) * t), int(50 + (24 - 50) * t),
                     int(57 + (28 - 57) * t), 255))
    bg.putalpha(rounded_rect_mask(plate, radius))
    img.paste(bg, (inset, inset), bg)

    d = ImageDraw.Draw(img)
    scale = n / 190.0
    ox, oy = n * 0.5, n * 0.60
    W, D, H = 96, 62, 20          # the part
    def P(x, y, z): return iso(x - W / 2, y - D / 2, z, scale, ox, oy)

    top   = [P(0,0,H), P(W,0,H), P(W,D,H), P(0,D,H)]
    left  = [P(0,D,H), P(W,D,H), P(W,D,0), P(0,D,0)]
    right = [P(W,0,H), P(W,D,H), P(W,D,0), P(W,0,0)]

    edge = (18, 20, 24, 255)
    ew = max(int(2.0 * scale), 1)
    d.polygon(left,  fill=(126, 134, 148, 255), outline=edge, width=ew)
    d.polygon(right, fill=(154, 163, 178, 255), outline=edge, width=ew)
    d.polygon(top,   fill=(198, 206, 219, 255), outline=edge, width=ew)

    # A hole, drawn as the ellipse the isometric top face projects it to.
    cx, cy = P(W * 0.30, D * 0.5, H)
    rx = 15 * scale * math.cos(math.radians(30))
    ry = 15 * scale * math.sin(math.radians(30))
    d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry],
              fill=(96, 103, 116, 255), outline=edge, width=ew)

    # Amber measurement annotation, the app's accent.
    a = P(W * 0.58, D * 0.16, H)
    b = P(W * 0.94, D * 0.86, H)
    amber = (255, 148, 41, 255)
    d.line([a, b], fill=amber, width=max(int(2.6 * scale), 2))
    for pt in (a, b):
        r = 4.2 * scale
        d.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r], fill=amber)

    return img.resize((size, size), Image.LANCZOS)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "packaging"
    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size, name in [(16, "icon_16x16"), (32, "icon_16x16@2x"),
                       (32, "icon_32x32"), (64, "icon_32x32@2x"),
                       (128, "icon_128x128"), (256, "icon_128x128@2x"),
                       (256, "icon_256x256"), (512, "icon_256x256@2x"),
                       (512, "icon_512x512"), (1024, "icon_512x512@2x")]:
        draw_icon(size).save(os.path.join(iconset, name + ".png"))
    draw_icon(CANVAS).save(os.path.join(out, "AppIcon_preview.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset,
                    "-o", os.path.join(out, "AppIcon.icns")], check=True)
    print("wrote", os.path.join(out, "AppIcon.icns"))


if __name__ == "__main__":
    main()
