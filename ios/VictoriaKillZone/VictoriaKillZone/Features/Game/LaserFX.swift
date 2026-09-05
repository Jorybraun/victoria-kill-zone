#if os(iOS) && canImport(ARKit)
  import ARKit
  import AVFoundation
  import Combine
  import SceneKit
  import UIKit

  @MainActor
  final class LaserFXEngine: ObservableObject {
    private weak var sceneView: ARSCNView?
    private let audioEngine = AVAudioEngine()
    private let audioState = LaserAudioState()
    private var audioSource: AVAudioSourceNode?
    private var skeletonRoot: SCNNode?
    private var skeletonJointNodes: [String: SCNNode] = [:]
    private var skeletonBoneNodes: [String: SCNNode] = [:]
    private let skeletonMaterial: SCNMaterial = {
      let material = SCNMaterial()
      material.lightingModel = .constant
      material.transparency = 0.85
      return material
    }()
    private var lastSkeletonUpdate = Date.distantPast

    init() {
      configureAudio()
    }

    func attach(to view: ARSCNView) {
      sceneView = view
    }

    /// Fires the local laser. `target` is the world-space point the shot lands
    /// on when a tracked opponent is available; otherwise the bolt flies down
    /// the camera axis.
    func fireLaser(hit: Bool, target: SIMD3<Float>? = nil) {
      let impact = UIImpactFeedbackGenerator(style: .heavy)
      impact.prepare()
      impact.impactOccurred()
      if hit {
        let notification = UINotificationFeedbackGenerator()
        notification.prepare()
        notification.notificationOccurred(.success)
      }
      playPew()

      guard let sceneView, let frame = sceneView.session.currentFrame else { return }
      let cameraTransform = frame.camera.transform
      let forward = normalized(SIMD3<Float>(
        -cameraTransform.columns.2.x,
        -cameraTransform.columns.2.y,
        -cameraTransform.columns.2.z
      ))
      let cameraPosition = SIMD3<Float>(
        cameraTransform.columns.3.x,
        cameraTransform.columns.3.y,
        cameraTransform.columns.3.z
      )
      // The muzzle sits low-right of the lens so the beam crosses the screen
      // diagonally instead of being viewed end-on as a dot.
      let muzzle = worldPoint(
        cameraTransform,
        SIMD3<Float>(0.16, -0.26, -0.2)
      )
      let beamEnd = target ?? cameraPosition + forward * (hit ? 6 : 25)

      spawnBolt(
        from: muzzle,
        to: beamEnd,
        color: UIColor(red: 1, green: 0.1, blue: 0.1, alpha: 1),
        travelDuration: hit ? 0.18 : 0.32,
        impact: hit
      )
    }

    func renderIncomingLaser(from origin: SIMD3<Float>?, hit: Bool) {
      guard let sceneView, let frame = sceneView.session.currentFrame else { return }
      let transform = frame.camera.transform
      let cameraPosition = SIMD3<Float>(
        transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
      )
      let forward = normalized(SIMD3<Float>(
        -transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z
      ))
      let right = normalized(SIMD3<Float>(
        transform.columns.0.x, transform.columns.0.y, transform.columns.0.z
      ))
      let up = normalized(SIMD3<Float>(
        transform.columns.1.x, transform.columns.1.y, transform.columns.1.z
      ))
      // Without a tracked opponent the shot comes from ahead and slightly off
      // axis; incoming bolts always finish off-centre so their path is visible
      // instead of collapsing to a point at the lens.
      let start = origin ?? cameraPosition + forward * 5 + up * 0.7 - right * 0.5
      let end = hit
        ? cameraPosition + forward * 0.45 - up * 0.22 + right * 0.08
        : cameraPosition + right * 0.9 - up * 0.5 - forward * 0.2
      spawnBolt(
        from: start,
        to: end,
        color: UIColor(red: 1, green: 0.55, blue: 0.05, alpha: 1),
        travelDuration: 0.28,
        impact: hit
      )
      if hit {
        let feedback = UIImpactFeedbackGenerator(style: .rigid)
        feedback.prepare()
        feedback.impactOccurred()
      }
    }

    /// A tracer line that lights up along its full length plus a bright bolt
    /// that travels the path, leaving a fading glow trail.
    private func spawnBolt(
      from start: SIMD3<Float>,
      to end: SIMD3<Float>,
      color: UIColor,
      travelDuration: TimeInterval,
      impact: Bool
    ) {
      guard let sceneView else { return }
      let root = sceneView.scene.rootNode
      let direction = normalized(end - start)
      let length = simd_length(end - start)
      guard length > 0.05 else { return }
      let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)

      let core = SCNCylinder(radius: 0.012, height: CGFloat(length))
      core.firstMaterial = emissiveMaterial(color, transparency: 0.95)
      let coreNode = SCNNode(geometry: core)
      coreNode.position = midpoint(start, end)
      coreNode.simdOrientation = orientation
      coreNode.renderingOrder = 10
      root.addChildNode(coreNode)
      coreNode.runAction(.sequence([
        .wait(duration: travelDuration * 0.5),
        .fadeOut(duration: 0.45),
        .removeFromParentNode(),
      ]))

      let glow = SCNCylinder(radius: 0.045, height: CGFloat(length))
      glow.firstMaterial = emissiveMaterial(color, transparency: 0.28)
      let glowNode = SCNNode(geometry: glow)
      glowNode.position = coreNode.position
      glowNode.simdOrientation = orientation
      glowNode.renderingOrder = 9
      root.addChildNode(glowNode)
      glowNode.runAction(.sequence([
        .wait(duration: travelDuration * 0.5),
        .fadeOut(duration: 0.3),
        .removeFromParentNode(),
      ]))

      let boltLength = min(length * 0.35, 1.2)
      let bolt = SCNCapsule(capRadius: 0.035, height: CGFloat(boltLength))
      bolt.firstMaterial = emissiveMaterial(.white, transparency: 1)
      let boltNode = SCNNode(geometry: bolt)
      let boltStart = start + direction * (boltLength / 2)
      let boltEnd = end - direction * (boltLength / 2)
      boltNode.position = SCNVector3(boltStart.x, boltStart.y, boltStart.z)
      boltNode.simdOrientation = orientation
      boltNode.renderingOrder = 11
      let boltLight = SCNLight()
      boltLight.type = .omni
      boltLight.color = color
      boltLight.intensity = 600
      boltLight.attenuationEndDistance = 1.5
      boltNode.light = boltLight
      root.addChildNode(boltNode)
      var boltActions: [SCNAction] = [
        .move(to: SCNVector3(boltEnd.x, boltEnd.y, boltEnd.z), duration: travelDuration)
      ]
      if impact {
        boltActions.append(.run { [weak self] _ in
          Task { @MainActor in self?.spawnImpact(at: end, color: color) }
        })
      }
      boltActions.append(.removeFromParentNode())
      boltNode.runAction(.sequence(boltActions))
    }

    private func spawnImpact(at point: SIMD3<Float>, color: UIColor) {
      guard let sceneView else { return }
      let spark = SCNSphere(radius: 0.09)
      spark.firstMaterial = emissiveMaterial(color, transparency: 0.9)
      let sparkNode = SCNNode(geometry: spark)
      sparkNode.position = SCNVector3(point.x, point.y, point.z)
      sparkNode.scale = SCNVector3(0.35, 0.35, 0.35)
      let light = SCNLight()
      light.type = .omni
      light.color = color
      light.intensity = 900
      light.attenuationEndDistance = 2
      sparkNode.light = light
      sceneView.scene.rootNode.addChildNode(sparkNode)
      sparkNode.runAction(.sequence([
        .group([.scale(to: 2.2, duration: 0.14), .fadeOut(duration: 0.22)]),
        .removeFromParentNode(),
      ]))
    }

    private func emissiveMaterial(_ color: UIColor, transparency: CGFloat) -> SCNMaterial {
      let material = SCNMaterial()
      material.diffuse.contents = color
      material.emission.contents = color
      material.lightingModel = .constant
      material.transparency = transparency
      material.blendMode = .add
      material.writesToDepthBuffer = false
      material.readsFromDepthBuffer = false
      return material
    }

    func updateSkeleton(_ skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {
      guard let sceneView else { return }
      if skeleton == nil {
        skeletonRoot?.removeFromParentNode()
        return
      }
      guard Date().timeIntervalSince(lastSkeletonUpdate) >= 0.05 else { return }
      lastSkeletonUpdate = Date()
      let root = skeletonRoot ?? SCNNode()
      if root.parent == nil {
        sceneView.scene.rootNode.addChildNode(root)
        skeletonRoot = root
      }
      guard let skeleton else { return }
      let color: UIColor = zone == .head ? .systemRed : .systemGreen
      skeletonMaterial.diffuse.contents = color
      skeletonMaterial.emission.contents = color
      let byName = Dictionary(uniqueKeysWithValues: skeleton.joints.map { ($0.name, $0.position) })
      let jointNames = Set(skeleton.joints.map(\.name))
      for name in Array(skeletonJointNodes.keys) where !jointNames.contains(name) {
        skeletonJointNodes.removeValue(forKey: name)?.removeFromParentNode()
      }
      for joint in skeleton.joints {
        let node: SCNNode
        if let existing = skeletonJointNodes[joint.name] {
          node = existing
        } else {
          let sphere = SCNSphere(radius: 0.03)
          sphere.firstMaterial = skeletonMaterial
          node = SCNNode(geometry: sphere)
          skeletonJointNodes[joint.name] = node
          root.addChildNode(node)
        }
        node.position = SCNVector3(
          joint.position.x, joint.position.y, joint.position.z
        )
      }
      let boneNames = Set(skeleton.bones.map { "\($0.from)>\($0.to)" })
      for name in Array(skeletonBoneNodes.keys) where !boneNames.contains(name) {
        skeletonBoneNodes.removeValue(forKey: name)?.removeFromParentNode()
      }
      for bone in skeleton.bones {
        guard let from = byName[bone.from], let to = byName[bone.to] else { continue }
        let name = "\(bone.from)>\(bone.to)"
        let start = SIMD3<Float>(Float(from.x), Float(from.y), Float(from.z))
        let end = SIMD3<Float>(Float(to.x), Float(to.y), Float(to.z))
        let node: SCNNode
        if let existing = skeletonBoneNodes[name] {
          node = existing
        } else {
          let cylinder = SCNCylinder(radius: 0.012, height: 0)
          cylinder.firstMaterial = skeletonMaterial
          node = SCNNode(geometry: cylinder)
          skeletonBoneNodes[name] = node
          root.addChildNode(node)
        }
        guard let cylinder = node.geometry as? SCNCylinder else { continue }
        cylinder.height = CGFloat(simd_length(end - start))
        node.position = midpoint(start, end)
        node.simdOrientation = simd_quatf(
          from: SIMD3<Float>(0, 1, 0), to: normalized(end - start)
        )
      }
    }

    private func configureAudio() {
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      try? session.setActive(true)

      guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
      else { return }
      let source = AVAudioSourceNode { [audioState] _, _, frameCount, audioBufferList in
        audioState.fill(audioBufferList, frameCount: frameCount)
      }
      audioSource = source
      audioEngine.attach(source)
      audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
      audioEngine.prepare()
      try? audioEngine.start()
    }

    private func playPew() {
      audioState.trigger()
      if !audioEngine.isRunning {
        try? audioEngine.start()
      }
    }

    private func worldPoint(
      _ transform: simd_float4x4,
      _ cameraSpacePoint: SIMD3<Float>
    ) -> SIMD3<Float> {
      let point = transform * SIMD4<Float>(
        cameraSpacePoint.x,
        cameraSpacePoint.y,
        cameraSpacePoint.z,
        1
      )
      return SIMD3<Float>(point.x, point.y, point.z)
    }

    private func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
      let length = simd_length(vector)
      guard length > 0 else { return SIMD3<Float>(0, 0, -1) }
      return vector / length
    }

    private func midpoint(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> SCNVector3 {
      SCNVector3(
        (first.x + second.x) / 2,
        (first.y + second.y) / 2,
        (first.z + second.z) / 2
      )
    }
  }

  private final class LaserAudioState: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate = 44_100.0
    private let duration = 0.15
    private var sampleIndex = Int.max
    private var phase = 0.0

    func trigger() {
      lock.lock()
      sampleIndex = 0
      phase = 0
      lock.unlock()
    }

    func fill(
      _ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
      frameCount: AVAudioFrameCount
    ) -> OSStatus {
      lock.lock()
      defer { lock.unlock() }

      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      for buffer in buffers {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<Int(frameCount) {
          guard sampleIndex < Int(sampleRate * duration) else {
            data[frame] = 0
            continue
          }
          let progress = Double(sampleIndex) / (sampleRate * duration)
          let frequency = 900 - 600 * progress
          let envelope = Float((1 - progress) * 0.22)
          data[frame] = sin(Float(phase)) * envelope
          phase += 2 * .pi * frequency / sampleRate
          sampleIndex += 1
        }
      }
      return noErr
    }
  }
#else
  import Combine

  @MainActor
  final class LaserFXEngine: ObservableObject {
    func fireLaser(hit: Bool, target: SIMD3<Float>? = nil) {}
    func renderIncomingLaser(from origin: SIMD3<Float>?, hit: Bool) {}
    func updateSkeleton(_ skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {}
  }
#endif
