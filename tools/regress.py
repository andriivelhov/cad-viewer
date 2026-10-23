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

def defaults_bool(key, value):
    subprocess.run(["defaults", "write", DOMAIN, key, "-bool",
                    "true" if value else "false"], check=True)


def mesh_stats(*args):
    # (triangles, deflection, detail step) out of --stats.
    out, _, _ = run(*args, "--stats")
    f = out.split()
    return (int(f[f.index("triangles") + 1]),
            float(f[f.index("deflection") + 1]),
            int(f[f.index("step") + 1]))


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
# This check used to assert only that the measurement was unchanged, which is
# true whether or not the setting does anything - and it did not: the stored
# quality was applied to the ivar but never to a document opened from Finder,
# so every file was meshed at Normal. Assert the mesh actually moves.
#
# The pick is at 700,400 rather than 700,500 because picking is pixel-exact and
# 700,500 sits on a feature edge: a headless pick now re-meshes to the same
# detail the window would be showing, so the edge moves between quality levels
# and that pixel lands on the spline at Draft and on the face at Fine. Both
# answers are correct, which makes it the wrong pixel to ask. 700,400 is well
# inside the column's 40 mm shaft.
measurements = set()
triangles = []
for quality in (0, 1, 2):
    defaults_set("TessellationQuality", quality)
    out, _, _ = run(sample("column.step"), "--pick", "700", "400")
    measurements.add(out.split("⌀")[-1].strip())
    stats, _, _ = run(sample("column.step"), "--stats")
    triangles.append(int(stats.split("triangles")[1].split()[0]))
defaults_clear("TessellationQuality")
check("diameter identical at coarse, normal and fine detail",
      measurements, {"40.0000 mm  (r 20.0000)"})
check("coarser detail really means fewer triangles",
      triangles[0] < triangles[1] < triangles[2], True)

print("\nAdaptive detail: the mesh follows what the screen can actually show")
# The mesh a model is loaded with is sized against the model, so magnifying a
# small feature used to show the facets it was built with however fine the
# Detail setting was - Detail is relative to the same bounding box. ring.step
# is the shape that exposes it: 3 mm of tube swept around 80 mm.
defaults_bool("AdaptiveDetail", False)
flat = [mesh_stats(sample("ring.step"), "--zoom", z) for z in ("1", "2", "4")]
check("with sharpening off, zooming in changes nothing",
      {(t, round(d, 6), s) for t, d, s in flat}, {flat[0][:2] + (0,)})

defaults_bool("AdaptiveDetail", True)
sharp = [mesh_stats(sample("ring.step"), "--zoom", z) for z in ("1", "2", "4")]
check("zooming in raises the triangle count",
      sharp[0][0] < sharp[1][0] < sharp[2][0], True)
check("zooming in tightens the chordal deviation",
      sharp[0][1] > sharp[1][1] > sharp[2][1], True)
# Against the chordal deviation, not the triangle count: the count is a cost,
# not a quality. Letting the chordal test set facet count instead of holding
# the angular cap down cut the count eightfold at the same deviation, and the
# picture got no worse - a check written against the count would have called
# that a regression.
check("sharpening tightens the deviation well past the loaded mesh",
      sharp[2][1] < flat[2][1] / 8 and sharp[2][0] > flat[2][0] * 2, True)

# Detail has to keep meaning something: without a target per setting, adaptive
# detail converges all three on the same mesh and the setting goes dead.
spread = []
for quality in (0, 1, 2):
    defaults_set("TessellationQuality", quality)
    spread.append(mesh_stats(sample("ring.step"), "--zoom", "4")[0])
defaults_clear("TessellationQuality")
check("Detail still separates the three levels once sharpened",
      spread[0] < spread[1] < spread[2], True)

# Ids come from the topology now, not from the triangulation, so a measurement
# taken against a sharpened mesh has to land on the same geometry.
measured = set()
for adaptive in (False, True):
    defaults_bool("AdaptiveDetail", adaptive)
    out, _, _ = run(sample("column.step"), "--pick", "700", "400")
    measured.add(out)
check("sharpening never moves a measurement", len(measured), 1)

defaults_bool("AdaptiveDetail", True)
sharp_png = os.path.join(os.environ.get("TMPDIR", "/tmp"), "regress_sharp.png")
_, _, rc = run(sample("ring.step"), "--zoom", "4", "--render", sharp_png)
check("a sharpened view still renders",
      rc == 0 and os.path.exists(sharp_png) and os.path.getsize(sharp_png) > 5000,
      True)
# Runaway refinement is how this feature breaks badly, so the budget that stops
# it is worth asserting rather than trusting.
check("the budget caps refinement rather than letting it run away",
      mesh_stats(sample("ring.step"), "--zoom", "400")[0] < 6000000, True)
defaults_clear("AdaptiveDetail")

# Does the sharpened mesh actually look more like the surface? Triangle counts
# say the mesh changed, not that the picture got better. Rendering the same
# view three ways and measuring each against the fully-resolved one answers the
# question the feature was built for.
try:
    import numpy as np
    from PIL import Image
except ImportError:
    print("  skip  pixel comparison needs numpy and pillow")
else:
    def render(name, adaptive, quality):
        defaults_bool("AdaptiveDetail", adaptive)
        defaults_set("TessellationQuality", quality)
        path = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"regress_{name}.png")
        run(sample("ring.step"), "--zoom", "18", "--render", path)
        return np.asarray(Image.open(path).convert("RGB")).astype(float)

    coarse = render("coarse", False, 1)
    sharp = render("sharp", True, 1)
    truth = render("truth", True, 2)
    defaults_clear("AdaptiveDetail", "TessellationQuality")
    off = np.abs(coarse - truth).mean()
    on = np.abs(sharp - truth).mean()
    check(f"the sharpened render is closer to the real surface "
          f"({off:.3f} -> {on:.3f})", on < off / 1.5, True)

# The live path, not the synchronous one every check above uses: a real window,
# a real run loop, the settle timer, the background build and the upload. This
# is the part that can be perfectly correct in policy and still never fire.
defaults_bool("AdaptiveDetail", True)
out, _, _ = run(sample("ring.step"), "--settle", "5")
live = int(out.split("step")[-1].strip()) if "step" in out else -1
check("sharpening fires on its own once the camera settles", live > 0, True)

defaults_bool("AdaptiveDetail", False)
out, _, _ = run(sample("ring.step"), "--settle", "5")
check("and does not fire when it is switched off",
      out.split("step")[-1].strip(), "0")
defaults_clear("AdaptiveDetail")

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
