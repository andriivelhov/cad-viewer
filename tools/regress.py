#!/usr/bin/env python3
"""Regression checks for CAD Viewer.

Every assertion here is anchored to geometry whose true value is known from the
sample models, not to whatever the build happened to print last. Run from the
repository root after a build:

    python3 tools/regress.py [path/to/CADViewer.app]

Written in Python rather than shell because the checks pass coordinate pairs as
separate arguments, and shells disagree about splitting them.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "CADViewer.app")
BIN = os.path.join(APP, "Contents", "MacOS", "CADViewer")
DOMAIN = "dev.cadviewer.app"
SAMPLES = os.path.join(ROOT, "samples")

failures = []
checks = 0


def run(*args):
    proc = subprocess.run([BIN] + list(args), capture_output=True, text=True, timeout=180)
    return proc.stdout.strip(), proc.stderr, proc.returncode


def check(name, got, want):
    global checks
    checks += 1
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}\n          want: {want}\n          got:  {got}")
        failures.append(name)


def defaults_set(key, value):
    subprocess.run(["defaults", "write", DOMAIN, key, "-int", str(value)], check=True)


def defaults_clear(*keys):
    for key in keys:
        subprocess.run(["defaults", "delete", DOMAIN, key],
                       capture_output=True)


def sample(name):
    return os.path.join(SAMPLES, name)


print("Loading: every supported format opens and frames without clipping")
for name in sorted(os.listdir(SAMPLES)):
    out, _, rc = run(sample(name), "--cliptest")
    check(f"{name} loads and frames",
          (rc, out.split(";")[0]), (0, "0 clipping failures"))

print("\nClean stdout: OCCT chatter must not reach the parseable stream")
for name in ("plate.glb", "plate.stl", "plate.iges", "plate.obj"):
    out, _, _ = run(sample(name), "--cliptest")
    check(f"{name} stdout free of reader chatter and ANSI escapes",
          bool(re.search(r"\x1b\[|Mesh |Total number", out)), False)

print("\nExact geometry: values come from the B-rep, not the display mesh")
GEOMETRY = [
    ("plate.step", (700, 500), "face 2    plane    area 5788.7279 mm²"),
    ("plate.step", (700, 620), "edge 5    line    length 100.0000 mm"),
    ("column.step", (700, 500),
     "face 3    cylinder    area 2440.0593 mm²    ⌀ 28.0000 mm  (r 14.0000)"),
    ("column.step", (660, 460),
     "face 1    cylinder    area 72083.4026 mm²    ⌀ 40.0000 mm  (r 20.0000)"),
]
for name, (x, y), want in GEOMETRY:
    out, _, _ = run(sample(name), "--pick", str(x), str(y))
    check(f"{name} at {x},{y}", out, want)

print("\nSame solid, eight formats: the top face survives every importer")
# The mesh formats carry no B-rep, so they report the tessellation, not a plane;
# what must hold is that all of them agree on the model being there and framed.
for name in ("plate.step", "plate.iges", "plate.brep"):
    out, _, _ = run(sample(name), "--pick", "700", "500")
    check(f"{name} top face area", out.split("area")[-1].strip(), "5788.7279 mm²")

print("\nUnits: the same edge, reported four ways")
UNITS = {0: "100.0000 mm", 1: "10.00000 cm", 2: "0.1000000 m", 3: "3.93701 in"}
for style, want in UNITS.items():
    defaults_set("UnitStyle", style)
    out, _, _ = run(sample("plate.step"), "--pick", "700", "620")
    check(f"unit style {style}", out.split("length")[-1].strip(), want)
defaults_clear("UnitStyle")

print("\nDetail: quality changes the mesh but never the measurement")
measurements = set()
for quality in (0, 1, 2):
    defaults_set("TessellationQuality", quality)
    out, _, _ = run(sample("column.step"), "--pick", "700", "500")
    measurements.add(out.split("⌀")[-1].strip())
defaults_clear("TessellationQuality")
check("diameter identical at coarse, normal and fine detail",
      measurements, {"28.0000 mm  (r 14.0000)"})

print("\nRendering: every shading mode and background produces a real image")
scratch = os.environ.get("TMPDIR", "/tmp")
for mode in (0, 1, 2):
    defaults_set("ShadingMode", mode)
    png = os.path.join(scratch, f"regress_shading{mode}.png")
    out, err, rc = run(sample("plate.step"), "--render", png)
    ok = rc == 0 and os.path.exists(png) and os.path.getsize(png) > 5000
    check(f"shading mode {mode} renders", ok, True)
defaults_clear("ShadingMode")

for style in range(4):
    png = os.path.join(scratch, f"regress_bg{style}.png")
    out, err, rc = run(sample("plate.step"), "--background", str(style), "--render", png)
    check(f"background {style} renders", rc == 0 and os.path.getsize(png) > 5000, True)

print("\nAnti-aliasing: every level renders and picks, supported or not")
# 8x is unsupported on Apple silicon and 99 is nonsense; both must fall back
# rather than trip Metal's validation assertion, which takes the process down.
for aa in (1, 2, 4, 8, 99):
    defaults_set("AntialiasingSamples", aa)
    png = os.path.join(scratch, f"regress_aa{aa}.png")
    _, _, rc = run(sample("plate.step"), "--render", png)
    edge, _, _ = run(sample("plate.step"), "--pick", "700", "620")
    check(f"AA {aa} renders and picks",
          (rc, os.path.getsize(png) > 5000, edge),
          (0, True, "edge 5    line    length 100.0000 mm"))
defaults_clear("AntialiasingSamples")

print("\nChrome: overlay controls contrast with whatever background is behind")
try:
    from PIL import Image
except ImportError:
    print("  skip  (needs Pillow)")
else:
    # The background is chosen independently of the system theme, so the
    # floating controls must take their contrast from the rendered ground. What
    # matters is the direction: lighter chrome on a dark ground, darker chrome
    # on a light one. Magnitude is not the test - the controls cover only part
    # of the strip being averaged.
    def mean_luma(image, box):
        crop = image.convert("L").crop(box)
        return sum(crop.getdata()) / (crop.width * crop.height)

    for style in range(1, 6):
        base = os.path.join(scratch, f"regress_ground{style}.png")
        over = os.path.join(scratch, f"regress_chrome{style}.png")
        run(sample("plate.step"), "--background", str(style), "--render", base)
        run(sample("plate.step"), "--background", str(style), "--chromeshot", over)
        ground = Image.open(base).convert("RGBA")
        chrome = Image.open(over).convert("RGBA").resize(ground.size)
        merged = Image.alpha_composite(ground, chrome)

        box = (0, 0, 700, 90)  # the toolbar strip, top-left in both images
        bare = mean_luma(ground, box)
        with_chrome = mean_luma(merged, box)
        ground_is_light = bare > 127
        contrasts = (with_chrome < bare - 2) if ground_is_light else (with_chrome > bare + 2)
        check(f"background {style} toolbar contrasts with its ground",
              contrasts, True)

print("\nWindow drag: the titlebar strip belongs to the window, not the camera")
# A full-size-content window puts the view under the titlebar, so dragging the
# window used to orbit the model at the same time.
out, _, rc = run(sample("plate.step"), "--dragtest")
lines = dict(l.split(" ", 1) for l in out.splitlines() if " " in l)
check("titlebar band is present", out.splitlines()[0], "band 32")
check("dragging the titlebar leaves the camera alone", lines.get("titlebar"), "drag ignored")
check("dragging the model still orbits", lines.get("body"), "drag orbits")

print("\nChrome: the settings window and toolbar build without a window server")
png = os.path.join(scratch, "regress_settings.png")
out, _, rc = run(sample("plate.step"), "--settingsshot", png)
check("settings window builds", (rc, out), (0, "settings captured"))

print(f"\n{checks - len(failures)}/{checks} checks passed")
if failures:
    print("failed: " + ", ".join(failures))
sys.exit(1 if failures else 0)
