import Foundation

/// No camera or network ownership. AR normal tracking alone never establishes
/// a measured shared frame, and old epochs/callbacks cannot reopen its gate.
struct DuelFramePolicy: Sendable {
  static let maximumSampleAge: TimeInterval = 0.100
  static let relocalizationTimeout: TimeInterval = 15
  static let requiredGoodResiduals = 3

  private(set) var snapshot = DuelFrameSnapshot()
  private var generation: UInt64 = 0
  private var latestEpoch: UInt16 = 0
  private var phaseDeadline: Date?
  private var sawRelocalizing = false
  private var lastObservationAt: Date?
  private var goodResiduals = 0
  private var lastResidualAt: Date?

  var operationToken: DuelFrameOperationToken? {
    snapshot.epoch.map { DuelFrameOperationToken(generation: generation, epoch: $0) }
  }

  func accepts(_ token: DuelFrameOperationToken) -> Bool {
    operationToken == token && snapshot.stage != .unaligned && snapshot.stage != .lost
  }

  mutating func beginCalibration(epoch: UInt16) throws {
    guard epoch > 0 else { throw DuelFrameFailure.invalidEpoch }
    guard epoch > latestEpoch else { throw DuelFrameFailure.staleEpoch }
    generation &+= 1
    latestEpoch = epoch
    snapshot = DuelFrameSnapshot(stage: .mapping, epoch: epoch)
    resetEvidence()
  }

  mutating func beginInstall(_ map: DuelFrameMap, at now: Date) throws {
    guard snapshot.epoch == map.epoch, map.epoch == latestEpoch else { throw DuelFrameFailure.staleEpoch }
    guard snapshot.stage == .mapping || snapshot.stage == .mapReady else { throw DuelFrameFailure.mapNotReady }
    generation &+= 1
    resetEvidence()
    snapshot = DuelFrameSnapshot(stage: .relocalizingWorld, epoch: map.epoch, frameID: map.frameID)
    phaseDeadline = now.addingTimeInterval(Self.relocalizationTimeout)
  }

  /// Returns true exactly once when the provider must run the body configuration.
  mutating func ingest(_ observation: DuelFrameObservation, at now: Date) -> Bool {
    guard observation.epoch == snapshot.epoch,
      snapshot.stage != .unaligned, snapshot.stage != .lost
    else { return false }
    if let phaseDeadline, now >= phaseDeadline {
      invalidate(reason: .relocalizationTimedOut)
      return false
    }
    if let frameID = snapshot.frameID, observation.frameID != frameID { return false }
    if let failure = observation.failure {
      invalidate(reason: failure)
      return false
    }
    guard Self.isFresh(observation.observedAt, at: now),
      lastObservationAt.map({ observation.observedAt > $0 }) ?? true
    else { return false }

    if snapshot.stage == .mapping || snapshot.stage == .mapReady {
      guard observation.phase == .mapping else { return false }
      lastObservationAt = observation.observedAt
      snapshot.stage = observation.tracking == .normal && observation.isMapped ? .mapReady : .mapping
      return false
    }
    guard observation.frameID == snapshot.frameID else { return false }
    let expectedPhase: DuelFrameSessionPhase = snapshot.stage == .relocalizingWorld
      ? .worldRelocalization : .bodyRelocalization
    guard observation.phase == expectedPhase else { return false }
    lastObservationAt = observation.observedAt

    if snapshot.stage == .relocalizingWorld || snapshot.stage == .relocalizingBody {
      if observation.tracking == .relocalizing { sawRelocalizing = true }
      guard sawRelocalizing, observation.tracking == .normal, let pose = observation.pose, pose.isValid,
        Self.isFresh(pose.capturedAt, at: now)
      else { return false }
      if snapshot.stage == .relocalizingWorld {
        snapshot.stage = .relocalizingBody
        sawRelocalizing = false
        phaseDeadline = now.addingTimeInterval(Self.relocalizationTimeout)
        return true
      }
      snapshot.stage = .awaitingResidual
      snapshot.localPose = pose
      phaseDeadline = nil
      return false
    }

    guard observation.tracking == .normal, let pose = observation.pose, pose.isValid,
      Self.isFresh(pose.capturedAt, at: now)
    else {
      invalidate(reason: .trackingLost)
      return false
    }
    snapshot.localPose = pose
    return false
  }

  mutating func recordResidual(
    frameID: String, epoch: UInt16, translationMeters: Double,
    yawDegrees: Double, observedAt: Date, now: Date
  ) throws {
    guard snapshot.epoch == epoch, snapshot.frameID == frameID else { throw DuelFrameFailure.staleEpoch }
    guard [.awaitingResidual, .aligned, .degraded].contains(snapshot.stage) else { throw DuelFrameFailure.mapNotReady }
    guard translationMeters.isFinite, yawDegrees.isFinite, translationMeters >= 0, yawDegrees >= 0,
      Self.isFresh(observedAt, at: now),
      lastResidualAt.map({ observedAt > $0 }) ?? true
    else { throw DuelFrameFailure.invalidResidual }
    lastResidualAt = observedAt
    guard translationMeters <= 0.10, yawDegrees <= 0.5 else {
      degrade(reason: .residualExceeded)
      throw DuelFrameFailure.residualExceeded
    }
    guard let pose = snapshot.localPose, Self.isFresh(pose.capturedAt, at: now) else {
      degrade(reason: .stalePose)
      throw DuelFrameFailure.stalePose
    }
    if let previous = snapshot.residual, !Self.isFresh(previous.observedAt, at: observedAt) { goodResiduals = 0 }
    goodResiduals += 1
    snapshot.residual = DuelFrameResidual(translationMeters: translationMeters, yawDegrees: yawDegrees, observedAt: observedAt)
    snapshot.failure = nil
    snapshot.stage = goodResiduals >= Self.requiredGoodResiduals ? .aligned : .awaitingResidual
  }

  mutating func tick(at now: Date) {
    if let phaseDeadline, now >= phaseDeadline {
      invalidate(reason: .relocalizationTimedOut)
      return
    }
    guard [.aligned, .awaitingResidual, .degraded].contains(snapshot.stage) else { return }
    if let pose = snapshot.localPose, !Self.isFresh(pose.capturedAt, at: now) {
      snapshot.localPose = nil
      if snapshot.stage == .aligned { degrade(reason: .stalePose) }
    }
    if let residual = snapshot.residual, !Self.isFresh(residual.observedAt, at: now) {
      degrade(reason: .staleResidual)
    }
  }

  mutating func invalidate(reason: DuelFrameFailure) {
    generation &+= 1
    snapshot.stage = .lost
    snapshot.failure = reason
    resetEvidence()
  }

  mutating func referenceUnavailable() {
    guard [.awaitingResidual, .aligned, .degraded].contains(snapshot.stage) else { return }
    let stillCalibrating = snapshot.stage == .awaitingResidual
    degrade(reason: .referenceUnavailable)
    if stillCalibrating { snapshot.stage = .awaitingResidual }
  }

  mutating func stop() {
    generation &+= 1
    latestEpoch = 0
    snapshot = DuelFrameSnapshot()
    resetEvidence()
  }

  static func isFresh(_ date: Date, at now: Date) -> Bool {
    let age = now.timeIntervalSince(date)
    return age.isFinite && age >= 0 && age <= maximumSampleAge
  }

  private mutating func degrade(reason: DuelFrameFailure) {
    snapshot.stage = .degraded
    snapshot.failure = reason
    snapshot.residual = nil
    goodResiduals = 0
  }

  private mutating func resetEvidence() {
    snapshot.localPose = nil
    snapshot.residual = nil
    phaseDeadline = nil
    sawRelocalizing = false
    lastObservationAt = nil
    goodResiduals = 0
    lastResidualAt = nil
  }
}
