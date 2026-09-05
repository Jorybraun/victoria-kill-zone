#if canImport(SceneKit)
  import Foundation
  import SceneKit

  /// The single pooled, confirmed-hit reveal used by the game and native art
  /// harness. Geometry is preloaded by the model; refreshes never extend expiry.
  @MainActor
  final class HitSkeletonReveal {
    let root = SCNNode()
    private let anatomy: SkeletonAnatomyModel
    private var presentation = HitSkeletonPresentation()
    private var zone: TargetingHitZone?
    private var lastPoseUpdate: TimeInterval = 0

    init(anatomy: SkeletonAnatomyModel? = nil) {
      let anatomy = anatomy ?? SkeletonAnatomyModel()
      self.anatomy = anatomy
      root.name = "confirmed-hit-skeleton"
      root.addChildNode(anatomy.root)
      root.isHidden = true
      root.opacity = 0
    }

    @discardableResult
    func confirmHit(skeleton: TargetingSkeleton?, zone: TargetingHitZone?,
      at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
      observedAt now: Date = Date()) -> Bool
    {
      guard let skeleton, CombatPresentationPolicy.isPoseFresh(capturedAt: skeleton.capturedAt, now: now),
        uptime.isFinite, uptime >= 0 else { clear(); return false }
      presentation.confirmHit(at: uptime)
      self.zone = zone
      lastPoseUpdate = uptime
      root.removeAllActions()
      anatomy.update(skeleton, zone: zone)
      root.opacity = 1
      root.isHidden = false
      // The production SceneKit action and deterministic sample use the exact
      // same opacity function. No display link or repeated mesh allocation.
      root.runAction(.sequence([
        .customAction(duration: CombatPresentationPolicy.skeletonDuration) { node, elapsed in
          node.opacity = Self.opacity(elapsed: Double(elapsed))
        },
        .hide(),
      ]), forKey: "confirmed-hit")
      return true
    }

    func refresh(_ skeleton: TargetingSkeleton?, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
      observedAt now: Date = Date())
    {
      guard presentation.isVisible(at: uptime), let skeleton,
        CombatPresentationPolicy.isPoseFresh(capturedAt: skeleton.capturedAt, now: now)
      else { clear(); return }
      guard uptime - lastPoseUpdate >= 0.05 else { return }
      lastPoseUpdate = uptime
      anatomy.update(skeleton, zone: zone)
    }

    func clear() {
      presentation.clear()
      zone = nil
      lastPoseUpdate = 0
      root.removeAllActions()
      root.isHidden = true
      root.opacity = 0
    }

    /// Deterministic inspection of the same production curve. This is useful
    /// to assert exact boundaries; it does not prove wall-clock device timing.
    func sample(at uptime: TimeInterval) -> (visible: Bool, opacity: CGFloat) {
      guard presentation.isVisible(at: uptime), let expiresAt = presentation.expiresAt else { return (false, 0) }
      let elapsed = uptime - (expiresAt - CombatPresentationPolicy.skeletonDuration)
      return (true, Self.opacity(elapsed: elapsed))
    }

    nonisolated static func opacity(elapsed: TimeInterval) -> CGFloat {
      guard elapsed.isFinite, elapsed >= 0, elapsed < CombatPresentationPolicy.skeletonDuration else { return 0 }
      return CGFloat(max(0, min(1,
        1 - (elapsed - CombatPresentationPolicy.skeletonHoldDuration) / CombatPresentationPolicy.skeletonFadeDuration)))
    }
  }
#endif
