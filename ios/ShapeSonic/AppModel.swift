// App state and actions behind the SwiftUI controls. Settings that a user
// would expect to persist are kept in UserDefaults.

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import simd

final class AppModel: ObservableObject {
  let pose = PoseProvider()
  let audio = AudioOutput()
  let haptics = Haptics()
  let tracker = HandTracker()
  let engine: Engine
  let stage: Stage

  struct Demo: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { name }
  }

  let demos: [Demo]
  /// Paper: "The threshold was tuned per model so output edges matched common sense."
  static let demoSharpAngles: [String: Float] = ["cat": 50]
  static let defaultSharpAngle: Float = 30

  @Published var showShape = true { didSet { applyVisibility() } }
  @Published var showFeatures = true { didSet { applyVisibility() } }
  @Published var handMode: HandMode {
    didSet {
      engine.handMode = handMode
      stage.touchView.showMidline = handMode == .split
      UserDefaults.standard.set(handMode.rawValue, forKey: "handMode")
    }
  }
  @Published var volume: Float {
    didSet {
      audio.setVolume(volume)
      UserDefaults.standard.set(volume, forKey: "volume")
    }
  }
  @Published var predictMotion: Bool {
    didSet {
      pose.predict = predictMotion
    haptics.enabled = vibrateOnCrossing
      UserDefaults.standard.set(predictMotion, forKey: "predictMotion")
    }
  }
  @Published var predictTouches: Bool {
    didSet {
      engine.usePredictedTouches = predictTouches
      UserDefaults.standard.set(predictTouches, forKey: "predictTouches")
    }
  }
  @Published var vibrateOnCrossing: Bool {
    didSet {
      haptics.enabled = vibrateOnCrossing
      UserDefaults.standard.set(vibrateOnCrossing, forKey: "vibrateOnCrossing")
    }
  }
  @Published var fitTo40cm = true
  @Published var sharpAngle: Float = AppModel.defaultSharpAngle
  @Published var ppiOverride: Double {
    didSet {
      engine.screenGeometry.overridePPI = ppiOverride
      UserDefaults.standard.set(ppiOverride, forKey: "ppiOverride")
    }
  }
  @Published var virtualAdvance: Float = 0 { didSet { stage.virtualAdvance = virtualAdvance } }

  // Hands in the air (front depth camera).
  /// "Touch the glass" is switched off for now: the app always runs hands in the air.
  static let glassModeAvailable = false
  @Published var inputMode: InputMode {
    didSet {
      UserDefaults.standard.set(inputMode.rawValue, forKey: "inputMode")
      applyInputMode()
    }
  }
  /// Distance from the front camera to the shape's centre (m).
  @Published var airDistance: Float {
    didSet {
      UserDefaults.standard.set(airDistance, forKey: "airDistance")
      placeAir()
    }
  }
  /// The shape's size (longest side, m) in air mode.
  @Published var airSize: Float {
    didSet {
      UserDefaults.standard.set(airSize, forKey: "airSize")
      placeAir()
    }
  }
  @Published var airSmoothing: Bool {
    didSet {
      engine.airSmoothing = airSmoothing
      UserDefaults.standard.set(airSmoothing, forKey: "airSmoothing")
    }
  }
  @Published private(set) var airStatus = HandTracker.Status.off
  /// The demo shapes are fitted to 40 cm; air mode scales them to airSize.
  static let fittedSize: Float = 0.4

  /// Only shown inside the menu, never on the main screen.
  @Published private(set) var shapeName: String?
  @Published private(set) var status = "Loading…"
  @Published private(set) var statusIsError = false
  @Published private(set) var loading = false
  @Published private(set) var tracking: String?
  @Published var surfaceMessage: String?

  private var started = false
  private var loadGeneration = 0

  init() {
    engine = Engine(pose: pose, audio: audio)
    stage = Stage(engine: engine)
    let d = UserDefaults.standard
    handMode = HandMode(rawValue: d.string(forKey: "handMode") ?? "") ?? .order
    volume = d.object(forKey: "volume") as? Float ?? 0.8
    predictMotion = d.object(forKey: "predictMotion") as? Bool ?? true
    predictTouches = d.bool(forKey: "predictTouches")
    vibrateOnCrossing = d.object(forKey: "vibrateOnCrossing") as? Bool ?? true
    ppiOverride = d.double(forKey: "ppiOverride")
    inputMode = AppModel.glassModeAvailable
      ? InputMode(rawValue: d.string(forKey: "inputMode") ?? "") ?? .glass : .air
    airDistance = d.object(forKey: "airDistance") as? Float ?? 0.30
    airSize = d.object(forKey: "airSize") as? Float ?? 0.20
    airSmoothing = d.object(forKey: "airSmoothing") as? Bool ?? true
    let dir = Bundle.main.url(forResource: "models", withExtension: nil)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir ?? URL(fileURLWithPath: "/"),
                                                              includingPropertiesForKeys: nil)) ?? []
    demos = files.filter { $0.pathExtension.lowercased() == "obj" }
      .map { Demo(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
      .sorted { $0.name < $1.name }

    engine.handMode = handMode
    engine.usePredictedTouches = predictTouches
    engine.screenGeometry.overridePPI = ppiOverride
    pose.predict = predictMotion
    haptics.enabled = vibrateOnCrossing
    stage.touchView.showMidline = handMode == .split
    engine.onFingersChanged = { [weak self] in self?.stage.redraw() }
    engine.airSmoothing = airSmoothing
    stage.tracker = tracker
    tracker.onHands = { [weak self] hands, time in
      guard let self, self.inputMode == .air else { return }
      self.engine.setAirHands(hands, time: time)
    }
    tracker.onStatus = { [weak self] status in
      guard let self else { return }
      self.airStatus = status
      self.updateAirStatus()
    }
    engine.onCrossing = { [weak self] finger, entered, time in
      self?.haptics.crossed(finger: finger, entered: entered, at: time)
    }
    pose.onMotionSample = { [weak self] in
      guard let self else { return }
      guard self.inputMode == .glass, self.pose.predict, !self.engine.fingers.isEmpty else { return }
      self.engine.update()
    }
    stage.onTrackingChanged = { [weak self] text in self?.tracking = text }
  }

  func start() {
    guard !started else { return }
    started = true
    audio.start()
    audio.setVolume(volume)
    pose.startMotion()
    applyInputMode()
    stage.start()
    UIApplication.shared.isIdleTimerDisabled = true
    if let demo = demos.first(where: { $0.name == "cube" }) ?? demos.first { select(demo) }
    if let error = audio.error { setStatus(error, error: true) }
  }

  func scenePhaseChanged(_ phase: ScenePhase) {
    switch phase {
    case .active:
      guard started else { return }
      stage.resume()
      pose.startMotion()
      haptics.start()
    case .background:
      stage.pause()
      pose.stopMotion()
      haptics.stop()
      engine.clearFingers()
      engine.setAirHands([], time: 0)
    default: break
    }
  }

  // MARK: Shapes

  func select(_ demo: Demo) {
    print("[ShapeSonic] select \(demo.name) (current: \(shapeName ?? "none"), loading: \(loading))")
    sharpAngle = AppModel.demoSharpAngles[demo.name] ?? AppModel.defaultSharpAngle
    load(url: demo.url, name: demo.name, fit: true)
  }

  func importFile(_ url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    // Copy out so the build can read it after access ends.
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
    try? FileManager.default.removeItem(at: local)
    do {
      try FileManager.default.copyItem(at: url, to: local)
    } catch {
      setStatus("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)", error: true)
      return
    }
    sharpAngle = AppModel.defaultSharpAngle
    load(url: local, name: url.deletingPathExtension().lastPathComponent, fit: fitTo40cm)
  }

  private func load(url: URL, name: String, fit: Bool) {
    loadGeneration += 1
    let generation = loadGeneration
    loading = true
    setStatus("Building \(name)…")
    let angle = sharpAngle
    let started = CACurrentMediaTime()
    print("[ShapeSonic] load #\(generation) \(name) started")
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try ShapeLoader.build(url: url, name: name, fit: fit, sharpAngle: angle) }
      let built = CACurrentMediaTime()
      DispatchQueue.main.async {
        let ms = { (t: CFTimeInterval) in Int((t - started) * 1000) }
        switch result {
        case .success: print("[ShapeSonic] load #\(generation) \(name) built in \(ms(built)) ms, on main at \(ms(CACurrentMediaTime())) ms")
        case .failure(let e): print("[ShapeSonic] load #\(generation) \(name) FAILED after \(ms(built)) ms: \(e.localizedDescription)")
        }
        guard generation == self.loadGeneration else {  // a newer load won
          print("[ShapeSonic] load #\(generation) \(name) discarded (newest is #\(self.loadGeneration))")
          return
        }
        self.loading = false
        switch result {
        case .success(let shape): self.install(shape)
        case .failure(let error): self.setStatus(error.localizedDescription, error: true)
        }
      }
    }
  }

  private func install(_ shape: Shape) {
    let t0 = CACurrentMediaTime()
    engine.shape = shape
    shapeName = shape.name
    stage.visualizer.setShape(shape, sharpAngle: sharpAngle)
    applyVisibility()
    updateStatus()
    print("[ShapeSonic] installed \(shape.name) in \(Int((CACurrentMediaTime() - t0) * 1000)) ms")
  }

  func sharpAngleCommitted() {
    guard let shape = engine.shape else { return }
    shape.detectFeatures(sharpAngle: sharpAngle)
    stage.visualizer.setFeatures(shape)
    engine.update()
    updateStatus()
  }

  // MARK: Placement

  func recenter() { stage.recenter() }

  // MARK: Hands in the air

  private func applyInputMode() {
    let air = inputMode == .air
    engine.inputMode = inputMode
    stage.setAirMode(air)
    if air {
      placeAir()  // waits for the first tracked frame if there is none yet
    } else {
      tracker.setStatus(.off)
      tracking = nil
    }
    updateAirStatus()
  }

  /// Air-mode distance and size; the shape is placed in the world (Stage) and
  /// stays there until recentred.
  func placeAir() {
    guard inputMode == .air else { return }
    let scale = airSize / AppModel.fittedSize
    engine.airScale = scale
    stage.airDistance = airDistance
    stage.airScale = scale
    stage.recenter()
  }

  private func updateAirStatus() {
    guard inputMode == .air else { return }
    var text = airStatus.text
    if case .running(let n) = airStatus, n == 0 {
      text += String(format: "\nHold your hands about %.0f cm from the screen.", airDistance * 100)
    }
    stage.airView.setStatus(text)
    if case .failed = airStatus { tracking = airStatus.text } else { tracking = nil }
  }

  func placeOnSurface() {
    surfaceMessage = stage.placeOnSurface() ? nil : "No horizontal surface found at the centre of the screen."
  }

  // MARK: Status

  private func applyVisibility() {
    stage.visualizer.setVisible(shape: showShape, features: showFeatures)
    stage.touchView.showContact = showShape
    stage.airView.showContact = showShape
    stage.redraw()
  }

  private func setStatus(_ text: String, error: Bool = false) {
    status = text
    statusIsError = error
  }

  private func updateStatus() {
    guard let shape = engine.shape else { return }
    let i = shape.info
    func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
    setStatus(
      "\(shape.name): \(plural(i.sharp_edge_count, "sharp edge")), \(plural(i.corner_count, "corner")). "
        + String(format: "SDF octree: %.1f MB, built in %.2f s.", Double(i.sdf_bytes) / 1e6, i.build_seconds)
        + (i.watertight != 0 ? "" : " Not watertight: inside/outside by ray parity."))
  }

  var latencyText: String {
    String(format: "Audio output latency: %.1f ms (I/O buffer %.1f ms)", audio.latency * 1000,
           AVAudioSession.sharedInstance().ioBufferDuration * 1000)
  }

  var screenText: String {
    let g = engine.screenGeometry
    return "\(g.identifier): \(Int(g.ppi)) ppi" + (g.isKnown || ppiOverride > 0 ? "" : " (guessed)")
  }

  static var importTypes: [UTType] {
    ShapeLoader.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.threeDContent]
  }
}
