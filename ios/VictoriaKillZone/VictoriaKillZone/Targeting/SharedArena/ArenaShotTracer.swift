import Foundation

// MARK: - Shared-arena shot tracers (KIL-22 presentation, hitscan only)
//
// Implements the frozen tracer rules from
// docs/features/shared-spatial-hit-registration/requirements.md §6.4:
// one deduplicated transient tracer per shot identity per member, drawn from
// the shot's shared-arena origin and normalized direction, hits and misses
// alike; the tracer is presentation of an instantaneous ray and never a
// simulated body. No verdict, damage, ammo, or Convex change lives here.

/// A shot as exchanged between members. `shotId` is the shot identity that
/// every dedup and reconciliation rule keys on.
struct ArenaShotTracer: Equatable, Sendable {
  let shotId: String
  let shooterPlayerId: String
  let firedAtMs: Int64
  let ray: ArenaShotRay

  init(shotId: String, shooterPlayerId: String, ray: ArenaShotRay) {
    self.shotId = shotId
    self.shooterPlayerId = shooterPlayerId
    firedAtMs = ray.firedAtMs
    self.ray = ray
  }
}

enum ArenaTracerKind: String, Equatable, Sendable {
  /// The shooter's own immediate tracer — `SHOT PREDICTED` in the packet.
  case predicted
  /// Another member's shot — `INCOMING SHOT`.
  case incoming
}

/// Why the fire gate refused a trigger press. Surfaced verbatim in the HUD so
/// the operator can tell a locked frame from a cooldown.
enum ArenaFireRefusal: String, Equatable, Sendable {
  case trackingLost
  case cooldown
  case noLocalPose
}

/// Trigger gate per requirements §3A.1: a lock is not permission to fire. The
/// shooter fires whenever *its own* tracking is normal and the cooldown has
/// elapsed; frame alignment governs what receivers draw, not whether you can
/// pull the trigger. Cooldown, not target state, governs the next press.
struct ArenaTracerFireGate: Equatable, Sendable {
  static let defaultCooldownMs: Int64 = 400

  let cooldownMs: Int64
  private var lastFiredAtMs: Int64?
  private(set) var shotsFired: Int64 = 0

  init(cooldownMs: Int64 = ArenaTracerFireGate.defaultCooldownMs) {
    self.cooldownMs = cooldownMs
  }

  func refusal(localTracking: ArenaLocalTracking, hasLocalPose: Bool, nowMs: Int64) -> ArenaFireRefusal? {
    guard localTracking == .normal else { return .trackingLost }
    guard hasLocalPose else { return .noLocalPose }
    if let lastFiredAtMs, nowMs - lastFiredAtMs < cooldownMs { return .cooldown }
    return nil
  }

  /// Records a shot and returns its per-shooter sequence for identity minting.
  mutating func recordFire(nowMs: Int64) -> Int64 {
    lastFiredAtMs = nowMs
    shotsFired += 1
    return shotsFired
  }

  static func shotId(shooterPlayerId: String, sequence: Int64) -> String {
    "\(shooterPlayerId)#\(sequence)"
  }
}

/// Exactly one tracer per shot identity per member. Bounded so a long run does
/// not grow without limit; identities older than the window are, by the rule,
/// "unknown" and therefore dropped rather than drawn.
struct ArenaTracerDedup: Equatable, Sendable {
  static let defaultCapacity = 512

  private let capacity: Int
  private var order: [String] = []
  private var seen: Set<String> = []

  init(capacity: Int = ArenaTracerDedup.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// `true` the first time an identity is offered; `false` for every repeat.
  mutating func admit(_ shotId: String) -> Bool {
    guard !seen.contains(shotId) else { return false }
    seen.insert(shotId)
    order.append(shotId)
    if order.count > capacity {
      let evicted = order.removeFirst()
      seen.remove(evicted)
    }
    return true
  }
}

/// One tracer as the renderer draws it: a segment in the arena frame that
/// fades out after `durationMs`. Length is the frozen maximum shot lane; the
/// tracer does not know or care whether anything was hit.
struct ArenaTracerSegment: Equatable, Sendable {
  static let durationMs: Int64 = 350
  static let lengthMeters = ArenaHitEvaluator.maximumLaneMeters

  let shotId: String
  let kind: ArenaTracerKind
  let origin: ArenaVector3
  let end: ArenaVector3
  let spawnedAtMs: Int64

  init(tracer: ArenaShotTracer, kind: ArenaTracerKind, spawnedAtMs: Int64) {
    shotId = tracer.shotId
    self.kind = kind
    origin = tracer.ray.origin
    end = tracer.ray.origin + tracer.ray.direction * Self.lengthMeters
    self.spawnedAtMs = spawnedAtMs
  }

  func isAlive(nowMs: Int64) -> Bool {
    nowMs - spawnedAtMs < Self.durationMs
  }
}

/// The member-local tracer ledger: dedup + transient segments + counters the
/// physical run reports. Pure; the session feeds it and the renderer reads it.
struct ArenaTracerLedger: Equatable, Sendable {
  private(set) var dedup = ArenaTracerDedup()
  private(set) var active: [ArenaTracerSegment] = []
  private(set) var predictedDrawn = 0
  private(set) var incomingDrawn = 0
  private(set) var duplicatesIgnored = 0
  private(set) var droppedWhileUnlocked = 0

  /// Shooter side. The caller has already passed the fire gate.
  mutating func present(own tracer: ArenaShotTracer, nowMs: Int64) {
    guard dedup.admit(tracer.shotId) else {
      duplicatesIgnored += 1
      return
    }
    predictedDrawn += 1
    active.append(ArenaTracerSegment(tracer: tracer, kind: .predicted, spawnedAtMs: nowMs))
  }

  /// Receiver side. A tracer in an unlocked frame would be drawn in the wrong
  /// place, which the packet treats as a wrong verdict; it is dropped, and the
  /// identity is still consumed so a later replay cannot draw it either.
  mutating func present(incoming tracer: ArenaShotTracer, lockState: ArenaLockState, nowMs: Int64) {
    guard dedup.admit(tracer.shotId) else {
      duplicatesIgnored += 1
      return
    }
    guard lockState.isLocked else {
      droppedWhileUnlocked += 1
      return
    }
    incomingDrawn += 1
    active.append(ArenaTracerSegment(tracer: tracer, kind: .incoming, spawnedAtMs: nowMs))
  }

  mutating func expire(nowMs: Int64) {
    active.removeAll { !$0.isAlive(nowMs: nowMs) }
  }
}
