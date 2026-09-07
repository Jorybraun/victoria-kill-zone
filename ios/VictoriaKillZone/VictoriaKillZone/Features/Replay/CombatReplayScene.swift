#if DEBUG && os(iOS) && canImport(SceneKit)
import SceneKit
import UIKit

/// A camera-free stage. Arena coordinates enter the same pooled FX used by the
/// game, then one non-identity root transform maps them into this scene.
@MainActor
final class CombatReplayScene {
  let scene = SCNScene()
  let camera = SCNNode()
  let effects = RealtimeCombatFX()
  let localFromArena: simd_float4x4
  private let arena = SCNNode()
  private var phones: [SCNNode] = []

  init() {
    var transform = simd_float4x4(simd_quatf(angle: 0.35, axis: SIMD3<Float>(0, 1, 0)))
    transform.columns.3 = SIMD4<Float>(1.2, -0.4, -2.8, 1)
    localFromArena = transform
    effects.root.simdTransform = transform
    arena.simdTransform = transform
    scene.rootNode.addChildNode(arena)
    scene.rootNode.addChildNode(effects.root)
    scene.background.contents = UIColor(red: 0.027, green: 0.043, blue: 0.063, alpha: 1)
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 50
    camera.camera?.zNear = 0.02
    camera.camera?.zFar = 80
    scene.rootNode.addChildNode(camera)

    // A metre grid and simple phone markers describe the recorded coordinates.
    // Neither is a collider, body estimate, skeleton or readiness signal.
    let gridMaterial = Self.material(.init(red: 0.2, green: 0.35, blue: 0.4, alpha: 0.5))
    for x in 0...25 {
      let line = SCNNode(geometry: SCNBox(width: 0.006, height: 0.006, length: 4, chamferRadius: 0))
      line.geometry?.firstMaterial = gridMaterial
      line.simdPosition = SIMD3<Float>(Float(x), -0.5, 0)
      arena.addChildNode(line)
    }
    for z in -2...2 {
      let line = SCNNode(geometry: SCNBox(width: 25, height: 0.006, length: 0.006, chamferRadius: 0))
      line.geometry?.firstMaterial = gridMaterial
      line.simdPosition = SIMD3<Float>(12.5, -0.5, Float(z))
      arena.addChildNode(line)
    }
    for index in 0..<RealtimeCombatPresentation.playerCapacity {
      let marker = SCNNode(geometry: SCNBox(width: 0.16, height: 0.32, length: 0.03, chamferRadius: 0.02))
      marker.name = "synthetic-phone-\(index)"
      marker.geometry?.firstMaterial = Self.material(index == 0 ? .cyan : .systemPink)
      marker.isHidden = true
      arena.addChildNode(marker)
      phones.append(marker)
    }
    positionCamera(following: 2.5)
  }

  func update(_ session: CombatReplaySession) {
    guard !session.isCleared else { clear(); return }
    let snapshot = session.snapshot
    effects.update(snapshot: snapshot, matchTimeMs: session.matchTimeMs)
    for index in phones.indices {
      guard index < snapshot.players.count,
        snapshot.players[index].connected,
        let pose = snapshot.phonePoses.first(where: { $0.playerId == snapshot.players[index].id })?.pose,
        pose.position.count == 3
      else { phones[index].isHidden = true; continue }
      phones[index].simdPosition = SIMD3<Float>(Float(pose.position[0]), Float(pose.position[1]), Float(pose.position[2]))
      phones[index].isHidden = false
    }
    if let projectile = session.presentation.projectiles.first,
      let timing = session.presentation.timing(at: session.matchTimeMs / 1000),
      let point = RealtimeCombatPresentation.position(projectile, timing: timing) {
      positionCamera(following: min(23, max(2.5, Float(point.x))))
    }
  }

  func reset() {
    clear()
    positionCamera(following: 2.5)
  }

  func clear() {
    effects.clear()
    phones.forEach { $0.isHidden = true }
  }

  private func positionCamera(following x: Float) {
    let eye = localFromArena * SIMD4<Float>(x, 3.2, 6.5, 1)
    let target = localFromArena * SIMD4<Float>(x, 0, 0, 1)
    camera.simdPosition = SIMD3<Float>(eye.x, eye.y, eye.z)
    camera.look(at: SCNVector3(target.x, target.y, target.z))
  }

  private static func material(_ color: UIColor) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = color
    return material
  }
}
#endif
