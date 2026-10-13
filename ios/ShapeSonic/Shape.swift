// A built shape (owning the core's ss_shape), and loading it from files:
// OBJ through the core's own parser (shared with Android), and other formats
// (PLY, STL, USD/USDZ, Alembic) through ModelIO as a triangle soup.

import Foundation
import ModelIO
import simd

final class Shape: @unchecked Sendable {
  let ptr: OpaquePointer
  let name: String

  init(ptr: OpaquePointer, name: String) {
    self.ptr = ptr
    self.name = name
  }

  deinit { ss_shape_destroy(ptr) }

  var info: ss_shape_info {
    var i = ss_shape_info()
    ss_shape_get_info(ptr, &i)
    return i
  }

  func detectFeatures(sharpAngle: Float) { ss_shape_detect_features(ptr, sharpAngle) }

  var vertices: [SIMD3<Float>] {
    let n = info.vertex_count
    guard n > 0, let p = ss_shape_vertices(ptr) else { return [] }
    return (0..<n).map { SIMD3(p[3 * $0], p[3 * $0 + 1], p[3 * $0 + 2]) }
  }

  var triangles: [UInt32] {
    let n = info.triangle_count
    guard n > 0, let p = ss_shape_triangles(ptr) else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: 3 * n))
  }

  var sharpEdges: [(SIMD3<Float>, SIMD3<Float>)] {
    let n = info.sharp_edge_count
    guard n > 0, let p = ss_shape_sharp_edges(ptr) else { return [] }
    return (0..<n).map { i in
      (SIMD3(p[6 * i], p[6 * i + 1], p[6 * i + 2]), SIMD3(p[6 * i + 3], p[6 * i + 4], p[6 * i + 5]))
    }
  }

  var corners: [SIMD3<Float>] {
    let n = info.corner_count
    guard n > 0, let p = ss_shape_corners(ptr) else { return [] }
    return (0..<n).map { SIMD3(p[3 * $0], p[3 * $0 + 1], p[3 * $0 + 2]) }
  }
}

struct LoadError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum ShapeLoader {
  static let fileExtensions = ["obj", "ply", "stl", "usd", "usda", "usdc", "usdz", "abc"]

  /// Parse and build (SDF octree + features). Slow: call off the main thread.
  static func build(url: URL, name: String, fit: Bool, sharpAngle: Float) throws -> Shape {
    var err = [CChar](repeating: 0, count: 256)
    let raw: OpaquePointer?
    if url.pathExtension.lowercased() == "obj" {
      let data = try Data(contentsOf: url)
      raw = data.withUnsafeBytes { bytes in
        ss_shape_from_obj(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, &err, err.count)
      }
    } else {
      let (xyz, indices) = try triangleSoup(url: url)
      raw = ss_shape_from_triangles(xyz, xyz.count / 3, indices, indices.count / 3, &err, err.count)
    }
    guard let raw else { throw LoadError(message: String(cString: err)) }
    var options = ss_build_options()
    ss_build_options_default(&options)
    options.sharp_angle_deg = sharpAngle
    if !fit { options.fit_size = 0 }
    if ss_shape_build(raw, &options, &err, err.count) != 0 {
      ss_shape_destroy(raw)
      throw LoadError(message: String(cString: err))
    }
    return Shape(ptr: raw, name: name)
  }

  private static func triangleSoup(url: URL) throws -> ([Float], [UInt32]) {
    guard MDLAsset.canImportFileExtension(url.pathExtension) else {
      throw LoadError(message: "Can't read .\(url.pathExtension) files.")
    }
    let asset = MDLAsset(url: url)
    var xyz: [Float] = []
    var indices: [UInt32] = []
    for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
      guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3)
      else { continue }
      let m = MDLTransform.globalTransform(with: mesh, atTime: 0)
      let base = UInt32(xyz.count / 3)
      for i in 0..<mesh.vertexCount {
        let p = (positions.dataStart + i * positions.stride).assumingMemoryBound(to: Float.self)
        let v = m * SIMD4(p[0], p[1], p[2], 1)
        xyz += [v.x, v.y, v.z]
      }
      for case let sub as MDLSubmesh in mesh.submeshes ?? [] {
        let map = sub.indexBuffer(asIndexType: .uInt32).map()
        let idx = UnsafeBufferPointer(start: map.bytes.assumingMemoryBound(to: UInt32.self), count: sub.indexCount)
        switch sub.geometryType {
        case .triangles:
          indices += idx.map { base + $0 }
        case .quads:
          for q in stride(from: 0, to: idx.count - 3, by: 4) {
            indices += [idx[q], idx[q + 1], idx[q + 2], idx[q], idx[q + 2], idx[q + 3]].map { base + $0 }
          }
        case .variableTopology:
          guard let topology = sub.topology, let faces = topology.faceTopology else { continue }
          let counts = UnsafeBufferPointer(
            start: faces.map().bytes.assumingMemoryBound(to: UInt8.self), count: topology.faceCount)
          var start = 0
          for c in counts {
            let c = Int(c)
            for k in stride(from: 2, to: c, by: 1) where start + k < idx.count {
              indices += [idx[start], idx[start + k - 1], idx[start + k]].map { base + $0 }
            }
            start += c
          }
        default:
          continue
        }
      }
    }
    if indices.isEmpty { throw LoadError(message: "No triangles found in \(url.lastPathComponent).") }
    return (xyz, indices)
  }
}
