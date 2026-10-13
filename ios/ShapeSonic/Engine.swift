// The sonification loop: touches -> fingertips in world space -> shape-local
// points -> core probe -> mixer levels.
//
// It runs on the main thread, synchronously, on every touch event, every ARKit
// frame and every motion sample, so nothing waits for the next display frame.

import QuartzCore
import UIKit
import simd

enum HandMode: String, CaseIterable, Identifiable {
  case split  // by which half of the screen a touch starts on
  case order  // first five touches are the left hand, the next five the right
  var id: String { rawValue }
  var label: String { self == .split ? "Screen halves" : "Touch order" }
}

final class Engine {
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
  var handMode: HandMode = .split {
    didSet { clearFingers() }
  }
  var usePredictedTouches = false
  var params: ss_sonify_params = {
    var p = ss_sonify_params()
    ss_sonify_params_default(&p)
    return p
  }()

  private(set) var fingers: [ObjectIdentifier: Finger] = [:]
  /// Called after touches change or a finger crosses the surface (for drawing).
  var onFingersChanged: (() -> Void)?

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
    guard let shape, let screen, !fingers.isEmpty else {
      audio.silence()
      if touchesChanged { onFingersChanged?() }
      return
    }
    let camera = pose.transform(at: CACurrentMediaTime())
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
      let was = fingers[id]!.probe.sdf <= 0
      fingers[id]!.probe = probeOutput[i]
      if was != (probeOutput[i].sdf <= 0) { crossed = true }
    }
    if touchesChanged || crossed { onFingersChanged?() }
  }
}
