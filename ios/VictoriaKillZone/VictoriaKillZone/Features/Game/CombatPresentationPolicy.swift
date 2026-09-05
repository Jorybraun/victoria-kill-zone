import Foundation

/// Presentation timing only. Hits are resolved by authority; these values never
/// delay damage, move a collider, or create a dodge window for a hitscan shot.
enum CombatPresentationPolicy {
  static let tracerCapacity = 24
  static let impactCapacity = 12
  static let maximumSkeletonJoints = 32
  static let maximumSkeletonBones = 32
  static let maximumTracerDistance = 25.0
  static let tracerSpeed = 180.0
  static let skeletonHoldDuration = 0.10
  static let skeletonFadeDuration = 0.18
  static let maximumSkeletonAge = 0.20

  static var skeletonDuration: TimeInterval {
    skeletonHoldDuration + skeletonFadeDuration
  }

  static func tracerDuration(distance: Double) -> TimeInterval? {
    guard distance.isFinite, distance > 0, distance <= maximumTracerDistance else { return nil }
    return max(0.045, distance / tracerSpeed)
  }

  /// A camera-relative visual muzzle gives a first-person streak parallax. The
  /// authoritative ray retains its camera origin and original direction.
  static func cosmeticMuzzleOffset(
    cameraRight: SIMD3<Float>,
    cameraUp: SIMD3<Float>,
    cameraForward: SIMD3<Float>
  ) -> SIMD3<Float> {
    cameraRight * 0.06 - cameraUp * 0.045 + cameraForward * 0.10
  }

  static func isPoseFresh(capturedAt: Date, now: Date) -> Bool {
    let age = now.timeIntervalSince(capturedAt)
    return age.isFinite && age >= 0 && age <= maximumSkeletonAge
  }
}

/// A fixed ring evicts the oldest visual under load instead of growing the scene.
struct CombatEffectPoolCursor {
  let capacity: Int
  private(set) var nextIndex = 0

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  mutating func acquire() -> Int {
    let index = nextIndex
    nextIndex = (nextIndex + 1) % capacity
    return index
  }

  mutating func reset() {
    nextIndex = 0
  }
}

/// Uses monotonic uptime. Pose updates may follow a confirmed flash, but cannot
/// begin or extend one. SceneKit also schedules its fade so silence cannot leave
/// an old skeleton visible indefinitely.
struct HitSkeletonPresentation {
  private(set) var expiresAt: TimeInterval?

  mutating func confirmHit(at uptime: TimeInterval) {
    guard uptime.isFinite, uptime >= 0 else {
      clear()
      return
    }
    expiresAt = uptime + CombatPresentationPolicy.skeletonDuration
  }

  func isVisible(at uptime: TimeInterval) -> Bool {
    guard let expiresAt, uptime.isFinite, uptime >= 0 else { return false }
    let startedAt = expiresAt - CombatPresentationPolicy.skeletonDuration
    return uptime >= startedAt && uptime < expiresAt
  }

  mutating func clear() {
    expiresAt = nil
  }
}
