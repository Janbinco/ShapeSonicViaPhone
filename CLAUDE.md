# Notes for Claude Code

This is a local copy of Yotam Gingold's ShapeSonicPhone (github.com/yig/ShapeSonicPhone),
extended by Jialin with a **"hands in the air"** input mode. Read `DESIGN.md` first,
especially the section "Hands in the air (front depth camera)".

- Do **not** push to yig's GitHub repo; this copy is for local experiments only.
- State: the hands-in-the-air Swift code (`ios/ShapeSonic/HandTracker.swift`,
  `AirView.swift`, changes in `Engine.swift`, `AppModel.swift`, `Stage.swift`,
  `MenuView.swift`, `PoseProvider.swift`) was written without Xcode and has **not yet
  been compiled or run on a device**. Expect a first round of compile fixes.
- The C++ additions (`core/src/hands.cpp`, declared in `core/include/shapesonic.h`)
  build and pass `core_tests`:
  `cmake -S core -B build && cmake --build build && ./build/core_tests`
- The front camera's buffer orientation (`bufferRight`/`bufferDown` in
  HandTracker.swift) is derived, not verified; the menu's "Camera calibration"
  (rotation / mirror) exists to fix it on a device. With Show shape on, the readout's
  x should grow to the user's right, y upward, z toward the user.
- Tuning knobs Jialin wants to adjust: fingertip depth sampling (`ss_fingertip_depth`:
  25% toward the next joint, 20th percentile), Vision confidence (0.3), one-euro filter
  (2 Hz, beta 8), hand left/right assignment (`Engine.setAirHands`), shape distance and
  size (menu; defaults 30 cm and 20 cm).
