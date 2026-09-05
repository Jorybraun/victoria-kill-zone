#if canImport(SceneKit)
  import SceneKit
  import simd
  #if os(iOS)
    import UIKit
    private typealias AnatomyColor = UIColor
  #else
    import AppKit
    private typealias AnatomyColor = NSColor
  #endif

  /// Original procedural anatomy meshes, built once and retargeted as rigid
  /// parts. No downloaded assets, skin mesh, physics body, or collision geometry.
  @MainActor
  final class SkeletonAnatomyModel {
    let root = SCNNode()
    private let boneMaterial = SCNMaterial()
    private var parts: [SkeletonAnatomyPart: SCNNode] = [:]
    private static let lightingCategory = 1 << 4

    init() {
      root.name = "human-skeleton-anatomy"
      boneMaterial.lightingModel = .physicallyBased
      boneMaterial.roughness.contents = 0.58
      boneMaterial.metalness.contents = 0.04
      boneMaterial.isDoubleSided = true
      let cavity = SCNMaterial()
      cavity.lightingModel = .constant
      cavity.diffuse.contents = AnatomyColor(red: 0.025, green: 0.040, blue: 0.055, alpha: 1)
      cavity.isDoubleSided = true
      let materials = [boneMaterial, cavity]
      let geometry: [String: SCNGeometry] = [
        "skull": AnatomyMesh.skull().geometry(materials: materials),
        "ribs": AnatomyMesh.ribcage().geometry(materials: materials),
        "spine": AnatomyMesh.spine().geometry(materials: materials),
        "neck": AnatomyMesh.spine(vertebrae: 7).geometry(materials: materials),
        "pelvis": AnatomyMesh.pelvis().geometry(materials: materials),
        "single": AnatomyMesh.longBone(paired: false).geometry(materials: materials),
        "paired": AnatomyMesh.longBone(paired: true).geometry(materials: materials),
        "leftFemur": AnatomyMesh.femur(side: -1).geometry(materials: materials),
        "rightFemur": AnatomyMesh.femur(side: 1).geometry(materials: materials),
        "clavicle": AnatomyMesh.clavicle().geometry(materials: materials),
        "leftHand": AnatomyMesh.hand(side: 1).geometry(materials: materials),
        "rightHand": AnatomyMesh.hand(side: -1).geometry(materials: materials),
        "leftFoot": AnatomyMesh.foot(side: 1).geometry(materials: materials),
        "rightFoot": AnatomyMesh.foot(side: -1).geometry(materials: materials),
      ]
      for part in SkeletonAnatomyPart.allCases {
        let key: String
        switch part {
        case .skull: key = "skull"
        case .cervicalSpine: key = "neck"
        case .ribcage: key = "ribs"
        case .spine: key = "spine"
        case .pelvis: key = "pelvis"
        case .leftClavicle, .rightClavicle: key = "clavicle"
        case .leftThigh: key = "leftFemur"
        case .rightThigh: key = "rightFemur"
        case .leftHand: key = "leftHand"
        case .rightHand: key = "rightHand"
        case .leftFoot: key = "leftFoot"
        case .rightFoot: key = "rightFoot"
        case .leftForearm, .rightForearm, .leftShin, .rightShin: key = "paired"
        default: key = "single"
        }
        let node = SCNNode(geometry: geometry[key])
        node.name = part.rawValue
        node.categoryBitMask = Self.lightingCategory
        node.isHidden = true
        root.addChildNode(node)
        parts[part] = node
      }
      // These lights affect anatomy only, preserving the camera and tracer look.
      let ambient = SCNLight()
      ambient.type = .ambient
      ambient.intensity = 320
      ambient.categoryBitMask = Self.lightingCategory
      let ambientNode = SCNNode()
      ambientNode.light = ambient
      root.addChildNode(ambientNode)
      let key = SCNLight()
      key.type = .directional
      key.intensity = 1_100
      key.castsShadow = false
      key.categoryBitMask = Self.lightingCategory
      let keyNode = SCNNode()
      keyNode.eulerAngles = SCNVector3(-0.4, -0.65, 0)
      keyNode.light = key
      root.addChildNode(keyNode)
      updateTint(zone: nil)
    }

    func update(_ skeleton: TargetingSkeleton, zone: TargetingHitZone?) {
      updateTint(zone: zone)
      for node in parts.values { node.isHidden = true }
      for placement in SkeletonAnatomyLayout.placements(for: skeleton) {
        guard let node = parts[placement.part] else { continue }
        let x = SIMD3<Float>(placement.right * placement.size.x)
        let y = SIMD3<Float>(placement.up * placement.size.y)
        let z = SIMD3<Float>(placement.back * placement.size.z)
        let position = SIMD3<Float>(placement.position)
        node.simdTransform = simd_float4x4(columns: (
          SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0), SIMD4<Float>(position, 1)
        ))
        node.isHidden = false
      }
    }

    private func updateTint(zone: TargetingHitZone?) {
      let red: CGFloat = zone == .head ? 1 : 0.88
      let green: CGFloat = zone == .head ? 0.29 : 0.96
      let blue: CGFloat = zone == .head ? 0.16 : 1
      boneMaterial.diffuse.contents = AnatomyColor(red: red, green: green, blue: blue, alpha: 1)
      boneMaterial.emission.contents = AnatomyColor(red: red * 0.07, green: green * 0.07, blue: blue * 0.07, alpha: 1)
    }
  }

  /// Compact indexed meshes keep each anatomical part to one SceneKit node.
  private struct AnatomyMesh {
    private var vertices: [SCNVector3] = []
    private var normals: [SCNVector3] = []
    private var triangles: [[Int32]] = [[], []]

    func geometry(materials: [SCNMaterial]) -> SCNGeometry {
      let elements = triangles.filter { !$0.isEmpty }.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
      let result = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: elements)
      result.materials = materials
      return result
    }

    static func skull() -> AnatomyMesh {
      var mesh = AnatomyMesh()
      mesh.ellipsoid(center: SIMD3<Float>(0, 0.10, 0.04), radii: SIMD3<Float>(0.46, 0.46, 0.40))
      mesh.ellipsoid(center: SIMD3<Float>(0, -0.10, -0.30), radii: SIMD3<Float>(0.35, 0.27, 0.16))
      for side: Float in [-1, 1] {
        mesh.ellipsoid(center: SIMD3<Float>(side * 0.18, 0.045, -0.425), radii: SIMD3<Float>(0.125, 0.13, 0.055), material: 1)
        mesh.tube(points: [SIMD3<Float>(side * 0.055, 0.17, -0.43), SIMD3<Float>(side * 0.18, 0.19, -0.44),
          SIMD3<Float>(side * 0.32, 0.12, -0.38)], radius: 0.045)
        mesh.ellipsoid(center: SIMD3<Float>(side * 0.31, -0.105, -0.33), radii: SIMD3<Float>(0.07, 0.105, 0.065))
      }
      mesh.triangle(SIMD3<Float>(0, -0.055, -0.48), SIMD3<Float>(-0.065, -0.19, -0.465), SIMD3<Float>(0.065, -0.19, -0.465), material: 1)
      mesh.ellipsoid(center: SIMD3<Float>(0, -0.29, -0.395), radii: SIMD3<Float>(0.23, 0.064, 0.046), material: 1)
      mesh.tube(points: [SIMD3<Float>(-0.31, -0.10, -0.20), SIMD3<Float>(-0.31, -0.29, -0.25),
        SIMD3<Float>(-0.21, -0.43, -0.32), SIMD3<Float>(0, -0.47, -0.35),
        SIMD3<Float>(0.21, -0.43, -0.32), SIMD3<Float>(0.31, -0.29, -0.25),
        SIMD3<Float>(0.31, -0.10, -0.20)], radius: 0.055)
      for index in 0..<6 {
        let x = (Float(index) - 2.5) * 0.058
        mesh.ellipsoid(center: SIMD3<Float>(x, -0.25, -0.438), radii: SIMD3<Float>(0.026, 0.044, 0.027))
        mesh.ellipsoid(center: SIMD3<Float>(x, -0.355, -0.40), radii: SIMD3<Float>(0.026, 0.033, 0.028))
      }
      return mesh
    }

    static func ribcage() -> AnatomyMesh {
      var mesh = AnatomyMesh()
      for row in 0..<12 {
        let expansion = sin(Float(row + 1) / 13 * .pi)
        let radiusX: Float = 0.32 + expansion * 0.17
        let radiusZ: Float = 0.27 + expansion * 0.11
        let height: Float = 0.44 - Float(row) * 0.071
        for side: Float in [-1, 1] {
          let points = (0...14).map { index -> SIMD3<Float> in
            let angle = Float(index) / 14 * .pi * (row >= 10 ? 0.78 : 1)
            let progress = angle / .pi
            let bow = sin(angle)
            return SIMD3<Float>(side * sin(angle) * radiusX,
              height - progress * 0.19 - bow * bow * 0.065, cos(angle) * radiusZ)
          }
          mesh.tube(points: points, radius: 0.018)
        }
      }
      mesh.tube(points: [SIMD3<Float>(0, 0.29, -0.30), SIMD3<Float>(0, 0.10, -0.35),
        SIMD3<Float>(0, -0.10, -0.39), SIMD3<Float>(0, -0.32, -0.37), SIMD3<Float>(0, -0.47, -0.31)], radius: 0.033)
      mesh.ellipsoid(center: SIMD3<Float>(0, 0.26, -0.315), radii: SIMD3<Float>(0.065, 0.065, 0.042))
      return mesh
    }

    static func spine(vertebrae: Int = 17) -> AnatomyMesh {
      var mesh = AnatomyMesh()
      for index in 0..<vertebrae {
        let y = -0.47 + Float(index) / Float(vertebrae - 1) * 0.94
        mesh.ellipsoid(center: SIMD3<Float>(0, y, 0), radii: SIMD3<Float>(0.34, 0.43 / Float(vertebrae - 1), 0.30), latitude: 4, longitude: 8)
        mesh.ellipsoid(center: SIMD3<Float>(0, y, 0.08), radii: SIMD3<Float>(0.54, 0.13 / Float(vertebrae), 0.075), latitude: 4, longitude: 8)
        mesh.ellipsoid(center: SIMD3<Float>(0, y - 0.008, 0.37), radii: SIMD3<Float>(0.075, 0.15 / Float(vertebrae), 0.30), latitude: 4, longitude: 8)
      }
      return mesh
    }

    static func pelvis() -> AnatomyMesh {
      var mesh = AnatomyMesh()
      for side: Float in [-1, 1] {
        // Curved, flared iliac wings have a concave inner surface and a rounded
        // crest. This open bowl uses two thin surfaces, never a flat plate.
        func wing(_ u: Float, _ v: Float, thickness: Float = 0) -> SIMD3<Float> {
          let progress = (u + 1) / 2
          return SIMD3<Float>(side * (0.11 + sin(progress * .pi * 0.85) * (0.12 + 0.25 * v) + thickness),
            -0.10 + 0.50 * v - 0.075 * progress * progress, 0.28 - progress * (0.35 + 0.18 * v))
        }
        for row in 0..<6 {
          for column in 0..<8 {
            let u = Float(column) / 4 - 1
            let v = Float(row) / 6
            for thickness: Float in [0, 0.025] {
              let a = wing(u, v, thickness: thickness)
              let b = wing(u + 0.25, v, thickness: thickness)
              let c = wing(u, v + 1 / 6, thickness: thickness)
              let d = wing(u + 0.25, v + 1 / 6, thickness: thickness)
              mesh.triangle(a, b, c)
              mesh.triangle(b, d, c)
            }
          }
        }
        mesh.tube(points: (0...16).map { wing(Float($0) / 8 - 1, 1, thickness: 0.012) }, radius: 0.027)
        let ring = (0...16).map { index -> SIMD3<Float> in
          let angle = Float(index) / 16 * .pi * 2
          return SIMD3<Float>(side * 0.20 + cos(angle) * 0.17, -0.25 + sin(angle) * 0.21, -0.12 - sin(angle) * 0.08)
        }
        mesh.tube(points: ring, radius: 0.048)
        mesh.ellipsoid(center: SIMD3<Float>(side * 0.30, -0.04, -0.02), radii: SIMD3<Float>(0.08, 0.07, 0.10))
      }
      for index in 0..<5 {
        let taper = 1 - Float(index) * 0.15
        mesh.ellipsoid(center: SIMD3<Float>(0, 0.26 - Float(index) * 0.083, 0.25 - Float(index) * 0.018),
          radii: SIMD3<Float>(0.15 * taper, 0.053, 0.10 * taper), latitude: 4, longitude: 8)
      }
      mesh.tube(points: [SIMD3<Float>(-0.13, -0.42, -0.17), SIMD3<Float>(0, -0.38, -0.23), SIMD3<Float>(0.13, -0.42, -0.17)], radius: 0.047)
      return mesh
    }

    static func longBone(paired: Bool) -> AnatomyMesh {
      var mesh = AnatomyMesh()
      let offsets: [Float] = paired ? [-0.21, 0.21] : [0]
      for offset in offsets {
        mesh.tube(points: [SIMD3<Float>(offset * 0.6, -0.43, 0), SIMD3<Float>(offset, -0.12, 0.02),
          SIMD3<Float>(offset, 0.18, -0.01), SIMD3<Float>(offset * 0.65, 0.43, 0)], radius: paired ? 0.11 : 0.17)
        mesh.ellipsoid(center: SIMD3<Float>(offset * 0.6, -0.44, 0), radii: SIMD3<Float>(paired ? 0.18 : 0.35, 0.060, paired ? 0.18 : 0.30))
        for side: Float in [-1, 1] {
          mesh.ellipsoid(center: SIMD3<Float>(offset * 0.65 + side * (paired ? 0.07 : 0.16), 0.445, 0),
            radii: SIMD3<Float>(paired ? 0.12 : 0.22, 0.052, paired ? 0.16 : 0.26))
        }
      }
      return mesh
    }

    static func clavicle() -> AnatomyMesh {
      var mesh = AnatomyMesh()
      mesh.tube(points: [SIMD3<Float>(0, -0.49, 0), SIMD3<Float>(0.06, -0.27, -0.22),
        SIMD3<Float>(0.10, 0.01, -0.28), SIMD3<Float>(0.03, 0.25, -0.10), SIMD3<Float>(0, 0.49, 0)], radius: 0.12)
      for y: Float in [-0.47, 0.47] {
        mesh.ellipsoid(center: SIMD3<Float>(0, y, 0), radii: SIMD3<Float>(0.20, 0.035, 0.17), latitude: 4, longitude: 8)
      }
      return mesh
    }

    static func femur(side: Float) -> AnatomyMesh {
      var mesh = AnatomyMesh()
      mesh.ellipsoid(center: SIMD3<Float>(0, -0.46, 0), radii: SIMD3<Float>(0.30, 0.038, 0.30))
      mesh.tube(points: [SIMD3<Float>(0, -0.46, 0), SIMD3<Float>(side * 0.34, -0.38, 0),
        SIMD3<Float>(side * 0.24, -0.12, 0.04), SIMD3<Float>(side * 0.12, 0.22, 0.02),
        SIMD3<Float>(0, 0.43, 0)], radius: 0.16)
      mesh.ellipsoid(center: SIMD3<Float>(side * 0.35, -0.38, 0), radii: SIMD3<Float>(0.19, 0.045, 0.23))
      for offset: Float in [-0.20, 0.20] {
        mesh.ellipsoid(center: SIMD3<Float>(offset, 0.45, 0.035), radii: SIMD3<Float>(0.25, 0.049, 0.30))
      }
      // The patella is a visual kneecap attached to the measured knee end.
      mesh.ellipsoid(center: SIMD3<Float>(0, 0.45, -0.27), radii: SIMD3<Float>(0.26, 0.041, 0.13))
      return mesh
    }

    static func hand(side: Float) -> AnatomyMesh {
      var mesh = AnatomyMesh()
      for row in 0..<2 {
        for column in 0..<4 {
          mesh.ellipsoid(center: SIMD3<Float>((Float(column) - 1.5) * 0.15, -0.44 + Float(row) * 0.065, 0),
            radii: SIMD3<Float>(0.076, 0.034, 0.12), latitude: 4, longitude: 6)
        }
      }
      for finger in 0..<4 {
        let x = side * (0.26 - Float(finger) * 0.17)
        let knuckle = SIMD3<Float>(x, -0.07 - (finger == 3 ? 0.05 : 0), 0)
        mesh.digitBone(from: SIMD3<Float>(x * 0.75, -0.35, 0), to: knuckle,
          radius: 0.035, jointRadius: SIMD3<Float>(0.065, 0.024, 0.08))
        let fingerLength: Float = [0.43, 0.49, 0.455, 0.35][finger]
        var start = knuckle
        for fraction: Float in [0.44, 0.32, 0.24] {
          let end = start + SIMD3<Float>(side * (Float(finger) - 1) * -0.010, fingerLength * fraction, -0.025)
          mesh.digitBone(from: start, to: end, radius: 0.029,
            jointRadius: SIMD3<Float>(0.047, 0.018, 0.065))
          start = end
        }
      }
      let thumb = [SIMD3<Float>(side * 0.26, -0.34, 0), SIMD3<Float>(side * 0.43, -0.20, -0.045),
        SIMD3<Float>(side * 0.55, -0.065, -0.06), SIMD3<Float>(side * 0.59, 0.06, -0.08)]
      for index in 0..<3 {
        mesh.digitBone(from: thumb[index], to: thumb[index + 1], radius: 0.035,
          jointRadius: SIMD3<Float>(0.055, 0.021, 0.075))
      }
      return mesh
    }

    static func foot(side: Float) -> AnatomyMesh {
      var mesh = AnatomyMesh()
      mesh.ellipsoid(center: SIMD3<Float>(0, -0.08, 0.31), radii: SIMD3<Float>(0.23, 0.32, 0.18))
      mesh.ellipsoid(center: SIMD3<Float>(0, 0.20, 0.21), radii: SIMD3<Float>(0.23, 0.23, 0.10))
      for index in 0..<3 {
        mesh.ellipsoid(center: SIMD3<Float>((Float(index) - 1) * 0.18, 0.01, 0.075),
          radii: SIMD3<Float>(0.11, 0.20, 0.085), latitude: 4, longitude: 8)
      }
      for toe in 0..<5 {
        let x = side * (0.32 - Float(toe) * 0.145)
        let knuckleZ: Float = -0.21 + Float(toe) * 0.024
        mesh.digitBone(from: SIMD3<Float>(x * 0.63, 0.02, 0.05), to: SIMD3<Float>(x, -0.07, knuckleZ),
          radius: 0.043, jointRadius: SIMD3<Float>(0.065, 0.11, 0.026))
        var start = SIMD3<Float>(x, -0.07, knuckleZ)
        let count = toe == 0 ? 2 : 3
        let toeLength = Float(toe == 0 ? 0.20 : 0.18) - Float(toe) * 0.015
        for _ in 0..<count {
          let end = start + SIMD3<Float>(0, -0.017, -toeLength / Float(count))
          mesh.digitBone(from: start, to: end, radius: toe == 0 ? 0.047 : 0.030,
            jointRadius: SIMD3<Float>(toe == 0 ? 0.077 : 0.047, 0.077, 0.018))
          start = end
        }
      }
      return mesh
    }

    private mutating func digitBone(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float,
      jointRadius: SIMD3<Float>) {
      let span = end - start
      tube(points: [start + span * 0.12, end - span * 0.12], radius: radius)
      ellipsoid(center: start + span * 0.07, radii: jointRadius, latitude: 4, longitude: 6)
      ellipsoid(center: end - span * 0.07, radii: jointRadius, latitude: 4, longitude: 6)
    }

    private mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, material: Int = 0) {
      let normal = simd_normalize(simd_cross(b - a, c - a))
      let base = Int32(vertices.count)
      for point in [a, b, c] {
        vertices.append(SCNVector3(point.x, point.y, point.z))
        normals.append(SCNVector3(normal.x, normal.y, normal.z))
      }
      triangles[material].append(contentsOf: [base, base + 1, base + 2])
    }

    private mutating func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, material: Int = 0, latitude: Int = 7, longitude: Int = 12) {
      let base = Int32(vertices.count)
      for row in 0...latitude {
        let theta = Float(row) / Float(latitude) * .pi
        for column in 0...longitude {
          let phi = Float(column) / Float(longitude) * 2 * .pi
          let sphere = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
          let point = center + sphere * radii
          let normal = simd_normalize(sphere / radii)
          vertices.append(SCNVector3(point.x, point.y, point.z))
          normals.append(SCNVector3(normal.x, normal.y, normal.z))
        }
      }
      for row in 0..<latitude {
        for column in 0..<longitude {
          let a = base + Int32(row * (longitude + 1) + column)
          let b = a + 1
          let c = a + Int32(longitude + 1)
          triangles[material].append(contentsOf: [a, b, c, b, c + 1, c])
        }
      }
    }

    private mutating func tube(points: [SIMD3<Float>], radius: Float) {
      guard points.count >= 2 else { return }
      let sides = 5
      let base = Int32(vertices.count)
      for index in points.indices {
        let previous = points[max(0, index - 1)]
        let next = points[min(points.count - 1, index + 1)]
        let tangent = simd_normalize(next - previous)
        let reference = abs(tangent.y) < 0.85 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        let right = simd_normalize(simd_cross(tangent, reference))
        let up = simd_cross(right, tangent)
        for side in 0..<sides {
          let angle = Float(side) / Float(sides) * .pi * 2
          let normal = right * cos(angle) + up * sin(angle)
          let point = points[index] + normal * radius
          vertices.append(SCNVector3(point.x, point.y, point.z))
          normals.append(SCNVector3(normal.x, normal.y, normal.z))
        }
      }
      for index in 0..<(points.count - 1) {
        for side in 0..<sides {
          let a = base + Int32(index * sides + side)
          let b = base + Int32(index * sides + (side + 1) % sides)
          let c = a + Int32(sides)
          let d = b + Int32(sides)
          triangles[0].append(contentsOf: [a, c, b, b, c, d])
        }
      }
    }
  }
#endif
