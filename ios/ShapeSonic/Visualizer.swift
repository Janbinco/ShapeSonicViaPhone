// RealityKit visualization of the hidden shape, its sharp edges and corners.
// Hidden unless "Show shape" is on. It is never on the audio path.

import RealityKit
import UIKit
import simd

final class Visualizer {
  let anchor = AnchorEntity(world: matrix_identity_float4x4)
  private let shapeEntity = ModelEntity()
  private let edgeEntity = ModelEntity()
  private let cornerEntity = ModelEntity()
  private let rangeEntity = ModelEntity()

  var featureRange: Float = 0.02

  init() {
    for e in [shapeEntity, edgeEntity, cornerEntity, rangeEntity] { anchor.addChild(e) }
    anchor.isEnabled = false
  }

  func setVisible(shape: Bool, features: Bool) {
    anchor.isEnabled = shape
    for e in [edgeEntity, cornerEntity, rangeEntity] { e.isEnabled = features }
  }

  func setTransform(_ m: simd_float4x4) { anchor.transform = Transform(matrix: m) }

  func setShape(_ shape: Shape, sharpAngle: Float) {
    var b = MeshBuilder()
    b.addCreasedMesh(vertices: shape.vertices, triangles: shape.triangles, creaseAngle: sharpAngle)
    var material = PhysicallyBasedMaterial()
    material.baseColor = .init(tint: UIColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1))
    material.roughness = 0.7
    // Transparent triangles within one mesh are not sorted. If they wrote depth,
    // whichever were drawn first would hide the rest, which looks like a
    // patchwork of flipped triangles wherever the surface overlaps itself.
    // Without depth writes every layer blends, and since all triangles share
    // one colour the result does not depend on the order. The inward-facing
    // copy shows the far side (and the surface around you when inside) lit
    // correctly; both copies use ordinary back-face culling.
    if #available(iOS 18.0, *) {
      material.blending = .transparent(opacity: 0.3)
      material.writesDepth = false
      b.addInwardCopy()
    } else {
      material.blending = .transparent(opacity: 0.45)  // outer faces only
    }
    shapeEntity.model = b.resource().map { ModelComponent(mesh: $0, materials: [material]) }
    setFeatures(shape)
  }

  func setFeatures(_ shape: Shape) {
    var edges = MeshBuilder()
    for (a, b) in shape.sharpEdges { edges.addTube(a, b, radius: 0.0015) }
    edgeEntity.model = edges.resource().map {
      ModelComponent(mesh: $0, materials: [UnlitMaterial(color: UIColor(red: 0.82, green: 0.38, blue: 0.18, alpha: 1))])
    }
    var dots = MeshBuilder(), ranges = MeshBuilder()
    for c in shape.corners {
      dots.addSphere(c, radius: 0.004, segments: 8)
      ranges.addSphere(c, radius: featureRange, segments: 16)
    }
    cornerEntity.model = dots.resource().map {
      ModelComponent(mesh: $0, materials: [UnlitMaterial(color: .systemRed)])
    }
    var shell = UnlitMaterial(color: .systemRed)
    shell.blending = .transparent(opacity: 0.18)
    rangeEntity.model = ranges.resource().map { ModelComponent(mesh: $0, materials: [shell]) }
  }
}

/// Accumulates triangles into one MeshResource.
struct MeshBuilder {
  var positions: [SIMD3<Float>] = []
  var normals: [SIMD3<Float>] = []
  var indices: [UInt32] = []

  func resource() -> MeshResource? {
    guard !indices.isEmpty else { return nil }
    var d = MeshDescriptor()
    d.positions = MeshBuffers.Positions(positions)
    d.normals = MeshBuffers.Normals(normals)
    d.primitives = .triangles(indices)
    return try? MeshResource.generate(from: [d])
  }

  /// Smooth shading, except across edges sharper than creaseAngle.
  mutating func addCreasedMesh(vertices: [SIMD3<Float>], triangles: [UInt32], creaseAngle: Float) {
    let nt = triangles.count / 3
    var faceNormal = [SIMD3<Float>](repeating: .zero, count: nt)
    var incident = [[Int]](repeating: [], count: vertices.count)
    for f in 0..<nt {
      let a = vertices[Int(triangles[3 * f])], b = vertices[Int(triangles[3 * f + 1])], c = vertices[Int(triangles[3 * f + 2])]
      let n = simd_cross(b - a, c - a)
      faceNormal[f] = simd_length(n) > 0 ? simd_normalize(n) : .zero
      for k in 0..<3 { incident[Int(triangles[3 * f + k])].append(f) }
    }
    let cosCrease = cos(creaseAngle * .pi / 180)
    let base = UInt32(positions.count)
    for f in 0..<nt {
      for k in 0..<3 {
        let v = Int(triangles[3 * f + k])
        var n = SIMD3<Float>.zero
        for g in incident[v] where simd_dot(faceNormal[g], faceNormal[f]) >= cosCrease { n += faceNormal[g] }
        positions.append(vertices[v])
        normals.append(simd_length(n) > 0 ? simd_normalize(n) : faceNormal[f])
      }
      indices += [base + UInt32(3 * f), base + UInt32(3 * f + 1), base + UInt32(3 * f + 2)]
    }
  }

  /// Append every triangle again with reversed winding and normals.
  mutating func addInwardCopy() {
    let base = UInt32(positions.count)
    let count = indices.count
    positions += positions
    normals += normals.map { -$0 }
    for t in stride(from: 0, to: count, by: 3) {
      indices += [base + indices[t], base + indices[t + 2], base + indices[t + 1]]
    }
  }

  /// A square prism along a-b.
  mutating func addTube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius r: Float) {
    let axis = b - a
    guard simd_length(axis) > 0 else { return }
    let d = simd_normalize(axis)
    let helper: SIMD3<Float> = abs(d.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
    let u = simd_normalize(simd_cross(d, helper)) * r, w = simd_normalize(simd_cross(d, u)) * r
    let ring = [u, w, -u, -w]
    for i in 0..<4 {
      let o0 = ring[i], o1 = ring[(i + 1) % 4]
      let n = simd_normalize(o0 + o1)
      let s = UInt32(positions.count)
      positions += [a + o0, a + o1, b + o1, b + o0]
      normals += [n, n, n, n]
      indices += [s, s + 1, s + 2, s, s + 2, s + 3]
    }
  }

  mutating func addSphere(_ c: SIMD3<Float>, radius r: Float, segments: Int) {
    let rings = segments / 2
    let s = UInt32(positions.count)
    for i in 0...rings {
      let phi = Float(i) / Float(rings) * .pi
      for j in 0...segments {
        let theta = Float(j) / Float(segments) * 2 * .pi
        let n = SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
        positions.append(c + n * r)
        normals.append(n)
      }
    }
    let row = UInt32(segments + 1)
    for i in 0..<UInt32(rings) {
      for j in 0..<UInt32(segments) {
        let a = s + i * row + j, b = a + row
        indices += [a, a + 1, b, a + 1, b + 1, b]
      }
    }
  }
}
