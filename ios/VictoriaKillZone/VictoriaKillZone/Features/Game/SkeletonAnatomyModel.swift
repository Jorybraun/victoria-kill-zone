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

  /// Retargets the bundled BodyParts3D anatomical mesh. Geometry, material and
  /// source-bind inverses are cached before combat; updates only place pooled
  /// nodes. This cosmetic template has no collision or tracking ownership.
  @MainActor
  final class SkeletonAnatomyModel {
    let root = SCNNode()
    let geometryLoaded: Bool
    private var parts: [SkeletonAnatomyPart: SCNNode] = [:]
    private var inverseBinds: [SkeletonAnatomyPart: simd_float4x4] = [:]
    private var previous: [SkeletonAnatomyPart: SkeletonAnatomyPlacement] = [:]
    private static let lightingCategory = 1 << 4
    private static let material: SCNMaterial = {
      let result = SCNMaterial()
      result.name = "anatomical-ivory"
      result.lightingModel = .physicallyBased
      result.diffuse.contents = AnatomyColor(red: 0.847, green: 0.835, blue: 0.784, alpha: 1)
      result.roughness.contents = 0.70
      result.metalness.contents = 0
      result.emission.contents = AnatomyColor(red: 0.032, green: 0.036, blue: 0.039, alpha: 1)
      result.isDoubleSided = false
      result.shaderModifiers = [.surface: """
        float anatomicalRim = pow(1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view))), 3.0);
        _surface.emission.rgb += anatomicalRim * float3(0.055, 0.095, 0.11);
        """]
      return result
    }()

    init(assetParts: [SkeletonMeshAsset.Part]? = nil) {
      let assetParts = assetParts ?? SkeletonMeshAsset.bundled
      root.name = "human-skeleton-anatomy"
      let names = Set(assetParts.map(\.name))
      geometryLoaded = assetParts.count == SkeletonAnatomyPart.allCases.count
        && names == Set(SkeletonAnatomyPart.allCases.map(\.rawValue))
        && assetParts.allSatisfy { SkeletonMeshAsset.validBind($0.bindTransform) }
      guard geometryLoaded else { return }
      for asset in assetParts {
        guard let part = SkeletonAnatomyPart(rawValue: asset.name) else { continue }
        // These immutable resources are shared by every skeleton instance.
        asset.geometry.materials = [Self.material]
        let node = SCNNode(geometry: asset.geometry)
        node.name = asset.name
        node.categoryBitMask = Self.lightingCategory
        node.isHidden = true
        root.addChildNode(node)
        parts[part] = node
        inverseBinds[part] = simd_inverse(asset.bindTransform)
      }
      // Isolated bone lighting lifts the short reveal's midtones without making
      // every surface emissive or affecting the AR camera/tracer materials.
      addLight(type: .ambient, intensity: 430, color: AnatomyColor(red: 0.80, green: 0.87, blue: 0.92, alpha: 1))
      addLight(type: .directional, intensity: 1_100, color: AnatomyColor(red: 1, green: 0.96, blue: 0.90, alpha: 1),
        angles: SCNVector3(-0.4, -0.65, 0))
      addLight(type: .directional, intensity: 360, color: AnatomyColor(red: 0.65, green: 0.83, blue: 0.94, alpha: 1),
        angles: SCNVector3(0.2, 2.4, 0))
    }

    func update(_ skeleton: TargetingSkeleton, zone: TargetingHitZone?) {
      // The hit marker owns damage type; a zone is not a surface impact point.
      // Keep shaded anatomy instead of replacing every bone with bright red.
      for node in parts.values { node.isHidden = true }
      let placements = SkeletonAnatomyLayout.placements(for: skeleton, previous: previous)
      previous.removeAll(keepingCapacity: true)
      for placement in placements {
        guard let node = parts[placement.part], let inverseBind = inverseBinds[placement.part] else { continue }
        let x = SIMD3<Float>(placement.right * placement.size.x)
        let y = SIMD3<Float>(placement.up * placement.size.y)
        let z = SIMD3<Float>(placement.back * placement.size.z)
        let position = SIMD3<Float>(placement.position)
        let target = simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(y, 0),
          SIMD4<Float>(z, 0), SIMD4<Float>(position, 1)))
        let transform = target * inverseBind
        guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { transform[column][$0].isFinite } }),
          simd_determinant(transform) > 0 else { continue }
        node.simdTransform = transform
        node.isHidden = false
        previous[placement.part] = placement
      }
    }

    private func addLight(type: SCNLight.LightType, intensity: CGFloat, color: AnatomyColor,
      angles: SCNVector3 = SCNVector3Zero) {
      let light = SCNLight()
      light.type = type
      light.intensity = intensity
      light.color = color
      light.castsShadow = false
      light.categoryBitMask = Self.lightingCategory
      let node = SCNNode()
      node.light = light
      node.eulerAngles = angles
      root.addChildNode(node)
    }
  }
#endif
