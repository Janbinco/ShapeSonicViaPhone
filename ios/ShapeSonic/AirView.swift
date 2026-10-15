// The overlay in "hands in the air" mode, over the ARView (which shows the
// front camera's picture and, when shown, the shape fixed in the world): a dot
// on each tracked fingertip in its hand's colour with its note, a status line,
// and, while the shape is shown, a readout of where the fingertips are
// relative to the shape. The picture is for the experimenter; the
// sonification doesn't depend on it.

import UIKit
import simd

final class AirView: UIView {
  var showContact = false
  private let statusLabel = UILabel()
  private let readout = UILabel()
  private var dots: [Int: (ring: CAShapeLayer, label: CATextLayer)] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    for label in [statusLabel, readout] {
      label.textColor = .white
      label.numberOfLines = 0
      label.textAlignment = .center
      label.shadowColor = UIColor.black.withAlphaComponent(0.6)
      label.shadowOffset = CGSize(width: 0, height: 1)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
    }
    statusLabel.font = .preferredFont(forTextStyle: .headline)
    readout.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
      statusLabel.bottomAnchor.constraint(equalTo: readout.topAnchor, constant: -8),
      readout.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
      readout.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
      readout.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
    isAccessibilityElement = true
    accessibilityLabel = "Hand tracking camera view"
  }

  required init?(coder: NSCoder) { fatalError() }

  func setStatus(_ text: String) {
    statusLabel.text = text
    accessibilityValue = text
  }

  /// `project`: world point -> point in this view (the ARView's projection).
  func redraw(engine: Engine, project: (SIMD3<Float>) -> CGPoint?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let keys = Set(engine.airTips.map { $0.hand * 8 + $0.slot })
    for key in dots.keys where !keys.contains(key) {
      dots[key]!.ring.removeFromSuperlayer()
      dots[key]!.label.removeFromSuperlayer()
      dots[key] = nil
    }
    for t in engine.airTips {
      let key = t.hand * 8 + t.slot
      let entry = dots[key] ?? makeDot()
      dots[key] = entry
      guard let p = project(t.world) else {
        entry.ring.isHidden = true
        entry.label.isHidden = true
        continue
      }
      let color = TouchView.handColors[t.hand]
      entry.ring.isHidden = false
      entry.label.isHidden = false
      entry.ring.position = p
      entry.ring.strokeColor = color.cgColor
      entry.ring.fillColor = showContact && t.probe.sdf <= 0 ? color.withAlphaComponent(0.6).cgColor : nil
      entry.label.string = TouchView.noteNames[t.slot]
      entry.label.foregroundColor = UIColor.white.cgColor
      entry.label.position = CGPoint(x: p.x, y: p.y - 24)
    }
    CATransaction.commit()

    // Readout: each hand's index fingertip (or any tip) relative to the shape's centre.
    guard showContact else {
      readout.text = nil
      return
    }
    var lines: [String] = []
    for hand in 0..<2 {
      let tips = engine.airTips.filter { $0.hand == hand }
      guard let t = tips.first(where: { $0.slot == 1 }) ?? tips.first else { continue }
      let p = engine.airLocal(t) * 100
      let inside = t.probe.sdf <= 0 ? "inside" : String(format: "%.0f cm out", t.probe.sdf * engine.airScale * 100)
      lines.append(String(format: "%@ %@  x %+5.1f  y %+5.1f  z %+5.1f cm  %@", hand == 0 ? "L" : "R",
                          TouchView.noteNames[t.slot], p.x, p.y, p.z, inside))
    }
    readout.text = lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  private func makeDot() -> (ring: CAShapeLayer, label: CATextLayer) {
    let r: CGFloat = 12
    let ring = CAShapeLayer()
    ring.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
    ring.lineWidth = 3
    let label = CATextLayer()
    label.fontSize = 13
    label.alignmentMode = .center
    label.contentsScale = window?.screen.scale ?? 3
    label.bounds = CGRect(x: 0, y: 0, width: 24, height: 18)
    layer.addSublayer(ring)
    layer.addSublayer(label)
    return (ring, label)
  }
}
