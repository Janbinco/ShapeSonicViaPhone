# Notes for Claude Code

This is Jialin's copy of Yotam Gingold's ShapeSonicPhone (github.com/yig/ShapeSonicPhone),
extended with a **"hands in the air"** input mode. Read `DESIGN.md` first,
especially the section "Hands in the air (front depth camera)".

- Do **not** push to yig's GitHub repo. Jialin's own copy is
  github.com/Janbinco/ShapeSonicViaPhone (branch `air-world-tracking`); the
  history starts from yig's `main`.
- State (2026-10-15): builds with Xcode 27 and runs on Jialin's iPhone 16 Pro
  (iOS 26.6). "Touch the glass" is switched off (`AppModel.glassModeAvailable`);
  the app always starts in hands in the air, with **Show shape on** by default.
- Air mode runs ARKit `ARFaceTrackingConfiguration` with
  `isWorldTrackingEnabled`: the front TrueDepth camera gives colour + depth, the
  back camera tracks the device. Fingertips are converted to **world**
  coordinates with ARKit's intrinsics and camera pose, and the shape is fixed in
  the world as in touch-the-glass (placed in front of the screen, re-placed by
  Recenter). The ARView renders the shape; `AirView` only draws fingertip dots
  (via `arView.project`), status and readout.
- `.disableFaceMesh` in `Stage` is required: without it RealityKit loads a face
  occlusion material synchronously on the main thread whenever a face is seen,
  hanging the app (watchdog 0x8BADF00D) — this was the "shape switch doesn't
  take" bug.
- Known tracking limits seen on the device: good when the whole hand is
  visible; tracking is lost when fingers point straight at the camera (Vision
  can't see the joints). Laying the phone flat, screen up, with the shape above
  it, is the suggested setup to try. Not yet done: a depth-based fallback for
  pointing fingers, holding tips briefly through dropouts, and a jitter
  measurement.
- `AppModel.load` prints `[ShapeSonic] …` timing lines (seen with
  `xcrun devicectl device process launch --console …`).
- The C++ core builds and passes `core_tests`:
  `cmake -S core -B build && cmake --build build && ./build/core_tests`

## Building and installing on the phone

Signing: Personal Team `3K76Q67AN8`, bundle ID `edu.gmu.jhuang26.shapesonic`
(the original `edu.gmu.shapesonic` is taken). Free provisioning expires after
7 days; rebuild to renew. Device ID of the 16 Pro: `00008140-0012401C0291401C`.

```
cd ios
xcodebuild -scheme ShapeSonic -configuration Debug -destination 'id=00008140-0012401C0291401C' \
  -derivedDataPath ~/ShapeSonicBuild -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008140-0012401C0291401C \
  ~/ShapeSonicBuild/Build/Products/Debug-iphoneos/ShapeSonic.app
xcrun devicectl device process launch --device 00008140-0012401C0291401C \
  --terminate-existing edu.gmu.jhuang26.shapesonic
```

If the phone shows as `unavailable` in `xcrun devicectl list devices`, reconnect
the cable and unlock it; it usually comes back within seconds.

## Tuning knobs

- Fingertip depth sampling: `ss_fingertip_depth` in `core/src/hands.cpp`
  (25% toward the next joint, 20th percentile).
- Vision confidence: `HandTracker.minConfidence` (0.3).
- One-euro filter: `Engine.setAirHands` (2 Hz, beta 8).
- Left/right hand assignment: `Engine.setAirHands`.
- Shape distance and size: menu (defaults 30 cm and 20 cm).
