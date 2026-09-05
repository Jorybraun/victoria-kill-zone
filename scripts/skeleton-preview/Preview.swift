import AppKit
import CryptoKit
import Foundation
import Metal
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

@main
@MainActor
struct SkeletonPreview {
  struct View {
    let name: String
    let target: SIMD3<Float>
    let yaw: Float
    let scale: Double
    var distance: Float = 3.2
    var perspective = false
    var width = 1080
    var height = 1440
  }

  static func main() throws {
    guard CommandLine.arguments.count == 4 else { throw Failure("Expected repository, asset, output paths") }
    let repository = URL(fileURLWithPath: CommandLine.arguments[1])
    let assetURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard let metal = MTLCreateSystemDefaultDevice() else { throw Failure("No Metal device; no evidence rendered") }
    let assetParts = try SkeletonMeshAsset.load(assetURL)
    let model = SkeletonAnatomyModel(assetParts: assetParts)
    guard model.geometryLoaded else { throw Failure("Production model refused asset") }
    let scene = SCNScene()
    scene.rootNode.addChildNode(model.root)
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.zNear = 0.01
    camera.camera?.zFar = 100
    camera.camera?.fieldOfView = 60
    camera.camera?.projectionDirection = .vertical
    camera.camera?.wantsHDR = false
    camera.camera?.wantsExposureAdaptation = false
    camera.camera?.bloomIntensity = 0
    scene.rootNode.addChildNode(camera)
    let renderer = SCNRenderer(device: metal, options: nil)
    renderer.scene = scene
    renderer.pointOfView = camera
    renderer.autoenablesDefaultLighting = false
    renderer.isJitteringEnabled = false
    let neutral = SkeletonReviewFixtures.neutral
    let poses: [(String, SkeletonReviewFixtures.Points)] = [
      ("neutral", neutral), ("bent-elbows", SkeletonReviewFixtures.bentElbows),
      ("crouch", SkeletonReviewFixtures.crouch), ("turned-90", SkeletonReviewFixtures.turned),
      ("missing-left-wrist-right-ankle", SkeletonReviewFixtures.missingWristAnkle),
      ("lateral-arm", SkeletonReviewFixtures.lateralArm(angle: .pi / 2)),
    ]
    let standingViews = [
      View(name: "front", target: [0, 0.875, 0], yaw: 0, scale: 1.12),
      View(name: "three-quarter", target: [0, 0.875, 0], yaw: .pi / 4, scale: 1.12),
      View(name: "rear", target: [0, 0.875, 0], yaw: .pi, scale: 1.12),
      View(name: "left-profile", target: [0, 0.875, 0], yaw: .pi / 2, scale: 1.12),
      View(name: "right-profile", target: [0, 0.875, 0], yaw: -.pi / 2, scale: 1.12),
    ]
    let backgrounds: [(String, NSColor)] = [
      ("dark", NSColor(srgbRed: 0.035, green: 0.055, blue: 0.070, alpha: 1)),
      ("gray", NSColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1)),
      ("bright", NSColor(srgbRed: 0.91, green: 0.92, blue: 0.90, alpha: 1)),
    ]
    var records: [[String: Any]] = []
    var renderTime: TimeInterval = 0
    var activeReveal: HitSkeletonReveal?

    func save(_ name: String, pose: String, view: View, background: (String, NSColor) = backgrounds[0],
      kind: String = "production-mesh-and-material", extra: [String: Any] = [:]) throws {
      scene.background.contents = background.1
      camera.camera?.usesOrthographicProjection = !view.perspective
      camera.camera?.orthographicScale = view.scale
      camera.simdPosition = view.target + [sin(view.yaw) * view.distance, 0, cos(view.yaw) * view.distance]
      camera.look(at: SCNVector3(view.target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
      let size = CGSize(width: view.width, height: view.height)
      let image = renderer.snapshot(atTime: renderTime, with: size, antialiasingMode: .multisampling4X)
      guard let data = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:])
      else { throw Failure("Unable to encode \(name)") }
      try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
      var record: [String: Any] = [
        "file": name + ".png", "pose": pose, "kind": kind,
        "background": background.0, "width": view.width, "height": view.height,
        "view": view.name, "cameraTarget": [view.target.x, view.target.y, view.target.z],
        "cameraYawRadians": view.yaw, "cameraDistanceMeters": view.distance,
        "verticalFieldOfViewDegrees": 60, "orthographic": !view.perspective,
        "orthographicScale": view.scale, "sha256": hash(png),
        "visibleGeometry": geometryRecord(model.root),
      ]
      record.merge(extra) { _, value in value }
      if let activeReveal {
        record["revealNodeHidden"] = activeReveal.root.isHidden
        record["revealNodeOpacity"] = activeReveal.root.presentation.opacity
        record["sceneTimeSeconds"] = renderTime
      }
      records.append(record)
      print("Rendered \(name)")
    }

    // Raw imported parts in one shared source-world frame isolate asset quality
    // from retargeting. Materials and lights remain the production ones.
    for node in model.root.childNodes where node.geometry != nil {
      node.simdTransform = matrix_identity_float4x4
      node.isHidden = false
    }
    for view in standingViews { try save("source-\(view.name)", pose: "source-bind", view: view) }
    if let skull = model.root.childNode(withName: "skull", recursively: false) {
      let bounds = skull.boundingBox
      let target = (SIMD3<Float>(bounds.min) + SIMD3<Float>(bounds.max)) / 2
      for (name, yaw) in [("front", Float(0)), ("three-quarter", Float.pi / 4), ("profile", Float.pi / 2)] {
        try save("source-skull-\(name)", pose: "source-bind",
          view: View(name: name, target: target, yaw: yaw, scale: 0.155, height: 1080))
      }
      // Optional generated reference meshes are reviewed with the exact same
      // material, camera and lights. They are not shipped or retargeted.
      for version in ["source", "packaged"] {
        let referenceURL = repository.appendingPathComponent("scripts/skeleton-assets/work/skull-\(version).obj")
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { continue }
        let mdl = MDLAsset(url: referenceURL)
        let reference = SCNNode()
        for index in 0..<mdl.count {
          if let object = mdl[index] { reference.addChildNode(SCNNode(mdlObject: object)) }
        }
        reference.enumerateChildNodes { node, _ in
          node.geometry?.materials = skull.geometry?.materials ?? []
          node.categoryBitMask = skull.categoryBitMask
        }
        for node in model.root.childNodes where node.geometry != nil { node.isHidden = true }
        model.root.addChildNode(reference)
        for (name, yaw) in [("front", Float(0)), ("three-quarter", Float.pi / 4), ("profile", Float.pi / 2)] {
          try save("reference-skull-\(version)-\(name)", pose: "source-bind",
            view: View(name: name, target: target, yaw: yaw, scale: 0.155, height: 1080),
            kind: "source-comparison-original-or-converted-geometry-production-material",
            extra: ["referenceOBJ": "skull-\(version).obj", "referenceSHA256": hash(try Data(contentsOf: referenceURL))])
        }
        reference.removeFromParentNode()
      }
    }

    for (poseName, points) in poses {
      model.update(SkeletonReviewFixtures.skeleton(points), zone: nil)
      let views = poseName == "neutral" ? standingViews : Array(standingViews.prefix(2))
      for view in views { try save("\(poseName)-\(view.name)", pose: poseName, view: view) }
      if poseName == "neutral" {
        let materials = model.root.childNodes.compactMap { node -> (SCNGeometry, [SCNMaterial])? in
          guard let geometry = node.geometry else { return nil }
          return (geometry, geometry.materials)
        }
        let silhouette = SCNMaterial()
        silhouette.lightingModel = .constant
        silhouette.diffuse.contents = NSColor.black
        for (geometry, _) in materials { geometry.materials = [silhouette] }
        for view in [standingViews[0], standingViews[2], standingViews[3]] {
          try save("silhouette-\(view.name)", pose: poseName, view: view, background: backgrounds[2], kind: "actual-mesh-unlit-silhouette")
        }
        for (geometry, originals) in materials { geometry.materials = originals }
      }
    }

    model.update(SkeletonReviewFixtures.skeleton(neutral), zone: nil)
    let crops: [View] = [
      View(name: "skull-front", target: [0, 1.63, 0.005], yaw: 0, scale: 0.155, height: 1080),
      View(name: "skull-three-quarter", target: [0, 1.63, 0.005], yaw: .pi / 4, scale: 0.155, height: 1080),
      View(name: "skull-profile", target: [0, 1.63, 0.005], yaw: .pi / 2, scale: 0.155, height: 1080),
      View(name: "pelvis", target: [0, 0.96, 0], yaw: .pi / 4, scale: 0.235, height: 1080),
      View(name: "shoulder-back", target: [0, 1.36, -0.02], yaw: .pi, scale: 0.265, height: 1080),
      View(name: "left-hand", target: [0.30, 0.78, 0], yaw: 0, scale: 0.150, height: 1080),
      View(name: "left-foot", target: [0.10, 0.08, 0.05], yaw: .pi / 3, scale: 0.180, height: 1080),
    ]
    for view in crops { try save("detail-\(view.name)", pose: "neutral", view: view) }
    for distance: Float in [3, 8, 15] {
      let view = View(name: "front-\(Int(distance))m", target: [0, 0.875, 0], yaw: 0,
        scale: 1.12, distance: distance, perspective: true, width: 1440, height: 1080)
      for background in backgrounds {
        try save("distance-\(Int(distance))m-\(background.0)", pose: "neutral", view: view, background: background,
          extra: ["fixtureHeightPixelsIdeal": 1.75 / (2 * Double(distance) * tan(.pi / 6)) * 1080])
      }
    }

    // This is the exact controller and SceneKit action used by LaserFX. Scene
    // times are deterministic; these are not wall-clock device timing captures.
    let reveal = HitSkeletonReveal(anatomy: model)
    activeReveal = reveal
    scene.rootNode.addChildNode(reveal.root)
    renderTime = 10
    _ = renderer.snapshot(atTime: renderTime, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
    reveal.confirmHit(skeleton: SkeletonReviewFixtures.skeleton(neutral, at: Date(timeIntervalSince1970: 10)),
      zone: .torso, at: 10, observedAt: Date(timeIntervalSince1970: 10))
    for milliseconds in [0, 20, 100, 180, 280] {
      let elapsed = Double(milliseconds) / 1_000
      renderTime = 10 + elapsed
      try save("reveal-\(milliseconds)ms", pose: "neutral", view: standingViews[0],
        kind: "production-reveal-SceneKit-action-deterministic-time", extra: ["elapsedMs": milliseconds,
          "policyVisible": reveal.sample(at: renderTime).visible, "policyOpacity": reveal.sample(at: renderTime).opacity])
    }
    renderTime = 20
    _ = renderer.snapshot(atTime: renderTime, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
    reveal.confirmHit(skeleton: SkeletonReviewFixtures.skeleton(neutral, at: Date(timeIntervalSince1970: 20)),
      zone: .torso, at: 20, observedAt: Date(timeIntervalSince1970: 20))
    _ = renderer.snapshot(atTime: renderTime, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
    renderTime = 20.15
    _ = renderer.snapshot(atTime: renderTime, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
    reveal.confirmHit(skeleton: SkeletonReviewFixtures.skeleton(neutral, at: Date(timeIntervalSince1970: 20.15)),
      zone: .torso, at: 20.15, observedAt: Date(timeIntervalSince1970: 20.15))
    _ = renderer.snapshot(atTime: renderTime, with: CGSize(width: 16, height: 16), antialiasingMode: .none)
    renderTime = 20.28
    try save("repeated-hit-280ms", pose: "neutral", view: standingViews[0],
      kind: "production-reveal-SceneKit-action-deterministic-time", extra: ["latestHitAtMs": 150, "elapsedMs": 280])
    renderTime = 30.201
    reveal.refresh(SkeletonReviewFixtures.skeleton(neutral, at: Date(timeIntervalSince1970: 30)),
      at: 20.201, observedAt: Date(timeIntervalSince1970: 30.201))
    try save("stale-observation-201ms", pose: "neutral", view: standingViews[0],
      kind: "production-reveal-controller-stale-input", extra: ["poseAgeMs": 201])
    reveal.clear()

    let sourcePaths = [
      "ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift",
      "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/CombatPresentationPolicy.swift",
      "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/SkeletonAnatomyLayout.swift",
      "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/SkeletonMeshAsset.swift",
      "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/SkeletonAnatomyModel.swift",
      "ios/VictoriaKillZone/VictoriaKillZone/Features/Game/HitSkeletonReveal.swift",
      "scripts/skeleton-preview/ReviewFixtures.swift", "scripts/skeleton-preview/Preview.swift",
    ]
    let sources = try Dictionary(uniqueKeysWithValues: sourcePaths.map { path in
      (path, hash(try Data(contentsOf: repository.appendingPathComponent(path))))
    })
    let manifest: [String: Any] = [
      "evidenceKind": "synthetic-native-SceneKit-render", "createdAt": ISO8601DateFormatter().string(from: Date()),
      "assetSHA256": hash(try Data(contentsOf: assetURL)), "sourceSHA256": sources,
      "convention": ["subjectLeft": "+X", "superior": "+Y", "anterior": "+Z", "units": "meters"],
      "renderer": ["api": "SceneKit SCNRenderer + Metal", "antialiasing": "4xMSAA", "defaultLighting": false,
        "lights": "unmodified production model lights", "HDR": false, "autoExposure": false, "bloom": false],
      "fixtures": Dictionary(uniqueKeysWithValues: poses.map { name, points in
        (name, ["joints": SkeletonReviewFixtures.serialized(points), "segmentLengthsMeters": SkeletonReviewFixtures.segmentLengths(points)] as [String: Any])
      }),
      "frames": records,
      "limits": ["Not a physical camera capture", "Not GPU/frame-time performance evidence", "Reveal captures use deterministic SceneKit times, not physical-device wall-clock timing", "Source fingerprints identify uncommitted implementation exactly"],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
  }

  static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func geometryRecord(_ root: SCNNode) -> [[String: Any]] {
    var nodes: [SCNNode] = []
    root.enumerateChildNodes { node, _ in nodes.append(node) }
    return nodes.compactMap { node in
      guard let geometry = node.geometry else { return nil }
      let bounds = node.boundingBox
      let transform = node.simdWorldTransform
      var hidden = node.isHidden
      var parent = node.parent
      while let ancestor = parent {
        hidden = hidden || ancestor.isHidden
        parent = ancestor.parent
      }
      return [
        "part": node.name ?? "unnamed", "hidden": hidden,
        "triangles": geometry.elements.reduce(0) { $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0) },
        "elements": geometry.elements.count, "transformDeterminant": simd_determinant(transform),
        "transform": (0..<4).flatMap { column in (0..<4).map { row in transform[column][row] } },
        "localBounds": [[bounds.min.x, bounds.min.y, bounds.min.z], [bounds.max.x, bounds.max.y, bounds.max.z]],
      ]
    }
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
