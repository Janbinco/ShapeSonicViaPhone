// A tap whenever a fingertip crosses the surface: sharper going in (contact),
// softer coming out. Core Haptics with the engine kept running, so a tap is
// sent at the same moment the contact sound switches. Devices without a
// Taptic Engine (iPads) have no haptics.

import CoreHaptics

final class Haptics {
  let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
  var enabled = true
  private var engine: CHHapticEngine?
  private var enter: CHHapticPattern?
  private var exit: CHHapticPattern?
  private var last: [ObjectIdentifier: CFTimeInterval] = [:]
  /// A finger hovering on the surface can cross back and forth every update
  /// (tracking noise); closer taps than this are dropped.
  static let minInterval: CFTimeInterval = 0.04

  init() {
    guard isSupported else { return }
    enter = try? Haptics.tap(intensity: 1.0, sharpness: 0.9)
    exit = try? Haptics.tap(intensity: 0.55, sharpness: 0.4)
    start()
  }

  private static func tap(intensity: Float, sharpness: Float) throws -> CHHapticPattern {
    let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
      CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
      CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
    ], relativeTime: 0)
    return try CHHapticPattern(events: [event], parameters: [])
  }

  func start() {
    guard isSupported else { return }
    do {
      let engine = try CHHapticEngine()
      engine.playsHapticsOnly = true
      engine.isAutoShutdownEnabled = false  // stay ready: no spin-up delay
      engine.resetHandler = { [weak self] in self?.start() }
      engine.stoppedHandler = { [weak self] _ in DispatchQueue.main.async { self?.engine = nil } }
      try engine.start()
      self.engine = engine
    } catch {
      engine = nil
    }
  }

  func stop() {
    engine?.stop()
    engine = nil
  }

  /// A finger crossed the surface (entered = now inside).
  func crossed(finger: ObjectIdentifier, entered: Bool, at now: CFTimeInterval) {
    guard enabled, isSupported else { return }
    if let t = last[finger], now - t < Haptics.minInterval { return }
    last[finger] = now
    if last.count > 32 { last = last.filter { now - $0.value < 1 } }
    if engine == nil { start() }
    guard let engine, let pattern = entered ? enter : exit else { return }
    try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
  }
}
