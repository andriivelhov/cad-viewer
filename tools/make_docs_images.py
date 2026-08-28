#!/usr/bin/env python3
"""Builds the screenshots used in the README.

Screen capture needs a permission this environment does not have, so each shot
is composited from two sources the app can produce itself: the Metal scene via
--render, and the AppKit layer (toolbar, status line, measurement chip) via
--chromeshot. A window frame is drawn around the result.
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

# Use the build tree so the images always match the code being documented.
APP = "build/CADViewer.app/Contents/MacOS/CADViewer"
W, H = 2360, 1560           # the app window at 2x
TITLEBAR = 56               # drawn, since the real one is system chrome
RADIUS = 22


def run(args):
    subprocess.run([APP] + args, capture_output=True, text=True)


def shot(sample, extra, out, light=False):
    """Renders the scene and the chrome with identical state, then composites."""
    scene, chrome = "/tmp/_scene.png", "/tmp/_chrome.png"
    appearance = ["--appearance", "light" if light else "dark"]
    # Two runs: --chromeshot exits before --render would fire. The state is
    # deterministic, so both invocations produce the same view.
    run([sample] + extra + appearance + ["--render", scene])
    run([sample] + extra + appearance + ["--chromeshot", chrome])

    body = Image.open(scene).convert("RGBA").resize((W, H), Image.LANCZOS)
    body = Image.alpha_composite(body, Image.open(chrome).convert("RGBA"))

    frame = Image.new("RGBA", (W, H + TITLEBAR), (0, 0, 0, 0))
    bar_colour = (238, 238, 240, 255) if light else (54, 56, 62, 255)
    ImageDraw.Draw(frame).rectangle([0, 0, W, TITLEBAR + RADIUS], fill=bar_colour)
    frame.paste(body, (0, TITLEBAR), body)

    # Traffic lights, so it reads as a window rather than a bare render.
    d = ImageDraw.Draw(frame)
    for i, colour in enumerate([(255, 95, 87), (255, 189, 46), (40, 201, 64)]):
        cx = 40 + i * 40
        d.ellipse([cx - 11, TITLEBAR // 2 - 11, cx + 11, TITLEBAR // 2 + 11],
                  fill=colour)

    mask = Image.new("L", frame.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, frame.width - 1, frame.height - 1],
                                           radius=RADIUS, fill=255)
    frame.putalpha(mask)

    # A soft drop shadow on a neutral page, the way a README screenshot sits.
    pad = 60
    canvas = Image.new("RGBA", (frame.width + pad * 2, frame.height + pad * 2),
                       (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 110), (pad, pad + 16), mask)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(28)))
    canvas.paste(frame, (pad, pad), frame)
    canvas.resize((canvas.width // 2, canvas.height // 2), Image.LANCZOS).save(out)
    print("wrote", out)


def grid(samples, out, cell=520):
    """A row of thumbnails, as Finder would show them."""
    images = []
    for sample, label in samples:
        png = f"/tmp/_g_{os.path.basename(sample)}.png"
        run([sample, "--render", png])
        im = Image.open(png).convert("RGB")
        side = min(im.size)
        im = im.crop(((im.width - side) // 2, (im.height - side) // 2,
                      (im.width + side) // 2, (im.height + side) // 2))
        images.append((im.resize((cell, cell), Image.LANCZOS), label))

    gap = 26
    sheet = Image.new("RGB", (len(images) * cell + gap * (len(images) + 1),
                              cell + gap * 2 + 40), (247, 247, 249))
    d = ImageDraw.Draw(sheet)
    x = gap
    for im, label in images:
        rounded = Image.new("L", (cell, cell), 0)
        ImageDraw.Draw(rounded).rounded_rectangle([0, 0, cell - 1, cell - 1],
                                                  radius=18, fill=255)
        sheet.paste(im, (x, gap), rounded)
        d.text((x + cell // 2 - len(label) * 4, cell + gap + 10), label,
               fill=(90, 92, 98))
        x += cell + gap
    sheet.save(out)
    print("wrote", out)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs"
    os.makedirs(out, exist_ok=True)
    s = "samples/"

    shot(s + "column.step", [], f"{out}/hero.png")
    shot(s + "plate.step", ["--measure", "248", "412", "1186", "472"],
         f"{out}/measure.png")
    shot(s + "assembly.step", [], f"{out}/assembly.png")
    shot(s + "plate.step", [], f"{out}/light.png", light=True)
    grid([(s + "column.step", "STEP"), (s + "plate.iges", "IGES"),
          (s + "plate.stl", "STL"), (s + "plate.glb", "glTF")],
         f"{out}/formats.png")


if __name__ == "__main__":
    main()
