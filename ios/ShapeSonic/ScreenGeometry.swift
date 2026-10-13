// Physical screen geometry: where a touch is on the glass, in metres, in
// ARKit's camera frame.
//
// iOS has no API for the physical size of the screen, so the pixel density
// comes from a table of device models (with a manual override in the menu).
// Only the scale matters: the unknown offset between the camera lens and the
// screen centre is the same for every touch, so it acts like moving the hidden
// shape by a centimetre or two, which cannot be heard.

import UIKit
import simd

struct ScreenGeometry {
  let identifier: String
  let tablePPI: Double?
  var overridePPI: Double = 0

  init() {
    identifier = ScreenGeometry.machineIdentifier()
    tablePPI = ScreenGeometry.ppiTable[identifier]
  }

  var isIPad: Bool { identifier.hasPrefix("iPad") || UIDevice.current.userInterfaceIdiom == .pad }

  /// Physical pixels per inch.
  var ppi: Double {
    if overridePPI > 0 { return overridePPI }
    return tablePPI ?? (isIPad ? 264 : 460)
  }

  var isKnown: Bool { tablePPI != nil }

  /// Points per metre on `screen` (nativeScale = physical pixels per point; it
  /// accounts for Display Zoom and for downsampled panels).
  func pointsPerMetre(on screen: UIScreen) -> Double {
    ppi / Double(screen.nativeScale) / 0.0254
  }

  /// A point in the screen's fixed (portrait-up) coordinate space, as a point
  /// on the glass in ARKit camera coordinates. ARKit's camera frame has +x
  /// along the long axis toward the bottom of the device (the Home button),
  /// +y toward the right edge in portrait, and +z out of the screen.
  func cameraPoint(fixed p: CGPoint, on screen: UIScreen) -> SIMD3<Float> {
    let bounds = screen.fixedCoordinateSpace.bounds
    let ppm = pointsPerMetre(on: screen)
    let right = Double(p.x - bounds.midX) / ppm
    let down = Double(p.y - bounds.midY) / ppm
    return SIMD3(Float(down), Float(right), 0)
  }

  static func machineIdentifier() -> String {
    if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }

  /// Physical pixels per inch of ARKit-capable devices.
  static let ppiTable: [String: Double] = {
    var t: [String: Double] = [
      "iPhone11,2": 458, "iPhone11,4": 458, "iPhone11,6": 458, "iPhone11,8": 326,  // XS, XS Max, XR
      "iPhone12,1": 326, "iPhone12,3": 458, "iPhone12,5": 458, "iPhone12,8": 326,  // 11, 11 Pro (Max), SE 2
      "iPhone13,1": 476, "iPhone13,2": 460, "iPhone13,3": 460, "iPhone13,4": 458,  // 12 mini, 12, 12 Pro (Max)
      "iPhone14,4": 476, "iPhone14,5": 460, "iPhone14,2": 460, "iPhone14,3": 458,  // 13 mini, 13, 13 Pro (Max)
      "iPhone14,6": 326, "iPhone14,7": 460, "iPhone14,8": 458,                     // SE 3, 14, 14 Plus
      "iPhone15,2": 460, "iPhone15,3": 460, "iPhone15,4": 460, "iPhone15,5": 460,  // 14 Pro (Max), 15 (Plus)
      "iPhone16,1": 460, "iPhone16,2": 460,                                        // 15 Pro (Max)
      "iPhone17,1": 460, "iPhone17,2": 460, "iPhone17,3": 460, "iPhone17,4": 460, "iPhone17,5": 460,  // 16 family
      "iPhone18,1": 460, "iPhone18,2": 460, "iPhone18,3": 460, "iPhone18,4": 460,  // 17 family, Air
      // iPad mini models; other iPads are 264 ppi (the default).
      "iPad11,1": 326, "iPad11,2": 326, "iPad14,1": 326, "iPad14,2": 326, "iPad16,1": 326, "iPad16,2": 326,
    ]
    for id in ["iPad8,1", "iPad8,5", "iPad8,9", "iPad8,11", "iPad13,4", "iPad13,8", "iPad14,3", "iPad14,5",
               "iPad16,3", "iPad16,5", "iPad13,1", "iPad13,16", "iPad14,8", "iPad14,10", "iPad13,18", "iPad15,7"] {
      t[id] = 264
    }
    return t
  }()
}
