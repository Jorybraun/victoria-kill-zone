import Foundation

// MARK: - Shared-arena lock policy (KIL-20)
//
// Decides whether the shared frame is trustworthy enough to expose spatial
// state. It never authorizes fire — spatial firing stays disabled in KIL-20 —
// but it is the gate that later slices will put in front of the hit evaluator,
// so it must fail closed and must never let stale transforms survive a loss.

struct ArenaLockThresholds: Equatable, Sendable {
  /// Proposed §3.2 budget split from the shared-arena research: 0.10 m and
  /// 0.5° at 15 m. KIL-20 measurements validate or re-cut these numbers.
  var maxTranslationResidualMeters: Double = 0.10
  var maxYawResidualDegrees: Double = 0.5
  /// Frozen maximum pose age from the spatial-hit requirements.
  var maxPeerAgeMs: Int64 = ArenaPoseHistory.maximumPoseAgeMs
  /// Consecutive clean evaluations required before (re)locking, so a single
  /// good frame after a loss cannot re-open the gate.
  var lockConsecutiveEvaluations: Int = 10

  static let phaseOne = ArenaLockThresholds()
}

struct ArenaPeerObservation: Equatable, Sendable {
  let tracking: ArenaTrackingQuality
  /// Age of the newest accepted peer sample on this phone's clock.
  let ageMs: Int64
  /// Self-reported vs observed disagreement, when the frame method can
  /// measure one (collaborative sessions via `ARParticipantAnchor`).
  let residual: ArenaAlignmentResidual?
}

struct ArenaLockObservation: Equatable, Sendable {
  let localTracking: ArenaLocalTracking
  let mappingStatus: ArenaMappingStatus
  /// Collaborative: a participant anchor for the peer has been received.
  /// World map: this phone relocalized against the host's map (or is the host).
  let mergeObserved: Bool
  let peer: ArenaPeerObservation?
}

enum ArenaLockBlocker: String, Equatable, Sendable {
  case localTracking
  case mapping
  case awaitingMerge
  case awaitingPeer
  case peerTracking
  case peerStale
  case residualTranslation
  case residualYaw
  /// Every check passes but the consecutive-evaluation streak is not met yet.
  case stabilizing
}

enum ArenaLockState: Equatable, Sendable {
  case aligning(ArenaLockBlocker)
  case lockReady
  case trackingLost(ArenaLockBlocker)

  var isLocked: Bool { self == .lockReady }

  var label: String {
    switch self {
    case .aligning(let blocker): "aligning:\(blocker.rawValue)"
    case .lockReady: "lockReady"
    case .trackingLost(let blocker): "trackingLost:\(blocker.rawValue)"
    }
  }
}

struct ArenaLockDecision: Equatable, Sendable {
  let state: ArenaLockState
  /// True exactly on the transition out of `lockReady`. The owner must drop
  /// every buffered peer transform so recovery cannot replay stale poses.
  let clearsHistory: Bool
  /// Set on the evaluation that restores `lockReady` after a loss.
  let recoveryMs: Int64?
}

struct SharedArenaLockPolicy: Equatable, Sendable {
  let thresholds: ArenaLockThresholds
  private(set) var state: ArenaLockState = .aligning(.awaitingPeer)
  private var cleanStreak = 0
  private var lostAtMs: Int64?

  init(thresholds: ArenaLockThresholds = .phaseOne) {
    self.thresholds = thresholds
  }

  mutating func evaluate(_ observation: ArenaLockObservation, nowMs: Int64) -> ArenaLockDecision {
    if let blocker = blocker(for: observation) {
      cleanStreak = 0
      let wasLocked = state.isLocked
      switch state {
      case .lockReady:
        lostAtMs = nowMs
        state = .trackingLost(blocker)
      case .trackingLost:
        state = .trackingLost(blocker)
      case .aligning:
        state = .aligning(blocker)
      }
      return ArenaLockDecision(state: state, clearsHistory: wasLocked, recoveryMs: nil)
    }

    if state.isLocked {
      return ArenaLockDecision(state: state, clearsHistory: false, recoveryMs: nil)
    }

    cleanStreak += 1
    guard cleanStreak >= thresholds.lockConsecutiveEvaluations else {
      state = state.isLost ? .trackingLost(.stabilizing) : .aligning(.stabilizing)
      return ArenaLockDecision(state: state, clearsHistory: false, recoveryMs: nil)
    }

    let recovery = lostAtMs.map { nowMs - $0 }
    lostAtMs = nil
    state = .lockReady
    return ArenaLockDecision(state: state, clearsHistory: false, recoveryMs: recovery)
  }

  private func blocker(for observation: ArenaLockObservation) -> ArenaLockBlocker? {
    guard observation.localTracking == .normal else { return .localTracking }

    // Initial lock demands a fully mapped local scene; once locked, the map
    // legitimately toggles between `extending` and `mapped` as players move.
    let minimumMapping: ArenaMappingStatus = state.isLocked ? .extending : .mapped
    guard observation.mappingStatus.rank >= minimumMapping.rank else { return .mapping }
    guard observation.mergeObserved else { return .awaitingMerge }
    guard let peer = observation.peer else { return .awaitingPeer }
    guard peer.tracking == .normal else { return .peerTracking }
    guard peer.ageMs >= 0, peer.ageMs <= thresholds.maxPeerAgeMs else { return .peerStale }
    if let residual = peer.residual {
      guard residual.translationMeters.isFinite,
        residual.translationMeters <= thresholds.maxTranslationResidualMeters
      else { return .residualTranslation }
      guard residual.yawDegrees.isFinite,
        residual.yawDegrees <= thresholds.maxYawResidualDegrees
      else { return .residualYaw }
    }
    return nil
  }
}

private extension ArenaLockState {
  var isLost: Bool {
    if case .trackingLost = self { return true }
    return false
  }
}

extension ArenaMappingStatus {
  var rank: Int {
    switch self {
    case .notAvailable: 0
    case .limited: 1
    case .extending: 2
    case .mapped: 3
    }
  }
}
