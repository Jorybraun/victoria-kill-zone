#if os(iOS) && canImport(ARKit)
  import ARKit
  import AVFoundation
  import Combine
  import SceneKit
  import UIKit

  @MainActor
  final class LaserFXEngine: ObservableObject {
    private weak var sceneView: ARSCNView?
    private let effectsRoot = SCNNode()
    private let audioEngine = AVAudioEngine()
    private let audioState = LaserAudioState()
    private var audioSource: AVAudioSourceNode?
    private let shotFeedback = UIImpactFeedbackGenerator(style: .light)
    private let damageFeedback = UIImpactFeedbackGenerator(style: .rigid)
    private let hitFeedback = UINotificationFeedbackGenerator()
    private let skeletonRoot = SCNNode()
    private let skeletonAnatomy = SkeletonAnatomyModel()
    private var hitPresentation = HitSkeletonPresentation()
    private var confirmedHitZone: TargetingHitZone?
    private var lastSkeletonUpdate: TimeInterval = 0
    private let outgoingGeometry = LaserFXEngine.tracerGeometry(color: UIColor(red: 1, green: 0.82, blue: 0.32, alpha: 1))
    private let incomingGeometry = LaserFXEngine.tracerGeometry(color: .systemOrange)
    private let tracerPool = SceneEffectPool(capacity: CombatPresentationPolicy.tracerCapacity)
    private let impactPool = SceneEffectPool(capacity: CombatPresentationPolicy.impactCapacity)
    private let impactGeometry: SCNSphere = {
      let sphere = SCNSphere(radius: 0.045)
      sphere.segmentCount = 8
      sphere.firstMaterial = LaserFXEngine.material(color: .systemOrange)
      return sphere
    }()

    init() {
      effectsRoot.name = "combat-effects"
      skeletonRoot.name = "confirmed-hit-skeleton"
      skeletonRoot.isHidden = true
      skeletonRoot.addChildNode(skeletonAnatomy.root)
      effectsRoot.addChildNode(skeletonRoot)
      tracerPool.attach(to: effectsRoot)
      impactPool.attach(to: effectsRoot)
      configureAudio()
      shotFeedback.prepare()
      hitFeedback.prepare()
      damageFeedback.prepare()
    }

    func attach(to view: ARSCNView) {
      guard sceneView !== view else { return }
      clearTransientEffects()
      effectsRoot.removeFromParentNode()
      sceneView = view
      view.scene.rootNode.addChildNode(effectsRoot)
    }

    /// Immediate local fire feedback. The streak is cosmetic hitscan presentation,
    /// not a projectile collider. Predicted shots must pass `hit: false`.
    func fireLaser(hit: Bool = false, ray: TargetingCameraRay? = nil) {
      shotFeedback.impactOccurred(intensity: 0.7)
      shotFeedback.prepare()
      playPew()
      if hit { confirmHit(skeleton: nil, zone: nil) }
      guard let sceneView else { return }
      let origin: SIMD3<Float>
      let direction: SIMD3<Float>
      if let ray {
        guard let position = vector(ray.origin), let rawDirection = vector(ray.direction),
          let unitDirection = normalized(rawDirection)
        else { return }
        origin = position
        direction = unitDirection
      } else {
        guard let frame = sceneView.session.currentFrame else { return }
        let transform = frame.camera.transform
        origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        guard let forward = normalized(SIMD3<Float>(
          -transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z
        )) else { return }
        direction = forward
      }
      let right: SIMD3<Float>
      let up: SIMD3<Float>
      let cameraForward: SIMD3<Float>
      if let transform = sceneView.session.currentFrame?.camera.transform {
        right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        cameraForward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
      } else {
        // A captured ray can still render before the next AR frame arrives.
        let referenceUp: SIMD3<Float> = abs(direction.y) > 0.95
          ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
        guard let fallbackRight = normalized(simd_cross(direction, referenceUp)) else { return }
        right = fallbackRight
        up = simd_cross(right, direction)
        cameraForward = direction
      }
      // Offset the visual muzzle only. Convergence stays on the original shot
      // endpoint, so neither the request ray nor authoritative hit geometry moves.
      let muzzle = origin + CombatPresentationPolicy.cosmeticMuzzleOffset(
        cameraRight: right, cameraUp: up, cameraForward: cameraForward
      )
      renderTracer(
        from: muzzle,
        to: origin + direction * Float(CombatPresentationPolicy.maximumTracerDistance),
        incoming: false
      )
    }

    /// Only call after an accepted outgoing hit. With no fresh observed body, the
    /// HUD and haptic confirm the verdict without inventing a world-space impact.
    func confirmHit(skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {
      hitFeedback.notificationOccurred(.success)
      hitFeedback.prepare()
      guard sceneView != nil, let skeleton,
        CombatPresentationPolicy.isPoseFresh(capturedAt: skeleton.capturedAt, now: Date())
      else {
        clearSkeleton()
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      hitPresentation.confirmHit(at: now)
      confirmedHitZone = zone
      lastSkeletonUpdate = now
      skeletonRoot.removeAllActions()
      skeletonRoot.opacity = 1
      skeletonRoot.isHidden = false
      renderSkeleton(skeleton, zone: confirmedHitZone)
      skeletonRoot.runAction(.sequence([
        .wait(duration: CombatPresentationPolicy.skeletonHoldDuration),
        .fadeOut(duration: CombatPresentationPolicy.skeletonFadeDuration),
        .hide(),
      ]), forKey: "confirmed-hit")

      // The joint is a body-local impact cue, not a new authoritative hit point.
      let point = zone == .head
        ? skeleton.position(of: "head")
        : skeleton.position(of: "spine_7_joint") ?? skeleton.position(of: "root")
      if let point, let position = vector(point) {
        renderImpact(at: position)
      }
    }

    /// The interim incoming event has no aligned shot ray. A currently observed
    /// origin permits a coarse incoming cue; an unknown origin gives haptics only.
    func renderIncomingLaser(from origin: SIMD3<Float>?, hit: Bool) {
      if hit {
        damageFeedback.impactOccurred(intensity: 0.9)
        damageFeedback.prepare()
      }
      guard let sceneView, let frame = sceneView.session.currentFrame,
        let origin, origin.x.isFinite, origin.y.isFinite, origin.z.isFinite
      else { return }
      let transform = frame.camera.transform
      let cameraPosition = SIMD3<Float>(
        transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
      )
      guard let forward = normalized(SIMD3<Float>(
        -transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z
      )) else { return }
      // Aim toward the receiver only for the explicitly coarse legacy cue.
      // Exact incoming worldlines require the shared-frame transport contract.
      let right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
      let end = hit ? cameraPosition + forward * 0.3 : cameraPosition + right * 0.6
      renderTracer(from: origin, to: end, incoming: true)
      if hit { renderImpact(at: end) }
    }

    /// Tracking refreshes an existing flash but never reveals an unhit person.
    /// Expiry is also scheduled on the scene, including when observations stop.
    func updateSkeleton(_ skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {
      let now = ProcessInfo.processInfo.systemUptime
      guard hitPresentation.isVisible(at: now), let skeleton,
        CombatPresentationPolicy.isPoseFresh(capturedAt: skeleton.capturedAt, now: Date())
      else {
        clearSkeleton()
        return
      }
      guard now - lastSkeletonUpdate >= 0.05 else { return }
      lastSkeletonUpdate = now
      renderSkeleton(skeleton, zone: confirmedHitZone)
    }

    func clearTransientEffects() {
      clearSkeleton()
      tracerPool.clear()
      impactPool.clear()
      audioState.silence()
      audioEngine.pause()
    }

    private func clearSkeleton() {
      hitPresentation.clear()
      confirmedHitZone = nil
      skeletonRoot.removeAllActions()
      skeletonRoot.isHidden = true
      skeletonRoot.opacity = 0
      lastSkeletonUpdate = 0
    }

    private func renderTracer(from start: SIMD3<Float>, to end: SIMD3<Float>, incoming: Bool) {
      let delta = end - start
      let length = simd_length(delta)
      guard let direction = normalized(delta),
        let duration = CombatPresentationPolicy.tracerDuration(distance: Double(length))
      else { return }
      let streakLength = min(Float(0.85), length * 0.4)
      let node = tracerPool.acquire()
      node.geometry = incoming ? incomingGeometry : outgoingGeometry
      node.simdScale = SIMD3<Float>(1, streakLength, 1)
      node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
      node.simdPosition = start + direction * (streakLength / 2)
      let finish = end - direction * (streakLength / 2)
      let move = SCNAction.move(to: SCNVector3(finish.x, finish.y, finish.z), duration: duration)
      move.timingMode = .linear
      node.runAction(.sequence([
        .group([
          move,
          .sequence([.wait(duration: duration * 0.6), .fadeOut(duration: duration * 0.4)]),
        ]),
        .hide(),
      ]))
    }

    private func renderImpact(at position: SIMD3<Float>) {
      let node = impactPool.acquire()
      node.geometry = impactGeometry
      node.simdPosition = position
      node.simdScale = SIMD3<Float>(repeating: 0.4)
      node.runAction(.sequence([
        .group([.scale(to: 1.7, duration: 0.12), .fadeOut(duration: 0.16)]),
        .hide(),
      ]))
    }

    private func renderSkeleton(_ skeleton: TargetingSkeleton, zone: TargetingHitZone?) {
      skeletonAnatomy.update(skeleton, zone: zone)
    }

    private static func material(color: UIColor) -> SCNMaterial {
      let material = SCNMaterial()
      material.lightingModel = .constant
      material.diffuse.contents = color
      material.emission.contents = color
      material.writesToDepthBuffer = false
      return material
    }

    private static func tracerGeometry(color: UIColor) -> SCNCylinder {
      let geometry = SCNCylinder(radius: 0.007, height: 1)
      geometry.radialSegmentCount = 6
      geometry.firstMaterial = material(color: color)
      return geometry
    }

    private func vector(_ point: TargetingVector3) -> SIMD3<Float>? {
      let result = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
      guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return nil }
      return result
    }

    private func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float>? {
      let length = simd_length(vector)
      guard length.isFinite, length > 0.0001 else { return nil }
      return vector / length
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

  }

  @MainActor
  private final class SceneEffectPool {
    private let nodes: [SCNNode]
    private var cursor: CombatEffectPoolCursor

    init(capacity: Int) {
      cursor = CombatEffectPoolCursor(capacity: capacity)
      nodes = (0..<cursor.capacity).map { _ in
        let node = SCNNode()
        node.isHidden = true
        return node
      }
    }

    func attach(to root: SCNNode) {
      for node in nodes { root.addChildNode(node) }
    }

    func acquire() -> SCNNode {
      let node = nodes[cursor.acquire()]
      node.removeAllActions()
      node.opacity = 1
      node.simdScale = SIMD3<Float>(repeating: 1)
      node.isHidden = false
      return node
    }

    func clear() {
      for node in nodes {
        node.removeAllActions()
        node.isHidden = true
        node.opacity = 0
      }
      cursor.reset()
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

    func silence() {
      lock.lock()
      sampleIndex = Int.max
      lock.unlock()
    }

    func fill(
      _ audioBufferList: UnsafeMutablePointer<AudioBufferList>,
      frameCount: AVAudioFrameCount
    ) -> OSStatus {
      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard lock.try() else {
        for buffer in buffers {
          guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
          data.update(repeating: 0, count: Int(frameCount))
        }
        return noErr
      }
      defer { lock.unlock() }
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
    func fireLaser(hit: Bool = false, ray: TargetingCameraRay? = nil) {}
    func confirmHit(skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {}
    func renderIncomingLaser(from origin: SIMD3<Float>?, hit: Bool) {}
    func updateSkeleton(_ skeleton: TargetingSkeleton?, zone: TargetingHitZone?) {}
    func clearTransientEffects() {}
  }
#endif
