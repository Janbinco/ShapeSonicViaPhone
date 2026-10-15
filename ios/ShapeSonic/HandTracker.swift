// "Hands in the air": fingertips from the front TrueDepth camera.
//
// The device stays still (standing, or lying on a table) and looks at the
// user's hands. Each camera frame:
//   1. Vision finds up to two hands and their joints in the colour image;
//   2. the depth map gives each fingertip's distance (core: ss_fingertip_depth);
//   3. the camera intrinsics turn pixel + depth into a 3D point
//      (ss_unproject), which is rotated into the device frame.
// The result goes to the main queue; Engine assigns hands, smooths and probes.
//
// Device frame (CoreMotion's): +x right (portrait), +y top, +z out of the
// screen, toward the user; the origin is the front camera.
//
// The colour and depth buffers are used as the sensor delivers them (no
// rotation; mirroring switched off), so the intrinsics apply directly. Their
// axes in the device frame are `bufferRight` and `bufferDown`; the default is
// for an unmirrored front camera, and the menu can rotate or mirror it if a
// device differs (see DESIGN.md, "Hands in the air").

import AVFoundation
import ImageIO
import Vision
import simd

struct TrackedHand {
  struct Tip {
    var slot: Int  // 0 thumb, 1 index, 2 middle, 3 ring, 4 little: the pentatonic note
    var device: SIMD3<Float>  // metres, device frame
    var image: CGPoint  // normalized sensor-buffer coordinates, top-left origin (for drawing)
  }
  var tips: [Tip]
  var chirality: Int  // 0 left, 1 right, -1 unknown (as Vision reports it)
}

final class HandTracker: NSObject, AVCaptureDataOutputSynchronizerDelegate {
  struct Calibration: Equatable {
    var quarterTurns = 0  // rotate the buffer axes about the optical axis
    var mirrored = false
  }

  enum Status: Equatable {
    case off, starting, running(hands: Int), failed(String)
    var text: String {
      switch self {
      case .off: return "Camera off"
      case .starting: return "Starting the front camera…"
      case .running(let n):
        return n == 0 ? "Looking for hands…" : n == 1 ? "1 hand" : "\(n) hands"
      case .failed(let message): return message
      }
    }
  }

  static var isSupported: Bool {
    AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
  }

  let session = AVCaptureSession()
  /// Called on the main queue with the hands of each frame and its timestamp.
  var onHands: ((_ hands: [TrackedHand], _ time: TimeInterval) -> Void)?
  var onStatus: ((Status) -> Void)?
  private(set) var device: AVCaptureDevice?

  private let queue = DispatchQueue(label: "ShapeSonic.hands", qos: .userInteractive)
  private let videoOutput = AVCaptureVideoDataOutput()
  private let depthOutput = AVCaptureDepthDataOutput()
  private var synchronizer: AVCaptureDataOutputSynchronizer?
  private var configured = false
  private var lastDepth: DepthFrame?
  private let request: VNDetectHumanHandPoseRequest = {
    let r = VNDetectHumanHandPoseRequest()
    r.maximumHandCount = 2
    return r
  }()
  // Accessed on `queue` only.
  private var calibration = Calibration()
  private var lastHandCount = -1

  /// Minimum Vision confidence for a fingertip to be used.
  static let minConfidence: Float = 0.3

  private static let fingers: [(tip: VNHumanHandPoseObservation.JointName, next: VNHumanHandPoseObservation.JointName)] = [
    (.thumbTip, .thumbIP), (.indexTip, .indexDIP), (.middleTip, .middleDIP), (.ringTip, .ringDIP),
    (.littleTip, .littleDIP),
  ]

  func setCalibration(_ c: Calibration) {
    queue.async { self.calibration = c }
  }

  func start() {
    report(.starting)
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      queue.async { self.startOnQueue() }
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted {
          self.queue.async { self.startOnQueue() }
        } else {
          self.report(.failed("Camera access is off. Allow it in Settings › ShapeSonic."))
        }
      }
    default:
      report(.failed("Camera access is off. Allow it in Settings › ShapeSonic."))
    }
  }

  func stop() {
    queue.async {
      if self.session.isRunning { self.session.stopRunning() }
      self.lastDepth = nil
      self.lastHandCount = -1
      self.report(.off)
    }
  }

  private func report(_ status: Status) {
    DispatchQueue.main.async { self.onStatus?(status) }
  }

  // MARK: Session

  private func startOnQueue() {
    if !configured {
      if let error = configure() {
        report(.failed(error))
        return
      }
      configured = true
    }
    if !session.isRunning { session.startRunning() }
    lastHandCount = -1
  }

  /// Returns an error message, or nil on success.
  private func configure() -> String? {
    guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
      return "This device has no TrueDepth (Face ID) camera."
    }
    self.device = device
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .vga640x480
    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else { return "Can't use the front camera." }
      session.addInput(input)
    } catch {
      return "Can't open the front camera: \(error.localizedDescription)"
    }
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    guard session.canAddOutput(videoOutput) else { return "Can't read the camera's video." }
    session.addOutput(videoOutput)
    depthOutput.isFilteringEnabled = true  // fills holes, smooths over time
    depthOutput.alwaysDiscardsLateDepthData = true
    guard session.canAddOutput(depthOutput) else { return "Can't read the camera's depth." }
    session.addOutput(depthOutput)
    depthOutput.connection(with: .depthData)?.isEnabled = true

    // Buffers exactly as the sensor sees them: unmirrored, unrotated.
    for connection in [videoOutput.connection(with: .video), depthOutput.connection(with: .depthData)] {
      guard let connection else { continue }
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
      }
    }

    // The highest-resolution depth format.
    let formats = device.activeFormat.supportedDepthDataFormats.filter {
      let t = CMFormatDescriptionGetMediaSubType($0.formatDescription)
      return t == kCVPixelFormatType_DepthFloat32 || t == kCVPixelFormatType_DepthFloat16
    }
    let best = formats.max {
      CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
        < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
    }
    do {
      try device.lockForConfiguration()
      if let best { device.activeDepthDataFormat = best }
      device.unlockForConfiguration()
    } catch {
      return "Can't configure the depth camera: \(error.localizedDescription)"
    }

    let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
    sync.setDelegate(self, queue: queue)
    synchronizer = sync
    return nil
  }

  // MARK: Frames

  private struct DepthFrame {
    let map: CVPixelBuffer  // DepthFloat32
    let width: Int, height: Int
    let intrinsics: ss_intrinsics
  }

  private func prepare(_ data: AVDepthData) -> DepthFrame? {
    let depth = data.depthDataType == kCVPixelFormatType_DepthFloat32
      ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    let map = depth.depthDataMap
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
    var k: ss_intrinsics
    if let cal = depth.cameraCalibrationData {
      let m = cal.intrinsicMatrix
      let ref = cal.intrinsicMatrixReferenceDimensions
      let sx = Float(w) / Float(ref.width), sy = Float(h) / Float(ref.height)
      k = ss_intrinsics(fx: m.columns.0.x * sx, fy: m.columns.1.y * sy, cx: m.columns.2.x * sx, cy: m.columns.2.y * sy)
    } else {
      // No calibration: a pinhole from the field of view.
      let fov = (device?.activeFormat.videoFieldOfView ?? 60) * .pi / 180
      let f = Float(max(w, h)) / 2 / tan(fov / 2)
      k = ss_intrinsics(fx: f, fy: f, cx: Float(w) / 2, cy: Float(h) / 2)
    }
    return DepthFrame(map: map, width: w, height: h, intrinsics: k)
  }

  func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                              didOutput collection: AVCaptureSynchronizedDataCollection) {
    if let d = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData, !d.depthDataWasDropped {
      lastDepth = prepare(d.depthData)
    }
    guard let v = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
          !v.sampleBufferWasDropped, let pixels = CMSampleBufferGetImageBuffer(v.sampleBuffer),
          let depth = lastDepth else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(v.sampleBuffer).seconds

    // Buffer axes in the device frame.
    var right = SIMD3<Float>(0, -1, 0), down = SIMD3<Float>(1, 0, 0)
    for _ in 0..<((calibration.quarterTurns % 4 + 4) % 4) {
      right = SIMD3(-right.y, right.x, right.z)
      down = SIMD3(-down.y, down.x, down.z)
    }
    if calibration.mirrored { right = -right }
    let forward = SIMD3<Float>(0, 0, 1)

    // Show Vision the image with the device's top up, so hands are upright.
    let up = SIMD3<Float>(0, 1, 0)
    let orientation: CGImagePropertyOrientation
    if simd_dot(-down, up) > 0.5 { orientation = .up }
    else if simd_dot(-right, up) > 0.5 { orientation = .right }
    else if simd_dot(down, up) > 0.5 { orientation = .down }
    else { orientation = .left }

    let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
    do { try handler.perform([request]) } catch { return }
    let observations = request.results ?? []

    // Vision's normalized point (oriented image, bottom-left origin) -> buffer
    // coordinates (top-left origin, normalized).
    func toBuffer(_ p: CGPoint) -> CGPoint {
      switch orientation {
      case .up: return CGPoint(x: p.x, y: 1 - p.y)
      case .right: return CGPoint(x: 1 - p.y, y: 1 - p.x)
      case .down: return CGPoint(x: 1 - p.x, y: p.y)
      default: return CGPoint(x: p.y, y: p.x)  // .left
      }
    }

    var hands: [TrackedHand] = []
    CVPixelBufferLockBaseAddress(depth.map, .readOnly)
    if let base = CVPixelBufferGetBaseAddress(depth.map) {
      let floats = base.assumingMemoryBound(to: Float.self)
      let stride = CVPixelBufferGetBytesPerRow(depth.map) / MemoryLayout<Float>.size
      let radius = max(1.5, Float(depth.width) * 0.006)
      var k = depth.intrinsics
      for obs in observations {
        guard let points = try? obs.recognizedPoints(.all) else { continue }
        var tips: [TrackedHand.Tip] = []
        for (slot, finger) in HandTracker.fingers.enumerated() {
          guard let tip = points[finger.tip], tip.confidence >= HandTracker.minConfidence else { continue }
          let t = toBuffer(tip.location)
          var n = t
          if let next = points[finger.next], next.confidence >= 0.1 { n = toBuffer(next.location) }
          let tu = Float(t.x) * Float(depth.width), tv = Float(t.y) * Float(depth.height)
          let nu = Float(n.x) * Float(depth.width), nv = Float(n.y) * Float(depth.height)
          let z = ss_fingertip_depth(floats, Int32(depth.width), Int32(depth.height), stride, tu, tv, nu, nv, radius)
          guard z.isFinite else { continue }
          var c: [Float] = [0, 0, 0]
          ss_unproject(&k, tu, tv, z, &c)
          let p = c[0] * right + c[1] * down + c[2] * forward
          tips.append(TrackedHand.Tip(slot: slot, device: p, image: t))
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
      report(.running(hands: hands.count))
    }
    DispatchQueue.main.async { self.onHands?(hands, time) }
  }
}
