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

    init() {
      configureAudio()
    }

    func attach(to view: ARSCNView) {
      sceneView = view
    }

    func fireLaser(hit: Bool) {
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
      let muzzle = worldPoint(
        cameraTransform,
        SIMD3<Float>(0.05, -0.08, -0.1)
      )
      let beamLength: Float = 25
      let beamEnd = muzzle + forward * beamLength
      let root = sceneView.scene.rootNode

      let beam = SCNCylinder(radius: 0.008, height: CGFloat(beamLength))
      let beamMaterial = SCNMaterial()
      beamMaterial.diffuse.contents = UIColor.red
      beamMaterial.emission.contents = UIColor.red
      beamMaterial.lightingModel = .constant
      beam.firstMaterial = beamMaterial
      let beamNode = SCNNode(geometry: beam)
      beamNode.position = midpoint(muzzle, beamEnd)
      beamNode.simdOrientation = simd_quatf(
        from: SIMD3<Float>(0, 1, 0),
        to: forward
      )
      root.addChildNode(beamNode)
      beamNode.runAction(.sequence([
        .fadeOut(duration: 0.35),
        .removeFromParentNode()
      ]))

      let bullet = SCNSphere(radius: 0.015)
      let bulletMaterial = SCNMaterial()
      bulletMaterial.diffuse.contents = UIColor.white
      bulletMaterial.emission.contents = UIColor(red: 1, green: 0.15, blue: 0.05, alpha: 1)
      bulletMaterial.lightingModel = .constant
      bullet.firstMaterial = bulletMaterial
      let bulletNode = SCNNode(geometry: bullet)
      bulletNode.position = SCNVector3(muzzle.x, muzzle.y, muzzle.z)
      root.addChildNode(bulletNode)
      bulletNode.runAction(.sequence([
        .move(to: SCNVector3(beamEnd.x, beamEnd.y, beamEnd.z), duration: 0.4),
        .removeFromParentNode()
      ]))

      if hit {
        let hitPoint = muzzle + forward * 6
        let spark = SCNSphere(radius: 0.07)
        let sparkMaterial = SCNMaterial()
        sparkMaterial.diffuse.contents = UIColor.orange
        sparkMaterial.emission.contents = UIColor.yellow
        sparkMaterial.lightingModel = .constant
        spark.firstMaterial = sparkMaterial
        let sparkNode = SCNNode(geometry: spark)
        sparkNode.position = SCNVector3(hitPoint.x, hitPoint.y, hitPoint.z)
        sparkNode.scale = SCNVector3(0.35, 0.35, 0.35)

        let light = SCNLight()
        light.type = .omni
        light.color = UIColor.orange
        light.intensity = 800
        light.attenuationEndDistance = 2
        sparkNode.light = light
        root.addChildNode(sparkNode)
        sparkNode.runAction(.sequence([
          .group([
            .scale(to: 1.8, duration: 0.12),
            .fadeOut(duration: 0.18)
          ]),
          .removeFromParentNode()
        ]))
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
#endif
