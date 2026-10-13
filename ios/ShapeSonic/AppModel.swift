// App state and actions behind the SwiftUI controls. Settings that a user
// would expect to persist are kept in UserDefaults.

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
  let pose = PoseProvider()
  let audio = AudioOutput()
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

  @Published var showShape = false { didSet { applyVisibility() } }
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
      UserDefaults.standard.set(predictMotion, forKey: "predictMotion")
    }
  }
  @Published var predictTouches: Bool {
    didSet {
      engine.usePredictedTouches = predictTouches
      UserDefaults.standard.set(predictTouches, forKey: "predictTouches")
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
    handMode = HandMode(rawValue: d.string(forKey: "handMode") ?? "") ?? .split
    volume = d.object(forKey: "volume") as? Float ?? 0.8
    predictMotion = d.object(forKey: "predictMotion") as? Bool ?? true
    predictTouches = d.bool(forKey: "predictTouches")
    ppiOverride = d.double(forKey: "ppiOverride")
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
    stage.touchView.showMidline = handMode == .split
    engine.onFingersChanged = { [weak self] in self?.stage.touchView.redraw() }
    pose.onMotionSample = { [weak self] in
      guard let self, self.pose.predict, !self.engine.fingers.isEmpty else { return }
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
    stage.start()
    UIApplication.shared.isIdleTimerDisabled = true
    if let demo = demos.first(where: { $0.name == "cube" }) ?? demos.first { select(demo) }
    if let error = audio.error { setStatus(error, error: true) }
  }

  func scenePhaseChanged(_ phase: ScenePhase) {
    switch phase {
    case .active:
      stage.resume()
      pose.startMotion()
    case .background:
      stage.pause()
      pose.stopMotion()
      engine.clearFingers()
    default: break
    }
  }

  // MARK: Shapes

  func select(_ demo: Demo) {
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
    DispatchQueue.global(qos: .userInitiated).async {
      let result = Result { try ShapeLoader.build(url: url, name: name, fit: fit, sharpAngle: angle) }
      DispatchQueue.main.async {
        guard generation == self.loadGeneration else { return }  // a newer load won
        self.loading = false
        switch result {
        case .success(let shape): self.install(shape)
        case .failure(let error): self.setStatus(error.localizedDescription, error: true)
        }
      }
    }
  }

  private func install(_ shape: Shape) {
    engine.shape = shape
    shapeName = shape.name
    stage.visualizer.setShape(shape, sharpAngle: sharpAngle)
    applyVisibility()
    updateStatus()
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

  func placeOnSurface() {
    surfaceMessage = stage.placeOnSurface() ? nil : "No horizontal surface found at the centre of the screen."
  }

  // MARK: Status

  private func applyVisibility() {
    stage.visualizer.setVisible(shape: showShape, features: showFeatures)
    stage.touchView.showContact = showShape
    stage.touchView.redraw()
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
