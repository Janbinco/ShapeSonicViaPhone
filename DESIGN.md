# ShapeSonic 3D for iOS: design and architecture

An iPhone/iPad app of ShapeSonic (Huang, Hanocka, Siu, Gingold, SIGGRAPH Asia
2023; `../paper/main.tex`). An invisible 3D shape is anchored in the room. ARKit
tracks the device, and every finger on the screen is a fingertip at its
**physical position on the glass**, in world space. The phone acts like a palm:
sweep it through the shape and the fingers on the screen hear guidance, contact,
edge and corner sounds, as in the paper. The 2D web demo (`../demo`,
`../demo/DESIGN.md`) is the reference for the sonification constants and hand
logic.

Keep this document up to date when the implementation changes.

## Building and running

```sh
# Portable core and its tests (any desktop with CMake and a C++17 compiler):
cmake -S core -B build && cmake --build build && ./build/core_tests

# iOS app:
open ios/ShapeSonic.xcodeproj    # set a Development Team under Signing, run on a device
xcodebuild -project ios/ShapeSonic.xcodeproj -scheme ShapeSonic \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build   # compile check
```

ARKit needs a real device (iOS 17+, A12 or later). In the Simulator the app
falls back to a virtual device that the menu can move toward the shape, which
is enough to exercise the UI, loading, visualization and audio. Use headphones:
the left hand is the left ear.

The Xcode project is hand-written and uses Xcode 16+ *synchronized folders*:
any file added to `ios/ShapeSonic/` or `core/src/` is compiled automatically,
with no project edits. `models/` and `audio/` are folder references, copied into
the app bundle as `models/` and `audio/`.

## Files

```
core/                      portable C++17, no platform dependencies (shared with a future Android app)
  include/shapesonic.h     the C API: shapes, probing, mixer
  src/internal.hpp         Vec3, BVH, OctreeSDF, FeatureGrid, ss_shape
  src/geometry.cpp         closest point on triangle, BVH, feature hash grid, parallel_for
  src/octree.cpp           adaptive octree SDF
  src/shape.cpp            OBJ parser, weld/normalize, pseudonormals, build, sharp edges and corners
  src/sonify.cpp           fingertips -> per-hand levels (paper's falloff table)
  src/mixer.cpp            real-time mixer (loops, plucks, gain smoothing)
  tests/core_tests.cpp     CTest: OBJ parsing, SDF accuracy/sign on all models, features, probe, mixer
  CMakeLists.txt
ios/ShapeSonic.xcodeproj   app project (synchronized folders; shared scheme)
ios/ShapeSonic/
  ContentView.swift        @main app, full-screen stage, top bar
  MenuView.swift           the pop-up menu (sheet)
  AppModel.swift           state, settings (UserDefaults), shape loading, status
  Engine.swift             touches -> fingers -> world -> shape-local -> probe -> mixer
  PoseProvider.swift       ARKit pose + gyro/velocity extrapolation to "now"
  ScreenGeometry.swift     touch point -> metres on the glass (device ppi table)
  Stage.swift              ARView + TouchView, ARSession delegate, placement; finger rings
  Visualizer.swift         RealityKit meshes: translucent shape, edge tubes, corner dots/ranges
  Shape.swift              ss_shape wrapper; OBJ via core, PLY/STL/USD(Z)/ABC via ModelIO
  AudioOutput.swift        AVAudioEngine + AVAudioSourceNode calling ss_mixer_render
  Haptics.swift            Core Haptics tap when a fingertip crosses the surface
  ShapeSonic-Bridging-Header.h
models/                    demo shapes (OBJ, already about 0.4 m, all watertight;
                           torus.obj is generated: ring 0.15 m, tube 0.05 m, standing upright
                           with its hole facing the user)
audio/                     the sounds, copied from ../demo/audio (trimmed/transcoded there)
```

## Data flow

```
 OBJ ──► ss_shape_from_obj ─┐                   ┌─ weld, centre, fit to 0.4 m
 PLY/STL/USDZ ─► ModelIO ───┴► ss_shape ─build─►├─ BVH, pseudonormals
                                (background)    ├─ octree SDF
                                                └─ sharp edges, corners, hash grids

 UITouch (TouchView) ──┐
 ARFrame (60 Hz) ──────┼──► Engine.update()  [main thread, synchronous]
 CMDeviceMotion (200 Hz)┘     for each finger:
                                glass point (camera frame) ── PoseProvider.transform(now) ──► world
                                ── worldToShape ──► shape-local
                              ss_probe ──► levels[2] ──► ss_mixer_set_levels (atomics)
                              a fingertip crossed the surface? ──► Haptics tap
                                                               │
                                       audio thread: ss_mixer_render ◄─ AVAudioSourceNode
```

The heavy work (SDF build) happens once per shape, off the main thread. The
per-event path is a few microseconds: 10 octree lookups and 20 hash-grid
queries.

## Core

### Shapes

- **OBJ** is parsed by the core: `v` and `f` records, with `v/vt/vn` forms,
  negative (relative) indices and polygons (fan-triangulated). Everything else
  is ignored. Other formats are loaded by ModelIO on iOS and passed in as a
  triangle soup (`ss_shape_from_triangles`).
- **Weld** vertices that coincide (to 1e-6 of the diagonal), drop degenerate
  triangles and unreferenced vertices.
- **Normalize**: centre the bounding box on the origin and scale the longest
  side to 0.4 m. The paper's study shapes were "uniformly scaled to fit inside a
  cube area whose size is 0.4 meters". Loaded models can keep their own units
  (menu toggle).
- **Orientation**: if the signed volume is negative, all triangles are flipped
  so normals point outward.
- **Watertight** if every edge has exactly two faces. All demo models are.

### Signed distance

Exact distances come from a BVH (median split on the longest centroid axis,
4 triangles per leaf, nearest-first traversal) and Ericson's closest point on
a triangle, which also reports whether the closest point is on a face, an edge
or a vertex. The **sign** uses the angle-weighted pseudonormal of that feature
(Bærentzen and Aanæs 2005), which is exact for closed, consistently oriented
meshes. Non-watertight meshes use a majority vote of 3 ray parities instead.

### Octree SDF (`octree.cpp`)

The paper precomputed a dense SDF offline. Here it is built on the device in
well under a second, as an adaptive octree, to keep memory low:

- **Domain**: a cube around the shape with a 0.5 m margin (the guidance range).
  The root side is `leaf × 2^depth`, so leaves are exactly the leaf size
  (default 2 mm). Outside the domain the sampler returns the distance to the
  bounding box, a lower bound that is beyond the guidance range anyway.
- **Refinement** (level by level, in parallel). A cell that the surface may
  pass through (its centre is closer to the surface than 0.9 × its side; the
  half-diagonal is 0.87 × side) is always split, down to the leaf size, so the
  zero level set is resolved at the finest level. Any other cell is split if it
  is larger than its distance to the surface, or if *error-driven* refinement,
  as in adaptive distance fields (Frisken et al. 2000), flags it: trilinear
  interpolation of its 8 corners misses the exact distance at its centre or at
  one of its 6 face centres by more than 0.5 mm + 1% of the distance. Testing
  for error puts cells along the medial axis and the other kinks of the distance
  field, inside and outside, where interpolation is worst, instead of
  refining everywhere.
- **Storage**: each leaf stores its 8 corner values as int16 (16 bytes); the
  quantum is `max|d| / 32767`, about 0.04 mm. Corners shared between leaves
  are evaluated once (sort and unique on lattice keys). Internal nodes are one
  `uint32` per child: an internal child points to its own 8 children, and a
  leaf child carries a flag and its leaf index.
- **Query**: descend by octant (≤ 12 levels), then trilinear.

Measured on the demo models (`core_tests`, Apple M-series; a phone is a few
times slower). The errors are octree minus exact, at 20 000 random points; they
are compared with each sound's range D (guidance 50 cm outside, contact |min SDF|
inside):

| model | triangles | leaves | memory | build | ≤ 2 mm from surface | outside, > 1 cm | inside, > 1 cm (÷ D) |
|---|---|---|---|---|---|---|---|
| cube | 12 | 1.30 M | 26.7 MB | 0.29 s | 0.37 mm | 1.6 mm | 0.9% |
| bowl | 1 468 | 0.70 M | 14.3 MB | 0.25 s | 0.18 mm | 2.9 mm | 5.0% |
| mug | 25 776 | 0.80 M | 16.5 MB | 0.43 s | 0.25 mm | 5.4 mm | 3.4% |
| cat | 10 944 | 0.22 M | 4.5 MB | 0.20 s | 0.14 mm | 4.6 mm | 2.1% |

So guidance volume (`e^(−10x)` per metre) is off by at most about 5%, below
the ~1 dB loudness difference people notice. A dense grid at the same 2 mm
resolution over the same domain would be about 10⁹ cells. Memory grows with
surface area, which is why the cube, with its large flat faces, is the
largest. Increase `leaf_size` to trade accuracy for memory. Signs agree with an
independent ray-parity test at every sampled point.

### Sharp edges and corners (`shape.cpp`)

This follows the paper, which used libigl's `sharp_edges` with a threshold
"tuned per model so output edges matched common sense":

- **Sharp edge**: its two faces' normals differ by more than the threshold
  (default 30°; the menu slider re-detects). Boundary and non-manifold edges
  count as sharp.
- **Corner**: a vertex where ≥ 3 sharp edges meet; or where a chain of sharp
  edges turns by more than the threshold; or a cone-like point whose angle
  deficit `|2π − Σ face angles|` exceeds 70°, such as the apex of a cone, which
  has no sharp edges.
- Results: cube 12 edges / 8 corners, sphere and torus 0 / 0, cone 32 (the
  base rim) / 1 (the apex). The mug gets the parallel sharp edges along its lip that the
  paper's participants noticed. The cat is a faceted organic mesh and gets
  spurious edges at 30°, so demo shapes have per-model defaults
  (`AppModel.demoSharpAngles`: cat 50°).
- Distances to edges (segments) and corners (points) use a uniform hash grid
  with 2 cm cells, so a range-limited query checks 27 cells.

### Sonification (`sonify.cpp`, `mixer.cpp`)

The paper's mapping (supplemental Table 1), `V(x) = a + b·e^(−5x/D)` for
`0 ≤ x < D`:

| Sound | Recording | Plays when | x | a | b | D |
|---|---|---|---|---|---|---|
| Guidance | `guidance.mp3` loop | a fingertip of the hand is outside | closest outside SDF | 0 | 1 | 50 cm |
| Contact | `contact-{left,right}.mp3` loop | this fingertip is inside | depth −SDF | 0 | 0.8 | \|min SDF\| |
| Edge | `edge-{left,right}.mp3` pluck | a fingertip is near a sharp edge | closest edge distance | 0.6 | 0.4 | 2 cm |
| Corner | `corner-{left,right}.mp3` bell | a fingertip is near a corner | closest corner distance | 0.6 | 0.4 | 2 cm |

Touching a cube's corner plays contact, edge and corner together, as in the
paper. The mixer is the web demo's audio graph moved into the core, so both
platforms share it:

- **Hands and ears**: left-hand sounds go to the left ear and are lower. The
  contact, edge and corner recordings are already hard-panned L/R pairs that
  differ in pitch. The guidance loop is shared: each hand gets a copy summed to
  mono in its own ear, with the left one 2 semitones lower.
- **Pentatonic fingers**: 5 contact voices per hand at C D E G A (playback rates
  for 0, 2, 4, 7 and 9 semitones), with linear-interpolation resampling. The
  finger in slot *i* drives voice *i*.
- **Always running**: all 12 loops start at random offsets and never stop.
  Levels only move gain targets, which are approached per sample by a one-pole
  filter (τ: guidance 8 ms, contact 3 ms, edge and corner 6 ms, master 20 ms).
  This avoids clicks and keeps CPU use constant: 10 s of audio with every voice
  on renders in about 30 ms.
- ◆ **Plucks are retriggered**: while a hand is in range of an edge (or corner),
  a new pluck starts every 0.45 s, immediately on entering the range, from a
  pool of 6 voices. All of them go through the hand's edge (corner) gain, which
  follows the distance.
- **Mix**: guidance 0.5, contact 0.45, edge and corner 0.9; master volume from
  the menu.
- Leading and trailing samples ≤ 1e-4 are trimmed from every sound when it is
  loaded (MP3 encoder padding would delay plucks and leave gaps at loop points).
- **Real time**: `ss_mixer_render` never locks or allocates. Levels arrive as
  relaxed atomic floats (tearing between fields is harmless).

## iOS app

### Touch → 3D (`ScreenGeometry.swift`, `Engine.swift`)

Each touch's location is converted to the screen's **fixed (portrait-up)
coordinate space**, which does not rotate with the interface, then to metres
from the screen centre using the device's pixel density, then to ARKit's camera
frame: +x along the long axis toward the bottom of the device, +y toward the
right edge (in portrait), and +z out of the screen. The point is put on the
plane z = 0. `world = cameraTransform · p`, `local = shapeToWorld⁻¹ · world`.

- iOS doesn't report physical screen size, so the ppi comes from a table of
  device identifiers (`hw.machine`), divided by `UIScreen.nativeScale`
  (physical pixels per point, which accounts for Display Zoom and downsampled
  panels). Unknown devices fall back to 460 ppi for iPhone and 264 for iPad,
  and the menu has an override.
- The distance from the lens to the screen centre (a few cm, and different per
  model) is ignored on purpose. It is the same for every touch, so it is
  equivalent to moving the hidden shape slightly, which a listener can't
  detect. Only the scale matters, because it sets the spacing between fingers.

### Hands and fingers

The same two modes as the web demo, chosen under **Hands** in the menu and
remembered:

- **Screen halves**: a touch is the left hand if it starts on the left
  half of the screen, in the current orientation. It keeps its hand when dragged
  across the midline. A faint midline is drawn while no finger is down.
- **Touch order** (default): the first five simultaneous touches are the left hand, and
  the next five the right hand: a new touch takes the earliest free slot,
  checking the left hand first.
- Each new touch takes the lowest free of its hand's 5 slots, which is its
  pentatonic note. A touch with no free slot is ignored.
- iPhones track at most 5 touches at once (iPads about 11), so on an iPhone
  touch-order mode rarely reaches the right hand.

### Latency

The goal is the shortest path from a finger or a movement of the phone to
sound:

1. **Raw touches**. `TouchView` overrides `touchesBegan/Moved/Ended` and has no
   gesture recognizers, so there is no recognition delay. Each event updates the
   audio synchronously instead of waiting for the next frame. *Use predicted
   touches* (off by default) uses UIKit's predicted location, which is about a
   frame ahead.
2. **Pose extrapolation** (`PoseProvider`, on by default). ARKit poses are for
   the capture time of the camera frame, and they arrive a frame or more later.
   At each update the pose is brought forward to now: rotation by integrating
   the fused CoreMotion rotation rate (200 Hz) since the frame's timestamp,
   expressed in the camera frame (`(−y, x, z)` of CoreMotion's device axes);
   translation by a smoothed velocity from consecutive frames (at most 50 ms
   ahead). Every motion sample also re-runs the probe, so a finger held still is
   heard moving through the shape as the phone moves, at 200 Hz rather than
   60 Hz.
3. **Audio**. The `.playback` session category (sound even with the silent
   switch on) and a 3 ms preferred I/O buffer; the hardware may round it up. The
   menu shows the actual output latency. Levels reach the render thread through
   atomics, so they apply from the next buffer. Bluetooth headphones add
   150–300 ms; use wired headphones or the speaker for the lowest latency.
4. Rendering (RealityKit) is never on this path.

### Haptics (`Haptics.swift`)

A fingertip crossing the surface also gives a tap: a sharp, strong one going
in, the haptic counterpart of the abrupt contact sound, and a softer one coming
out. A finger that touches down already inside counts as entering. The tap is
fired from the same synchronous `Engine.update` that switches the contact
sound, so the two coincide. Core Haptics' engine is kept running
(`isAutoShutdownEnabled = false`) with the patterns built in advance, to
avoid any spin-up delay, and it is restarted after a reset or when the app
returns to the foreground. Taps closer than 40 ms on the same finger are
dropped, so a finger resting on the surface doesn't buzz with tracking noise.
There is a menu toggle (on by default). iPads have no Taptic Engine, so there
the toggle is disabled.

The haptics are felt in the hand holding the device, not at the fingertip,
and all fingers share them, so they say *when* a crossing happened while the
pentatonic notes say *which* finger.

### Placement

The shape's frame is gravity-aligned (ARKit `.gravity`), with +y up. When
tracking first becomes normal, and on **Recenter**, the shape's centre is put
0.45 m in front of the device at the device's height, turned so that its front
(+z) faces the user. **Place on surface at screen centre** raycasts to a
horizontal plane and rests the shape's base on it.

### UI

- **Top bar**: Menu, Show shape (eye), Recenter, and a tracking warning when
  tracking is limited. It never names the shape.
- **Menu** (sheet; opening it clears the fingers): the demo shapes (the current
  one is checked, which is the only place its name appears); **Load model…**
  (OBJ, PLY, STL, USD/USDZ, Alembic) and *Fit loaded models to 40 cm*; a status
  line (edges, corners, SDF memory and build time, errors); Show shape and Show
  edges and corners; Hands; the sharp-edge angle; volume and the
  surface-crossing vibration; the latency options and the measured output latency; placement; screen ppi and its override.
- **Visualization** (hidden by default): a translucent mesh, smooth-shaded
  except across creases sharper than the edge threshold, sharp edges as orange
  1.5 mm tubes, corners as red dots with translucent 2 cm range spheres.
  RealityKit does not sort the triangles within a transparent mesh, so if
  they wrote depth, whichever were drawn first would hide the rest (a
  patchwork of "flipped" triangles wherever the surface overlaps itself). On
  iOS 18+ the shape is drawn without depth writes, as an outward-facing and an
  inward-facing copy, each with back-face culling. Every layer then blends
  with correct lighting, and because all its triangles share one colour the
  result doesn't depend on draw order. The far side and the inside are visible,
  and so are all edges and corners. iOS 17 draws only the outward faces, with
  depth, so overlapping parts of concave shapes can still look patchy there.
- **Finger rings** are always drawn under the fingers, in the hand's colour,
  labelled with the note. They don't reveal the shape: they are filled while
  inside only when the shape is shown.
- **VoiceOver**: the stage has the `.allowsDirectInteraction` trait, so with
  VoiceOver on, touches reach the app directly.
- The screen doesn't sleep. System edge gestures are deferred and the home
  indicator is hidden. On iPad, turn off the four- and five-finger multitasking
  gestures in Settings, or they will take multi-finger touches.

## Android: is a parallel build worth it?

Yes, if it is wanted, and the code is arranged so that it costs little. Everything
that is not platform I/O is already in `core/` behind a C API, built with
CMake and tested on the desktop: mesh loading (OBJ), the SDF, feature
detection, probing and the mixer. An Android app would be a thin Kotlin shell:

| Concern | iOS (here) | Android |
|---|---|---|
| Pose | ARKit `ARFrame.camera.transform` | ARCore `Frame.getCamera().getPose()` (also gravity-aligned, y up) |
| Pose extrapolation | CoreMotion rotation rate | `TYPE_GYROSCOPE` / `TYPE_GAME_ROTATION_VECTOR` |
| Touches | `UITouch` in a `UIView` | `MotionEvent` pointers (incl. `getHistorical*`) in a `View` |
| Physical screen size | ppi table | `DisplayMetrics.xdpi/ydpi` (true physical dpi, no table) |
| Glass → camera frame | `fixedCoordinateSpace`, camera +x = device bottom | `Display.getRotation()` + ARCore's sensor-aligned camera pose |
| Audio | `AVAudioSourceNode` → `ss_mixer_render` | Oboe/AAudio low-latency stream callback → `ss_mixer_render` |
| Decoding sounds | `AVAudioFile` | `MediaExtractor`/`MediaCodec` (or ship WAV) |
| Other formats | ModelIO | OBJ only, or an importer such as Assimp |
| Visualization | RealityKit | SceneView/Filament, or an OpenGL view |
| Core binding | bridging header (C) | JNI wrapper over the same `shapesonic.h`, CMake `add_subdirectory(core)` |

Alternatives were considered and rejected: Unity with AR Foundation (which the
paper used on the Quest) and Flutter or Kotlin Multiplatform would share more
UI code. But they put an engine's audio pipeline, with larger DSP buffers, and
its input loop between the finger and the sound, which works against the
lowest-latency goal. Android audio latency and ARCore tracking quality also
vary more between devices, so the Android app should show its measured output
latency the way the iOS menu does.

## Tests

`core/tests/core_tests.cpp` (run by `ctest`, or directly):

- OBJ parsing: quads, `v//vn`, negative indices, CRLF; bad indices rejected.
- For every demo model: watertight; octree vs. exact SDF at 20 000 random
  points (< 1 mm within 2 mm of the surface, < 3 mm within 1 cm, < 1 cm
  farther outside, < 8% of |min SDF| deeper inside); sign vs. independent ray
  parity; expected feature
  counts (cube, sphere, torus, cone); probe cost (< 50 µs for 10 fingers).
- Probe semantics on the cube: quiet contact at the centre, loud contact just
  inside, the guidance falloff value outside, no guidance when all of a hand's
  fingers are inside, edge and corner near a corner, edge only near an edge,
  and the re-detection threshold.
- Mixer: silent at rest, the left hand only in the left ear, contact within a
  few ms, a pluck starting in the first buffer (silence trimmed), and the
  render cost.

The Swift layer has no automated tests. It is compiled for the Simulator and
the device. Device checks: a shape is placed in front of you; guidance gets
louder as the phone approaches it; contact sounds when the glass enters it,
one note per finger; edge and corner plucks near the cube's edges and corners;
both hand modes; loading a user OBJ/USDZ; and the latency shown in the menu.

## Known limitations and possible extensions

- All fingers lie on one plane (the glass), so a single touch pose can't feel
  curvature the way a hand's fingertips can. Tilting the phone stands in for
  rotating the hand.
- The ppi table must be extended for new devices (the override covers it in
  the meantime).
- ARKit drift and relocalization can move the shape. Recenter puts it back in
  front of you.
- Corner detection on dense, beveled meshes may need the threshold adjusted,
  as in the paper. Manual labels (the paper used Blender for failures) are not
  supported yet. A per-model sidecar file of corners and edges would be a
  natural extension.
- Edges are distances to sharp-edge segments, including the parts of an edge
  near a corner, so corners also play the edge sound, as in the paper.
