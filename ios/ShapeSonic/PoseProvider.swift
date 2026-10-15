// Device pose for the current instant.
//
// ARKit delivers the camera pose once per camera frame (60 Hz), for the moment
// the frame was captured, and a frame or two after that. To hear the shape
// where the phone is *now*, the pose is extrapolated: rotation by integrating
// the fused gyroscope rate (CoreMotion, up to 200 Hz) since the frame's
// timestamp, and translation by the velocity of the last frames. Each motion
// sample also re-runs the probe, so a finger held still on the glass is heard
// moving through the shape as the phone moves.

import ARKit
import CoreMotion
import simd

final class PoseProvider {
  /// ARKit pose at the last frame (world from camera).
  private(set) var frameTransform = matrix_identity_float4x4
  private(set) var frameTime: TimeInterval = 0
  private(set) var hasPose = false
  var predict = true
  /// Called on the main queue for each motion sample.
  var onMotionSample: (() -> Void)?
  /// Gravity in CoreMotion's device frame (+x right, +y top, +z out of the
  /// screen), in g; nil until the first motion sample.
  private(set) var gravity: SIMD3<Float>?

  private var velocity = SIMD3<Float>(repeating: 0)
  private var lastPosition: SIMD3<Float>?
  private var lastTime: TimeInterval = 0
  private var gyro: [(t: TimeInterval, w: SIMD3<Float>)] = []  // camera-frame rates, newest last
  private let motion = CMMotionManager()

  static let maxExtrapolation: TimeInterval = 0.05

  func startMotion() {
    guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
    motion.deviceMotionUpdateInterval = 1.0 / 200
    motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
      guard let self, let data else { return }
      // CoreMotion's device frame: +x right (portrait), +y top, +z out of the screen.
      // ARKit's camera frame: +x toward the bottom, +y right, +z out of the screen.
      self.gravity = SIMD3(Float(data.gravity.x), Float(data.gravity.y), Float(data.gravity.z))
      let r = data.rotationRate
      self.gyro.append((data.timestamp, SIMD3(Float(-r.y), Float(r.x), Float(r.z))))
      if self.gyro.count > 64 { self.gyro.removeFirst(self.gyro.count - 64) }
      self.onMotionSample?()
    }
  }

  func stopMotion() { motion.stopDeviceMotionUpdates() }

  func ingest(_ frame: ARFrame) {
    let m = frame.camera.transform
    let p = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    if case .normal = frame.camera.trackingState, let last = lastPosition, frame.timestamp > lastTime {
      let v = (p - last) / Float(frame.timestamp - lastTime)
      velocity = simd_mix(velocity, v, SIMD3(repeating: 0.5))
    } else {
      velocity = .zero
    }
    lastPosition = p
    lastTime = frame.timestamp
    setPose(m, at: frame.timestamp)
  }

  /// For the non-AR (simulator) mode.
  func setPose(_ m: simd_float4x4, at t: TimeInterval) {
    frameTransform = m
    frameTime = t
    hasPose = true
  }

  /// World-from-camera transform at time `now` (same clock as ARFrame.timestamp).
  func transform(at now: TimeInterval) -> simd_float4x4 {
    guard predict, hasPose, now > frameTime else { return frameTransform }
    // Rotation: integrate body rates after the frame (dR/dt = R [w]x).
    var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    var t = frameTime
    var lastRate = SIMD3<Float>(repeating: 0)
    for s in gyro where s.t > frameTime && s.t <= now + 0.005 {
      q = q * PoseProvider.rotation(s.w, dt: min(s.t - t, 0.02))
      t = s.t
      lastRate = s.w
    }
    if now > t { q = q * PoseProvider.rotation(lastRate, dt: min(now - t, 0.01)) }
    var m = frameTransform * simd_float4x4(q)
    let dt = Float(min(now - frameTime, PoseProvider.maxExtrapolation))
    m.columns.3 = SIMD4(frameTransform.columns.3.x + velocity.x * dt, frameTransform.columns.3.y + velocity.y * dt,
                        frameTransform.columns.3.z + velocity.z * dt, 1)
    return m
  }

  private static func rotation(_ w: SIMD3<Float>, dt: TimeInterval) -> simd_quatf {
    let angle = simd_length(w) * Float(max(dt, 0))
    guard angle > 1e-7 else { return simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
    return simd_quatf(angle: angle, axis: simd_normalize(w))
  }
}
