// "Hands in the air": fingertips from the front TrueDepth camera, in world
// coordinates.
//
// ARKit runs face tracking (front camera: colour + depth) with world tracking
// (back camera: where the device is). The shape is fixed in the world, as in
// "touch the glass"; only the fingertips come from the front camera instead of
// the screen. For each ARKit frame:
//   1. Vision finds up to two hands and their joints in the colour image;
//   2. the depth map gives each fingertip's distance (core: ss_fingertip_depth);
//   3. ARKit's intrinsics and camera pose for that frame turn pixel + depth
//      into a world point.
// The result goes to the main queue; Engine assigns hands, smooths and probes.
//
// ARKit's camera frame: +x along the image's rows (u), +y against its columns
// (-v), and the camera looks along -z. Its intrinsics are for capturedImage at
// imageResolution; the depth map covers the same field of view.

import ARKit
import ImageIO
import Vision
import simd

struct TrackedHand {
  struct Tip {
    var slot: Int  // 0 thumb, 1 index, 2 middle, 3 ring, 4 little: the pentatonic note
    var world: SIMD3<Float>  // metres, ARKit world frame
  }
  var tips: [Tip]
  var chirality: Int  // 0 left, 1 right, -1 unknown (as Vision reports it)
}

final class HandTracker {
  enum Status: Equatable {
    case off, starting, running(hands: Int), failed(String)
    var text: String {
      switch self {
      case .off: return "Camera off"
      case .starting: return "Starting the cameras…"
      case .running(let n):
        return n == 0 ? "Looking for hands…" : n == 1 ? "1 hand" : "\(n) hands"
      case .failed(let message): return message
      }
    }
  }

  /// Front depth camera together with world tracking (A12 and later with Face ID).
  static var isSupported: Bool {
    ARFaceTrackingConfiguration.isSupported && ARFaceTrackingConfiguration.supportsWorldTracking
  }

  /// Called on the main queue with the hands of each frame and its timestamp.
  var onHands: ((_ hands: [TrackedHand], _ time: TimeInterval) -> Void)?
  var onStatus: ((Status) -> Void)?

  private let queue = DispatchQueue(label: "ShapeSonic.hands", qos: .userInteractive)
  private let request: VNDetectHumanHandPoseRequest = {
    let r = VNDetectHumanHandPoseRequest()
    r.maximumHandCount = 2
    return r
  }()
  // Main queue.
  private var busy = false
  private var status = Status.off
  // `queue` only.
  private var lastDepth: DepthFrame?
  private var lastHandCount = -1

  /// Minimum Vision confidence for a fingertip to be used.
  static let minConfidence: Float = 0.3

  private static let fingers: [(tip: VNHumanHandPoseObservation.JointName, next: VNHumanHandPoseObservation.JointName)] = [
    (.thumbTip, .thumbIP), (.indexTip, .indexDIP), (.middleTip, .middleDIP), (.ringTip, .ringDIP),
    (.littleTip, .littleDIP),
  ]

  /// Main queue.
  func setStatus(_ s: Status) {
    guard s != status else { return }
    status = s
    onStatus?(s)
  }

  /// Main queue: forget the last depth map and hand count (session restarted).
  func reset() {
    queue.async {
      self.lastDepth = nil
      self.lastHandCount = -1
    }
  }

  // MARK: Frames

  private struct DepthFrame {
    let map: CVPixelBuffer  // DepthFloat32
    let width: Int, height: Int
  }

  /// What the tracking queue needs from an ARFrame (frames themselves are not retained).
  private struct FrameData {
    let image: CVPixelBuffer
    let depth: AVDepthData?
    let cameraToWorld: simd_float4x4
    let intrinsics: simd_float3x3
    let resolution: CGSize
    let time: TimeInterval
  }

  /// Main queue, for each ARKit frame. Frames arriving while one is being
  /// processed are skipped (keeping their depth for the next one).
  func process(_ frame: ARFrame) {
    let data = FrameData(image: frame.capturedImage, depth: frame.capturedDepthData,
                         cameraToWorld: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                         resolution: frame.camera.imageResolution, time: frame.timestamp)
    if busy {
      if let d = data.depth { queue.async { self.lastDepth = HandTracker.prepare(d) ?? self.lastDepth } }
      return
    }
    busy = true
    queue.async {
      let hands = self.track(data)
      DispatchQueue.main.async {
        self.busy = false
        if let hands { self.onHands?(hands, data.time) }
      }
    }
  }

  private static func prepare(_ data: AVDepthData) -> DepthFrame? {
    let depth = data.depthDataType == kCVPixelFormatType_DepthFloat32
      ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let map = depth.depthDataMap
    return DepthFrame(map: map, width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map))
  }

  /// `queue`. Nil until the first depth map arrives.
  private func track(_ f: FrameData) -> [TrackedHand]? {
    if let d = f.depth { lastDepth = HandTracker.prepare(d) ?? lastDepth }
    guard let depth = lastDepth else { return nil }

    // Show Vision the image with the world's up at the top, so hands are upright.
    // Image axes in the camera frame: right = +x, down = -y.
    let up = simd_transpose(f.cameraToWorld) * SIMD4<Float>(0, 1, 0, 0)
    let orientation: CGImagePropertyOrientation
    if up.y > 0.5 { orientation = .up }
    else if -up.x > 0.5 { orientation = .right }
    else if -up.y > 0.5 { orientation = .down }
    else { orientation = .left }

    let handler = VNImageRequestHandler(cvPixelBuffer: f.image, orientation: orientation, options: [:])
    do { try handler.perform([request]) } catch { return nil }
    let observations = request.results ?? []

    // Vision's normalized point (oriented image, bottom-left origin) -> image
    // coordinates (top-left origin, normalized).
    func toImage(_ p: CGPoint) -> CGPoint {
      switch orientation {
      case .up: return CGPoint(x: p.x, y: 1 - p.y)
      case .right: return CGPoint(x: 1 - p.y, y: 1 - p.x)
      case .down: return CGPoint(x: 1 - p.x, y: p.y)
      default: return CGPoint(x: p.y, y: p.x)  // .left
      }
    }

    let fx = f.intrinsics.columns.0.x, fy = f.intrinsics.columns.1.y
    let cx = f.intrinsics.columns.2.x, cy = f.intrinsics.columns.2.y
    let iw = Float(f.resolution.width), ih = Float(f.resolution.height)

    var hands: [TrackedHand] = []
    CVPixelBufferLockBaseAddress(depth.map, .readOnly)
    if let base = CVPixelBufferGetBaseAddress(depth.map) {
      let floats = base.assumingMemoryBound(to: Float.self)
      let stride = CVPixelBufferGetBytesPerRow(depth.map) / MemoryLayout<Float>.size
      let radius = max(1.5, Float(depth.width) * 0.006)
      for obs in observations {
        guard let points = try? obs.recognizedPoints(.all) else { continue }
        var tips: [TrackedHand.Tip] = []
        for (slot, finger) in HandTracker.fingers.enumerated() {
          guard let tip = points[finger.tip], tip.confidence >= HandTracker.minConfidence else { continue }
          let t = toImage(tip.location)
          var n = t
          if let next = points[finger.next], next.confidence >= 0.1 { n = toImage(next.location) }
          let z = ss_fingertip_depth(floats, Int32(depth.width), Int32(depth.height), stride,
                                     Float(t.x) * Float(depth.width), Float(t.y) * Float(depth.height),
                                     Float(n.x) * Float(depth.width), Float(n.y) * Float(depth.height), radius)
          guard z.isFinite, z > 0 else { continue }
          let u = Float(t.x) * iw, v = Float(t.y) * ih
          let camera = SIMD4<Float>((u - cx) / fx * z, -(v - cy) / fy * z, -z, 1)
          let w = f.cameraToWorld * camera
          tips.append(TrackedHand.Tip(slot: slot, world: SIMD3(w.x, w.y, w.z)))
        }
        guard !tips.isEmpty else { continue }
        let chirality: Int
        switch obs.chirality {
        case .left: chirality = 0
        case .right: chirality = 1
        default: chirality = -1
        }
        hands.append(TrackedHand(tips: tips, chirality: chirality))
      }
    }
    CVPixelBufferUnlockBaseAddress(depth.map, .readOnly)

    if hands.count != lastHandCount {
      lastHandCount = hands.count
      let n = hands.count
      DispatchQueue.main.async { self.setStatus(.running(hands: n)) }
    }
    return hands
  }
}
