// The full-screen stage: an ARView (camera passthrough and visualization)
// under a transparent TouchView that receives raw multi-touch.
//
// Without ARKit (the Simulator), the view renders without a camera and the
// device pose is a virtual one that the menu can move toward the shape.
//
// In "hands in the air" mode, ARKit is paused (the front camera is in use) and
// an AirView with the front camera's picture covers the stage.

import ARKit
import RealityKit
import UIKit

final class Stage: NSObject, ARSessionDelegate {
  let container = UIView()
  let arView: ARView
  let touchView = TouchView()
  let airView = AirView()
  let visualizer = Visualizer()
  /// Hands-in-the-air mode: ARKit stays paused.
  private(set) var airMode = false
  let isAR = ARWorldTrackingConfiguration.isSupported
  let engine: Engine
  var onTrackingChanged: ((String?) -> Void)?

  /// Distance from the device to the shape's centre when placed in front of it.
  static let placementDistance: Float = 0.45
  private var placed = false
  private var virtualCamera: PerspectiveCamera?
  /// Simulator only: how far the virtual device has moved toward the shape (m).
  var virtualAdvance: Float = 0 {
    didSet { updateVirtualPose() }
  }

  init(engine: Engine) {
    self.engine = engine
    arView = ARView(frame: .zero, cameraMode: ARWorldTrackingConfiguration.isSupported ? .ar : .nonAR,
                    automaticallyConfigureSession: false)
    super.init()
    arView.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField])
    arView.scene.addAnchor(visualizer.anchor)
    airView.isHidden = true
    for v in [arView, touchView, airView] {
      v.frame = container.bounds
      v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(v)
    }
    touchView.engine = engine
    if !isAR {
      arView.environment.background = .color(UIColor(white: 0.09, alpha: 1))
      let camera = PerspectiveCamera()
      let anchor = AnchorEntity(world: matrix_identity_float4x4)
      anchor.addChild(camera)
      arView.scene.addAnchor(anchor)
      virtualCamera = camera
    }
  }

  func start() {
    engine.screen = touchView.window?.screen
    if isAR && airMode {
      onTrackingChanged?(nil)
    } else if isAR {
      let config = ARWorldTrackingConfiguration()
      config.worldAlignment = .gravity
      config.planeDetection = [.horizontal]
      arView.session.delegate = self
      arView.session.run(config)
    } else {
      updateVirtualPose()
      recenter()
      onTrackingChanged?("No ARKit: virtual device")
    }
  }

  func pause() {
    if isAR { arView.session.pause() }
  }

  func resume() {
    guard isAR, !airMode else { return }
    if let config = arView.session.configuration {
      arView.session.run(config)
    } else {
      let config = ARWorldTrackingConfiguration()
      config.worldAlignment = .gravity
      config.planeDetection = [.horizontal]
      arView.session.delegate = self
      arView.session.run(config)
    }
  }

  /// Switch between the glass (ARKit) and hands-in-the-air stages.
  func setAirMode(_ on: Bool) {
    guard on != airMode else { return }
    airMode = on
    airView.isHidden = !on
    touchView.isHidden = on
    arView.isHidden = on
    if on {
      pause()
    } else {
      resume()
    }
  }

  func redraw() {
    if airMode { airView.redraw(engine: engine) } else { touchView.redraw() }
  }

  // MARK: Placement

  /// Put the shape's centre in front of the device, upright, facing it.
  func recenter() {
    let cam = engine.pose.frameTransform
    let position = SIMD3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
    let forward = -SIMD3(cam.columns.2.x, 0, cam.columns.2.z)
    let flat = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
    place(at: position + flat * Stage.placementDistance, facing: flat)
  }

  /// Rest the shape's base on the horizontal surface at the centre of the screen.
  @discardableResult
  func placeOnSurface() -> Bool {
    guard isAR, let shape = engine.shape else { return false }
    let centre = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
    guard let hit = arView.raycast(from: centre, allowing: .estimatedPlane, alignment: .horizontal).first else {
      return false
    }
    let cam = engine.pose.frameTransform
    let forward = -SIMD3(cam.columns.2.x, 0, cam.columns.2.z)
    let flat = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
    var p = SIMD3(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
    p.y -= shape.info.bbox_min.1
    place(at: p, facing: flat)
    return true
  }

  private func place(at p: SIMD3<Float>, facing forward: SIMD3<Float>) {
    // The shape's +z (its front) points back toward the user.
    let yaw = atan2(-forward.x, -forward.z)
    var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    m.columns.3 = SIMD4(p, 1)
    engine.shapeToWorld = m
    visualizer.setTransform(m)
    placed = true
    engine.update()
  }

  private func updateVirtualPose() {
    guard !isAR else { return }
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(0, 0, -virtualAdvance, 1)
    engine.pose.setPose(m, at: CACurrentMediaTime())
    virtualCamera?.transform = Transform(matrix: m)
    engine.update()
  }

  // MARK: ARSessionDelegate (main queue)

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    engine.pose.ingest(frame)
    if !placed, case .normal = frame.camera.trackingState { recenter() }
    engine.update()
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    switch camera.trackingState {
    case .normal: onTrackingChanged?(nil)
    case .notAvailable: onTrackingChanged?("Tracking unavailable")
    case .limited(let reason):
      switch reason {
      case .initializing: onTrackingChanged?("Starting tracking…")
      case .excessiveMotion: onTrackingChanged?("Moving too fast")
      case .insufficientFeatures: onTrackingChanged?("Too little detail in view")
      case .relocalizing: onTrackingChanged?("Relocalizing…")
      @unknown default: onTrackingChanged?("Tracking limited")
      }
    }
  }
}

/// Receives raw touches (no gesture recognizers, for the least delay) and
/// draws a ring under each finger.
final class TouchView: UIView {
  weak var engine: Engine?
  var showContact = false
  var showMidline = true
  private var rings: [ObjectIdentifier: (ring: CAShapeLayer, label: CATextLayer)] = [:]
  private let midline = CAShapeLayer()
  static let handColors = [UIColor(red: 0.18, green: 0.37, blue: 0.82, alpha: 1),
                           UIColor(red: 0.72, green: 0.20, blue: 0.42, alpha: 1)]
  static let noteNames = ["C", "D", "E", "G", "A"]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    backgroundColor = .clear
    // VoiceOver users: touches pass straight through to the app.
    isAccessibilityElement = true
    accessibilityLabel = "Shape exploration area"
    accessibilityTraits = .allowsDirectInteraction
    midline.strokeColor = UIColor.white.withAlphaComponent(0.3).cgColor
    midline.lineDashPattern = [2, 6]
    midline.lineWidth = 1
    layer.addSublayer(midline)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    engine?.touchesBegan(touches, in: self)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    engine?.touchesMoved(touches, in: self, event: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesEnded(touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { engine?.touchesEnded(touches) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let path = UIBezierPath()
    path.move(to: CGPoint(x: bounds.midX, y: 0))
    path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
    midline.path = path.cgPath
  }

  func redraw() {
    guard let engine else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    midline.isHidden = !(showMidline && engine.fingers.isEmpty)
    for id in rings.keys where engine.fingers[id] == nil {
      rings[id]!.ring.removeFromSuperlayer()
      rings[id]!.label.removeFromSuperlayer()
      rings[id] = nil
    }
    for (id, f) in engine.fingers {
      let entry = rings[id] ?? makeRing()
      rings[id] = entry
      let color = TouchView.handColors[f.hand]
      entry.ring.strokeColor = color.cgColor
      // Only reveal contact when the shape is shown.
      entry.ring.fillColor = showContact && f.probe.sdf <= 0 ? color.withAlphaComponent(0.4).cgColor : nil
      entry.ring.position = f.viewPoint
      entry.label.string = TouchView.noteNames[f.slot]
      entry.label.foregroundColor = color.cgColor
      entry.label.position = CGPoint(x: f.viewPoint.x, y: f.viewPoint.y - 48)
    }
    CATransaction.commit()
  }

  private func makeRing() -> (ring: CAShapeLayer, label: CATextLayer) {
    let r: CGFloat = 34
    let ring = CAShapeLayer()
    ring.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
    ring.lineWidth = 3
    let label = CATextLayer()
    label.fontSize = 15
    label.alignmentMode = .center
    label.contentsScale = window?.screen.scale ?? 3
    label.bounds = CGRect(x: 0, y: 0, width: 30, height: 20)
    layer.addSublayer(ring)
    layer.addSublayer(label)
    return (ring, label)
  }
}
