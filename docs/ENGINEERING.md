# 3DViewer — core spike

Feasibility spike for a native macOS CAD viewer. Proves the load → topology →
exact-measurement path before any UI exists.

## Build

```sh
brew install opencascade      # OCCT 7.9.3
cmake -S . -B build && cmake --build build -j8
./build/cadinspect samples/plate.step
```

## Release build

```sh
./packaging/build_release.sh "Apple Development: Your Name (TEAMID)"
```

The script clears `build/CADViewer.app` first: a signed and stapled bundle is
protected by macOS and CMake cannot rewrite its `Info.plist`.

Builds, bundles the ~46 OCCT dylibs into `Contents/Frameworks` with rewritten
install names, signs, and produces `packaging/CADViewer-1.0.dmg` (18 MB). The
app then runs on a machine that has never seen Homebrew - verified by `otool`
reporting zero `/opt/homebrew` references and no stale rpath.

Passing no identity ad-hoc signs it: the app still runs, but macOS will not
load the QuickLook extension and other machines get a Gatekeeper warning.

Shipping to other people needs a **Developer ID Application** certificate -
which is a different certificate type from *Apple Development*, not an upgrade
of it - plus notarisation:

```sh
# one-time, after creating the certificate in Xcode
xcrun notarytool store-credentials cadviewer \
      --apple-id <appleid> --team-id RGKP6D55BR --password <app-specific-password>

# per release: builds, signs hardened, notarises, staples
./packaging/build_release.sh "Developer ID Application: <Name> (RGKP6D55BR)" cadviewer
```

With a Developer ID identity the script switches to `--options runtime
--timestamp`; both are required for notarisation and neither is wanted for a
local ad-hoc build.

`packaging/verify_extension.sh` installs the result and reports whether macOS
actually activates the QuickLook extension - the open question this version
ends on.

## Windows

One window per part, like any normal Mac app: `ViewerWindowController` owns a
window, a `CADView` and its status line; `AppDelegate` keeps the list. Opening a
file reuses the front window while it is still empty, otherwise it gets a window
of its own, cascaded. ⌘N opens an empty window, ⌘W closes one via
`performClose:`, and `applicationShouldTerminateAfterLastWindowClosed:` returns
NO so the app survives its last window; clicking the Dock icon then brings one
back.

## macOS integration

`app/Info.plist.in` declares the file types. STL, OBJ and GLB already have
system UTIs (`public.standard-tesselated-geometry-format`,
`public.geometry-definition-format`, `org.khronos.glb`) so they are *imported*
at `Alternate` rank; STEP, IGES, BREP, glTF and VRML have only dynamic UTIs, so
they are *exported* at `Owner` rank. After `lsregister`, Finder shows the app
icon for `.step` files and offers CAD Viewer as the opener.

`tools/import_icon.py` builds `packaging/AppIcon.icns` from artwork on Apple's
icon grid (1024 canvas, 824 shape, 22.37% corner radius) so it matches the
visual size of other icons in the Dock:

```sh
python3 tools/import_icon.py packaging/artwork/icon_source.png full-bleed packaging/AppIcon
```

`full-bleed` applies the squircle to square art; `baked` crops art that already
contains a rounded shape on a backdrop. Icons were compared at 512/128/64/32/16
before choosing: detailed artwork collapses into a blob below 32 px, which is
the size that actually matters in Finder. `tools/make_icon.py` still generates
the original drawn-from-scratch icon if you want it back.

## Layout

| Path | Purpose |
|---|---|
| `core/include/cadcore/CadDocument.h` | Normalized document: capabilities, stats, exact geometry queries |
| `core/src/CadDocument.cpp` | Format dispatch, XCAF load, topology analysis |
| `core/tools/cadinspect.cpp` | CLI that dumps everything the viewer will need |
| `core/tools/makesamples.cpp` | Writes a known 100x60x10 plate (holes d=12/8/6/5) to every format, plus `column.step` (65x40x600) for framing tests |
| `core/tools/makestress.cpp` | N-instance assembly for scale testing |
| `app/CADView.mm` | Metal renderer, orbit camera, face picking, measurement |
| `app/Shaders.metal` | Background, shaded+identity, screen-space edge quads |
| `app/main.mm` | Window, menus, drag-and-drop, `--render` headless mode |

## Format support

Read paths all land in one XCAF document, so the renderer, tree, picking and
measurement code is written once. Adding a format is a row in `kFormats`.

| Format | Tier | Face select | Exact measure | Notes |
|---|---|---|---|---|
| STEP | B-rep | yes | yes | Primary target. Full topology + units. |
| BREP | B-rep | yes | yes | OCCT native. |
| IGES | B-rep | yes | partial | Surface format: no solids, cylinders degrade to NURBS. |
| glTF/GLB | mesh | no | no | Declares metres; handled. |
| STL | mesh | no | no | No units; assumed mm. |
| OBJ | mesh | no | no | No units and Y-up: both corrected explicitly. |
| VRML | mesh | no | no | Registered, untested. |
| PLY | — | — | — | **OCCT is write-only.** Needs ModelIO or tinyply. |

## Verified

Against a plate built to known dimensions:

- Bounding box exact (100 x 60 x 10 mm) in all six working formats
- Hole diameters recovered as 12.0000 / 8.0000 / 6.0000 / 5.0000 mm from
  analytic surfaces, not from the mesh
- Volume 57887.279 mm^3, matches 60000 - pi*67.25*10 by hand
- 500-instance assembly (7000 faces, 598k triangles): 513 ms read, 10 ms tessellate

## Viewer

```sh
open build/CADViewer.app --args /path/to/file.step   # or drag a file in
./build/CADViewer.app/Contents/MacOS/CADViewer f.step --render out.png
```

Drag to orbit (vertical is inverted), ⌘/⌥-drag or right-drag to pan, scroll or
pinch to zoom, `F` to frame.


A floating toolbar sits over the viewport, clear of the traffic lights:

```
[ View | Measure | Points ]   [ Frame ]   [ Iso | Front | Top | Right ]
```

Plain `NSSegmentedControl`s drawn straight on the Metal view - they carry their
own native bezel and follow the system appearance, so the window stays
full-bleed with no chrome bar. The mode control stays in sync when the mode is
changed from the keyboard or the View menu.

Two modes, on `V` / `M`, in the View menu, and in the toolbar:

| mode | click does |
|---|---|
| **View** (`V`) | inspects a face: type, area, exact diameter |
| **Measure** (`M`) | two consecutive clicks give an exact face-to-face distance |

⇧-click measures from any mode. Hovering highlights the face under the pointer
in blue; the selected face is amber. The cursor reflects what a click will do -
pointing hand over pickable geometry, open hand over empty space, closed hand
while dragging, crosshair in measure mode.

Headless modes, both of which a QuickLook extension will reuse:

```sh
CADViewer f.step --render out.png [--appearance light|dark]
CADViewer f.step --pick 700 500        # prints the face under that pixel
CADViewer f.step --select 6 --render out.png   # drive highlight headlessly
CADViewer f.step --hover 2  --render out.png
CADViewer f.step --cliptest            # frustum vs model across zoom/pan
CADViewer f.step --view top --render out.png
CADViewer f.step --chromeshot ui.png   # AppKit layer only, needs no permission
CADViewer f.step --points 690 200 690 700
cadinspect f.step --edist 17 9         # exact edge-to-edge distance
```

`--chromeshot` renders the view hierarchy with `cacheDisplayInRect:`, which is
how the toolbar gets looked at from a terminal: screen capture needs a
permission this process does not have and returns black frames.

The viewport follows the system light/dark appearance; the readout sits in a
standard `NSVisualEffectView` strip.

Rendering notes worth keeping:

- **Winding.** OCCT emits counter-clockwise triangles; Metal defaults to
  clockwise. Without `setFrontFacingWinding:` every face reads as back-facing
  and the shader inverts every normal, which shades the model almost black.
- **Edge depth.** Surfaces are pushed away with a slope-scaled depth bias and
  edges are drawn unmodified. Offsetting the *edges* instead breaks rims on
  curved faces into arcs, because the edge polyline and the triangulation
  diverge by up to a full chordal deviation.
- **Near/far must come from the model, not the pivot.** Deriving them from
  `_distance` assumes the pivot sits on the geometry; that stops being true the
  moment you pan, and the near plane then slices the part open mid-view. Fit
  them to the bounding sphere as seen from the eye instead. Keep the ratio
  tight for depth precision - letting near collapse toward zero leaves 10 mm of
  material spanning 0.00002 in NDC, and no depth offset can be tuned to work -
  but never at the cost of clipping the part. `--cliptest` sweeps zoom 0.5-30x
  and pan 0-4x radius and asserts the bounding sphere stays inside the frustum.
- **Line width.** Metal rasterizes lines at exactly 1 px, so edges are expanded
  into screen-space quads. NDC spans 2.0, so pixel conversion uses *half* the
  drawable size.
- **Framing fits the bounding box, not the bounding sphere.** A sphere fit needs
  `R/sin(fov/2)` (3.33R at 35 deg) - an arbitrary multiple of R overflows - and
  it wastes the entire width on a long thin part while still clipping its
  length. Project the eight box corners into the camera basis, centre on those
  extents, and solve both FOV axes: `max(halfHeight/tanY, halfWidth/tanX)`
  measured to the *near* face, so the closest corner still fits.
- **The fit needs the aspect of the surface being drawn**, not the window's.
  Headless renders frame for their own output size.
- **Pan must be derived from the field of view**, not a tuned constant. The
  visible height at the pivot is `2*d*tan(fov/2)`, so world-units-per-point is
  that over the view height. A hand-picked constant had the model outrunning
  the pointer by 2.4x. Mouse deltas are in points, so use the view bounds, not
  the backing-scaled drawable size.
- **Hover resolves against the previous frame's identity buffer**, so it costs
  one 3-vertex pass per mouse move instead of a re-render, with a single
  resolve in flight at a time and its own readback buffer so it cannot race a
  click.
- Camera is a plain orbit about the pivot: drag rotates, ⌘/⌥ or right-drag
  pans the pivot, scroll changes distance. Cursor-anchored orbit and zoom were
  tried and reverted - they moved the pivot off the model, which read as the
  camera drifting.
- **The pick resolve samples the depth attachment**, so every path that renders
  must use the *owned* depth texture with `MTLStoreActionStore`. An offscreen
  path that allocated its own depth texture left the resolve reading
  uninitialised memory - depth came back NaN, and NaN silently passed a
  `>= 1.0` emptiness test. Compare with `!(d < limit)` so NaN fails closed.
- The measurement chip is positioned from the projected midpoint each frame.
  Metal texture space is top-left origin and AppKit is bottom-left, so the y
  coordinate is flipped; it hides when the midpoint goes behind the camera.
- **Selection is a flag per entity**, uploaded to the shaders as two buffers,
  so a multi-selection of any size highlights without the shader needing to
  know how many things are selected.
- **`-[NSString intValue]` is 32-bit signed**, so an entity id with the edge
  flag set (top bit) clamps to `INT_MAX` and silently selects nothing. Parse
  entity ids with `longLongValue`.
- **Headless picking must frame for the same size it renders**, or pick
  coordinates and rendered pixels refer to different cameras. Only shows up on
  small targets like corners.
- **MSAA and the identity buffer.** 4x MSAA covers colour and depth, but integer
  formats cannot be multisample-resolved - resolve averages, which is
  meaningless for IDs. The identity buffer stays multisampled and one texel is
  resolved on demand by `fsPickResolve`, which scans samples and takes the first
  real face so clicking near an antialiased edge still selects the face.
- **Uniforms.** Only `float4x4`/`float4`/`uint` cross into Metal. `float3` and
  `float3x3` pack differently on each side and silently corrupt later fields.
- **The metallib must be a bundle resource**, not a `POST_BUILD` copy: that only
  runs when the target relinks, so editing only a `.metal` file silently ships
  a stale shader library.

## Measured

| | plate.step | 500-part assembly |
|---|---|---|
| parse | 5.7 ms | 513 ms |
| tessellate + buffers | 2 ms | 31 ms |
| app launch → rendered frame | 0.45 s | 1.10 s |
| triangles / edge segments | 604 / 304 | 598 000 / 298 000 |

Anti-aliasing, measured across the plate silhouette (transitions from
background to body in a single pixel are aliased):

| | aliased | antialiased |
|---|---|---|
| before | 147 | 55 |
| 4x MSAA | 11 | 191 |

Measurement, verified against known geometry:

| query | result | expected |
|---|---|---|
| plate edge length | 100.0000 / 60.0000 mm | plate is 100 x 60 |
| column rim circle | 125.6637 mm, d 40.0000 | pi x 40 |
| tube length, rim to rim | 600.000000 mm | 600 |
| plate thickness, edge to edge | 10.000000 mm | 10 |
| point snapped to cylinder | radius 20.0000 from axis | tube radius 20 |
| vertex→vertex, plate corners | 116.6190 mm | sqrt(100²+60²) |
| vertex→vertex, body diagonal | 117.0470 mm | sqrt(100²+60²+10²) |
| rim edge → rim edge | 600.0000 mm | tube length |
| rim centre → rim centre | 600.0000 mm | tube length |
| 4 top-face edges, ⇧-selected | 320.0000 mm, closed loop | 2x(100+60) |
| 2 connected edges | 160.0000 mm, end to end 116.6190 | chain |

## QuickLook extensions

Two separate extension points, both in `app/quicklook/`:

| extension | point | what it does |
|---|---|---|
| `CADThumbnail.appex` | `com.apple.quicklook.thumbnail` | static Finder thumbnails, via the same offscreen path as `--render` |
| `CADPreview.appex` | `com.apple.quicklook.preview` | an **interactive** viewer in the preview pane and spacebar panel - orbit, zoom and hover all work |

The preview extension is a `QLPreviewingController` hosting the real `CADView`
with `navigationOnly = YES`: drag to rotate, scroll or pinch to zoom, and
nothing else. A preview pane is for looking at the part, so picking, hover and
measurement are all off there.

Two things are needed to make dragging work inside a preview pane:

- **Gesture recognisers, not raw mouse events.** The QuickLook host claims drag
  events (normally to drag the file out), so `mouseDragged:` never arrives. An
  `NSPanGestureRecognizer` participates in gesture arbitration and wins the
  drag; `NSMagnificationGestureRecognizer` covers pinch-zoom.
- **`acceptsFirstMouse:`** returning YES, or the first click in an inactive
  pane is swallowed by window activation.

STEP, IGES, BREP, glTF and VRML are ours; STL, OBJ and GLB are declared at
`Alternate` rank because macOS already handles them.

Both extensions render on **transparency** (`transparentBackground = YES`), so
QuickLook composites the model onto Finder's own background instead of a dark
box. The app window keeps its gradient. Two details this needs:

- skip the background pass, clear the colour attachment to `(0,0,0,0)`, and set
  `layer.opaque = NO` or AppKit composites the cleared pixels against black;
- build the `CGImage` with `kCGImageAlphaPremultipliedFirst`. The usual
  `kCGImageAlphaNoneSkipFirst` discards the alpha channel and the surround
  comes back opaque.

QuickLook caches thumbnails hard: after changing how they render, test with a
file it has never seen or run `qlmanage -r cache`, otherwise you are grading a
stale image.

**Thumbnail sizing:** draw into exactly the context Finder asks for
(`request.maximumSize`, scaled by `request.scale`). Forcing a square left the
rest of the panel unpainted - the model appeared shoved into the corner of a
white box.

Four separate things had to be right, and each failed silently:

1. **An `.appex` is a Mach-O executable**, entered at `NSExtensionMain` - not a
   loadable bundle. CMake's `MODULE` produces a bundle, which PlugInKit refuses
   without a word. It is `add_executable` with `-e _NSExtensionMain` and a
   hand-assembled bundle layout.
2. **`CADView`'s initialiser built the toolbar**, so the extension constructed
   AppKit controls off the main thread and hung. Hence
   `initHeadlessWithFrame:device:`, which skips all UI.
3. **App extensions must be sandboxed.** Without
   `com.apple.security.app-sandbox` macOS ignores the bundle entirely - no log,
   no error, `pluginkit -a` returns 0 and does nothing. See
   `app/quicklook/CADThumbnail.entitlements`. The app must also be notarised;
   Gatekeeper reporting `rejected: Unnotarized Developer ID` is enough to keep
   the extension out.
4. **A signed bundle is write-protected, and the failure is silent.** The embed
   step copies the extensions into the app; run against an already-signed and
   stapled bundle the copy fails and leaves an **empty** `.appex` behind, which
   PlugInKit then rejects as an invalid plugin path. The target now removes
   `_CodeSignature` before copying (it re-signs at the end anyway), and the
   release script clears the whole bundle first.
5. **A `POST_BUILD` step only runs when its own target relinks.** Embedding the
   extensions was a POST_BUILD on `CADViewer`, so editing only an extension
   source rebuilt the `.appex` and then shipped the *previous* one inside the
   app - silently, repeatedly. Embedding is now a custom *target*, which is
   never "up to date" and always runs. (The stale-metallib bug earlier was the
   same mistake in a different place.)
6. **`replyWithContextSize:` is in points; the context is scaled.** Drawing
   into `CGRectMake(0, 0, points.width, points.height)` fills only the
   bottom-left quadrant of a Retina tile, because CoreGraphics' origin is
   bottom-left. Take the extent from `CGContextGetClipBoundingBox(context)`
   instead. This one hid for three rounds because the test harness requested
   `scale:1.0` while Finder uses 2 - a test that does not reproduce the real
   conditions is worse than no test, because it reads as a pass.
7. **Thumbnails must be opaque.** A transparent thumbnail gets wrapped in
   Finder's white document-page frame, which insets and shrinks the model; an
   opaque one is drawn full-bleed. The drawing block paints its own ground
   rather than trusting the render to be opaque. The *preview* extension stays
   transparent, where it composites onto the pane.
8. **`CGBitmapContextCreateImage` does not copy your buffer.** `renderImageOfSize:`
   passed its own `NSMutableData`, so the returned `CGImage` referenced memory
   freed when the method returned. Writing a PNG immediately hid it; the
   QuickLook drawing block runs much later and crashed in `CGContextDrawImage`.
   Passing `NULL` lets CoreGraphics own the backing store.

Registration is not immediate - allow ~10 s before concluding it failed.
`packaging/verify_extension.sh` installs, registers and checks end to end.

## Known rough edges

- **OCCT writes progress and warnings to stderr.** Still unfixed; the app needs
  a `Message_Printer` installed to silence it. Harmless in the GUI, noisy on the
  command line (`2>/dev/null` everywhere in this README is why).
- **IGES claims exact geometry when it is degraded.** The format loses solids
  and turns analytic cylinders into NURBS, so `caps().exactGeometry` is
  optimistic there. It probably wants a third fidelity tier.
- **PLY cannot be read** - OCCT's PLY provider is write-only. Needs ModelIO
  (free, in the OS) or tinyply.
- **Textures and materials are never displayed.** `RenderVertex` carries no UVs
  and the shaders sample no textures. OBJ+MTL and glTF do carry materials and
  OCCT reads them into `XCAFDoc_VisMaterial`; the extraction discards them.
- No component sidebar or section planes.
- `_isPanning` is latched on mouse-down, so pressing ⌘ mid-drag pans correctly
  but the cursor does not update until the next event.
- Edge quads have no joins, so tight corners show a small notch at wide widths.
- The toolbar has no icons; labels were chosen over SF Symbols so the modes read
  unambiguously to someone who has not used CAD before.
