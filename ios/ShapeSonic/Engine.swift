// The sonification loop: touches -> fingertips in world space -> shape-local
// points -> core probe -> mixer levels.
//
// It runs on the main thread, synchronously, on every touch event, every ARKit
// frame and every motion sample, so nothing waits for the next display frame.
//
// In the "hands in the air" input mode, fingertips come from the front depth
// camera instead (HandTracker), as world points; the shape is fixed in the
// world exactly as for touches, and each camera frame is probed.

import QuartzCore
import UIKit
import simd

enum HandMode: String, CaseIterable, Identifiable {
  case split  // by which half of the screen a touch starts on
  case order  // first five touches are the left hand, the next five the right
  var id: String { rawValue }
  var label: String { self == .split ? "Screen halves" : "Touch order" }
}

enum InputMode: String, CaseIterable, Identifiable {
  case glass  // fingers on the screen, the phone moves through the shape (ARKit)
  case air  // the front depth camera tracks the hands; the shape stays fixed in the world
  var id: String { rawValue }
  var label: String { self == .glass ? "Touch the glass" : "Hands in the air" }
}

final class Engine {
  /// A fingertip tracked by the depth camera.
  struct AirTip {
    var hand: Int
    var slot: Int
    var world: SIMD3<Float>  // metres, world frame (smoothed)
    var probe = ss_finger_probe(sdf: .infinity, edge: .infinity, corner: .infinity)
  }

  struct Finger {
    var hand: Int
    var slot: Int
    var viewPoint: CGPoint
    var fixedPoint: CGPoint  // in the screen's fixed, portrait-up coordinate space
    var probe = ss_finger_probe(sdf: .infinity, edge: .infinity, corner: .infinity)
  }

  let pose: PoseProvider
  let audio: AudioOutput
  var screenGeometry = ScreenGeometry()
  weak var screen: UIScreen?

  var shape: Shape? {
    didSet { update() }
  }
  /// Where the shape is in the world. Its local frame is metres, y up.
  var shapeToWorld = matrix_identity_float4x4 {
    didSet { worldToShape = shapeToWorld.inverse }
  }
  private(set) var worldToShape = matrix_identity_float4x4
  var handMode: HandMode = .order {
    didSet { clearFingers() }
  }
  var usePredictedTouches = false
  var params: ss_sonify_params = {
    var p = ss_sonify_params()
    ss_sonify_params_default(&p)
    return p
  }()

  private(set) var fingers: [ObjectIdentifier: Finger] = [:]

  // MARK: Hands in the air
  var inputMode: InputMode = .glass {
    didSet {
      clearFingers()
      setAirHands([], time: 0)
    }
  }
  /// Scale of the shape in air mode; edge and corner ranges are kept at their
  /// real-world size (2 cm) so tracking noise doesn't hide them.
  var airScale: Float = 0.5
  var airSmoothing = true
  private(set) var airTips: [AirTip] = []
  private var airFilters: [Int: ss_one_euro3] = [:]
  /// Votes on whether Vision's chirality matches left/right by position.
  private var chiralityAgrees = 0, chiralityDisagrees = 0

  /// Called after touches change or a finger crosses the surface (for drawing).
  var onFingersChanged: (() -> Void)?
  /// Called for each fingertip that crosses the surface (entered = now inside).
  /// A finger that touches down inside the shape counts as entering.
  var onCrossing: ((_ finger: ObjectIdentifier, _ entered: Bool, _ time: CFTimeInterval) -> Void)?

  // Scratch buffers, reused so the per-event path does not allocate.
  private var keys: [ObjectIdentifier] = []
  private var probeInput: [ss_finger] = []
  private var probeOutput: [ss_finger_probe] = []
  private var levels = [ss_hand_levels(), ss_hand_levels()]
  private(set) var lastLevels = [ss_hand_levels(), ss_hand_levels()]

  init(pose: PoseProvider, audio: AudioOutput) {
    self.pose = pose
    self.audio = audio
    keys.reserveCapacity(16)
    probeInput.reserveCapacity(16)
    probeOutput.reserveCapacity(16)
  }

  // MARK: Touches

  func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
    if let s = view.window?.screen { screen = s }
    for t in touches where fingers[ObjectIdentifier(t)] == nil {
      let p = t.location(in: view)
      let hands = handMode == .order ? [0, 1] : [p.x < view.bounds.midX ? 0 : 1]
      guard let (hand, slot) = hands.lazy.compactMap({ h in self.freeSlot(h).map { (h, $0) } }).first else {
        continue  // no free slot: a sixth finger on one hand
      }
      fingers[ObjectIdentifier(t)] = Finger(hand: hand, slot: slot, viewPoint: p, fixedPoint: fixed(p, view))
    }
    update(touchesChanged: true)
  }

  func touchesMoved(_ touches: Set<UITouch>, in view: UIView, event: UIEvent?) {
    for t in touches {
      let id = ObjectIdentifier(t)
      guard fingers[id] != nil else { continue }
      let latest = usePredictedTouches ? (event?.predictedTouches(for: t)?.last ?? t) : t
      let p = latest.location(in: view)
      fingers[id]!.viewPoint = p
      fingers[id]!.fixedPoint = fixed(p, view)
    }
    update(touchesChanged: true)
  }

  func touchesEnded(_ touches: Set<UITouch>) {
    for t in touches { fingers[ObjectIdentifier(t)] = nil }
    update(touchesChanged: true)
  }

  func clearFingers() {
    fingers.removeAll()
    update(touchesChanged: true)
  }

  private func freeSlot(_ hand: Int) -> Int? {
    let used = Set(fingers.values.filter { $0.hand == hand }.map(\.slot))
    return (0..<Int(SS_FINGERS)).first { !used.contains($0) }
  }

  private func fixed(_ p: CGPoint, _ view: UIView) -> CGPoint {
    guard let screen = view.window?.screen ?? screen else { return p }
    return view.convert(p, to: screen.fixedCoordinateSpace)
  }

  // MARK: Probe

  /// Recompute every fingertip's position and the sound levels, now.
  func update(touchesChanged: Bool = false) {
    if inputMode == .air {
      updateAir()
      return
    }
    guard let shape, let screen, !fingers.isEmpty else {
      audio.silence()
      if touchesChanged { onFingersChanged?() }
      return
    }
    let now = CACurrentMediaTime()
    let camera = pose.transform(at: now)
    let toShape = worldToShape * camera
    keys.removeAll(keepingCapacity: true)
    probeInput.removeAll(keepingCapacity: true)
    for (id, f) in fingers {
      let c = screenGeometry.cameraPoint(fixed: f.fixedPoint, on: screen)
      let p = toShape * SIMD4(c, 1)
      keys.append(id)
      probeInput.append(ss_finger(x: p.x, y: p.y, z: p.z, hand: Int32(f.hand), slot: Int32(f.slot)))
    }
    if probeOutput.count < probeInput.count {
      probeOutput.append(contentsOf: repeatElement(ss_finger_probe(), count: probeInput.count - probeOutput.count))
    }
    ss_probe(shape.ptr, &params, probeInput, probeInput.count, &levels, &probeOutput)
    audio.setLevels(levels)
    lastLevels = levels

    var crossed = false
    for (i, id) in keys.enumerated() {
      let was = fingers[id]!.probe.sdf <= 0, inside = probeOutput[i].sdf <= 0
      fingers[id]!.probe = probeOutput[i]
      if was != inside {
        crossed = true
        onCrossing?(id, inside, now)
      }
    }
    if touchesChanged || crossed { onFingersChanged?() }
  }

  // MARK: Air mode

  /// Hands from the depth camera: assign left/right, smooth, probe.
  func setAirHands(_ hands: [TrackedHand], time: TimeInterval) {
    // Left/right by position across the shape (its +x is the user's right).
    func meanX(_ h: TrackedHand) -> Float {
      let xs = h.tips.map { (worldToShape * SIMD4($0.world, 1)).x }
      return xs.reduce(0, +) / Float(max(xs.count, 1))
    }
    var assigned: [(hand: Int, data: TrackedHand)] = []
    if hands.count >= 2 {
      let sorted = hands.prefix(2).sorted { meanX($0) < meanX($1) }
      assigned = [(0, sorted[0]), (1, sorted[1])]
      if sorted[0].chirality >= 0, sorted[1].chirality >= 0, sorted[0].chirality != sorted[1].chirality {
        if sorted[0].chirality == 0 { chiralityAgrees += 1 } else { chiralityDisagrees += 1 }
      }
    } else if let h = hands.first {
      var hand = meanX(h) < 0 ? 0 : 1
      if h.chirality >= 0 {
        hand = chiralityDisagrees > chiralityAgrees ? 1 - h.chirality : h.chirality
      }
      assigned = [(hand, h)]
    }
    var tips: [AirTip] = []
    var seen = Set<Int>()
    let old = Dictionary(uniqueKeysWithValues: airTips.map { ($0.hand * 8 + $0.slot, $0.probe) })
    for (hand, h) in assigned {
      for t in h.tips {
        let key = hand * 8 + t.slot
        seen.insert(key)
        var p = t.world
        if airSmoothing {
          var f = airFilters[key] ?? {
            var f = ss_one_euro3()
            ss_one_euro3_init(&f, 2.0, 8.0)
            return f
          }()
          let input: [Float] = [p.x, p.y, p.z]
          var out: [Float] = [0, 0, 0]
          ss_one_euro3_filter(&f, input, time, &out)
          airFilters[key] = f
          p = SIMD3(out[0], out[1], out[2])
        }
        var tip = AirTip(hand: hand, slot: t.slot, world: p)
        if let probe = old[key] { tip.probe = probe }
        tips.append(tip)
      }
    }
    for key in airFilters.keys where !seen.contains(key) { airFilters[key] = nil }
    airTips = tips
    updateAir()
  }

  private func updateAir() {
    guard let shape, !airTips.isEmpty else {
      audio.silence()
      lastLevels = [ss_hand_levels(), ss_hand_levels()]
      onFingersChanged?()
      return
    }
    var p = params
    let range = 0.02 / max(airScale, 0.05)
    p.edge_range = max(p.edge_range, range)
    p.corner_range = max(p.corner_range, range)
    probeInput.removeAll(keepingCapacity: true)
    for t in airTips {
      let q = worldToShape * SIMD4(t.world, 1)
      probeInput.append(ss_finger(x: q.x, y: q.y, z: q.z, hand: Int32(t.hand), slot: Int32(t.slot)))
    }
    if probeOutput.count < probeInput.count {
      probeOutput.append(contentsOf: repeatElement(ss_finger_probe(), count: probeInput.count - probeOutput.count))
    }
    ss_probe(shape.ptr, &p, probeInput, probeInput.count, &levels, &probeOutput)
    audio.setLevels(levels)
    lastLevels = levels
    for i in airTips.indices { airTips[i].probe = probeOutput[i] }
    onFingersChanged?()
  }

  /// A fingertip's position in the shape's frame, in metres of the real world
  /// (for the on-screen readout).
  func airLocal(_ t: AirTip) -> SIMD3<Float> {
    let q = worldToShape * SIMD4(t.world, 1)
    return SIMD3(q.x, q.y, q.z) * airScale
  }
}
