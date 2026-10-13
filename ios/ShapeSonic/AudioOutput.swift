// Audio output: AVAudioEngine with one AVAudioSourceNode whose render block
// calls the core mixer. The I/O buffer is as short as the hardware allows
// (requested 3 ms), and level changes reach the mixer through atomics, so a
// touch is heard at the next hardware buffer.

import AVFoundation

final class AudioOutput {
  private let engine = AVAudioEngine()
  private var source: AVAudioSourceNode?
  private(set) var mixer: OpaquePointer?
  private(set) var running = false
  private(set) var error: String?

  private static let files: [(ss_sound, String)] = [
    (SS_SOUND_GUIDANCE, "guidance"),
    (SS_SOUND_CONTACT_LEFT, "contact-left"), (SS_SOUND_CONTACT_RIGHT, "contact-right"),
    (SS_SOUND_EDGE_LEFT, "edge-left"), (SS_SOUND_EDGE_RIGHT, "edge-right"),
    (SS_SOUND_CORNER_LEFT, "corner-left"), (SS_SOUND_CORNER_RIGHT, "corner-right"),
  ]

  deinit {
    engine.stop()
    if let mixer { ss_mixer_destroy(mixer) }
  }

  /// Output latency (hardware + I/O buffer) in seconds.
  var latency: TimeInterval {
    let s = AVAudioSession.sharedInstance()
    return s.outputLatency + s.ioBufferDuration
  }

  func start() {
    do {
      let session = AVAudioSession.sharedInstance()
      // .playback: sound even with the silent switch on.
      try session.setCategory(.playback, mode: .default)
      try session.setPreferredIOBufferDuration(0.003)
      try session.setActive(true)
      let rate = session.sampleRate
      let mixer = ss_mixer_create(rate)!
      self.mixer = mixer
      for (sound, name) in AudioOutput.files { try load(name, as: sound, into: mixer) }
      try connect(rate: rate)
      NotificationCenter.default.addObserver(
        self, selector: #selector(configurationChanged), name: .AVAudioEngineConfigurationChange, object: engine)
      NotificationCenter.default.addObserver(
        self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    } catch {
      self.error = "Audio: \(error.localizedDescription)"
    }
  }

  private func load(_ name: String, as sound: ss_sound, into mixer: OpaquePointer) throws {
    guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "audio") else {
      throw NSError(domain: "ShapeSonic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing audio/\(name).mp3"])
    }
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
    try file.read(into: buffer)
    guard let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    var pointers = (0..<channels).map { UnsafePointer(data[$0]) as UnsafePointer<Float>? }
    _ = ss_mixer_load(mixer, sound, &pointers, Int32(channels), Int(buffer.frameLength), buffer.format.sampleRate)
  }

  private func connect(rate: Double) throws {
    guard let mixer else { return }
    engine.stop()
    if let source { engine.detach(source) }
    ss_mixer_set_output_rate(mixer, rate)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    // The render block runs on the real-time audio thread: no allocation, no locks.
    let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
      guard buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData else { return noErr }
      ss_mixer_render(mixer, l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self),
                      Int(frameCount))
      return noErr
    }
    source = node
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    running = true
  }

  @objc private func configurationChanged() {
    // Route or sample-rate change (e.g. headphones plugged in).
    DispatchQueue.main.async { try? self.connect(rate: AVAudioSession.sharedInstance().sampleRate) }
  }

  @objc private func interrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
    DispatchQueue.main.async {
      try? AVAudioSession.sharedInstance().setActive(true)
      try? self.connect(rate: AVAudioSession.sharedInstance().sampleRate)
    }
  }

  func setLevels(_ levels: UnsafePointer<ss_hand_levels>) {
    if let mixer { ss_mixer_set_levels(mixer, levels) }
  }

  func setVolume(_ v: Float) {
    if let mixer { ss_mixer_set_master(mixer, v) }
  }

  func silence() {
    var quiet = [ss_hand_levels(), ss_hand_levels()]
    setLevels(&quiet)
  }
}
