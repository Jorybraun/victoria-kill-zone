import Foundation

enum SharedOriginPhase: String, Equatable, Sendable {
  case idle, searching, observing, interrupted, timedOut, stopped
}

struct SharedOriginMeasurement: Equatable, Sendable {
  let localFromArena: ArenaRigidTransform
  let arenaFromPhone: ArenaRigidTransform
  let capturedUptimeMs: Double
  let frameTimestamp: Double
}

/// Pure measurement state, v1. Owns a temporary coordinate frame, never readiness.
/// Source samples expire locally; peer expiry is RECEIPT age, not end-to-end age.
struct SharedOriginPolicy: Sendable {
  static let maximumSampleAgeMs: Double = 100
  static let searchTimeoutMs: Double = 30_000
  let runID: UUID
  private(set) var epoch: UInt64 = 0
  private(set) var originID: UUID?
  private(set) var phase: SharedOriginPhase = .idle
  private(set) var measurement: SharedOriginMeasurement?
  private(set) var peerSequence: UInt64 = 0
  private(set) var peerCapturedUptimeMs: Double?
  private(set) var peerSourceAgeMs: Double?
  private(set) var peerReceivedAtMs: Double?
  private(set) var peerArenaFromPhone: ArenaRigidTransform?
  private var searchStartedAtMs: Double = 0
  private var lastFrameTimestamp: Double?

  init(runID: UUID) {self.runID = runID}

  mutating func begin(epoch: UInt64, nowMs: Double) throws {
    guard epoch > self.epoch, nowMs.isFinite, nowMs >= 0 else {throw SharedOriginFailure.invalidEpoch}
    self.epoch = epoch; phase = .searching; originID = nil
    searchStartedAtMs = nowMs; lastFrameTimestamp = nil
    measurement = nil; clearPeer()
  }

  @discardableResult
  mutating func adoptOrigin(runID: UUID, epoch: UInt64, originID: UUID) -> Bool {
    guard accepts(runID: runID, epoch: epoch), self.originID == nil || self.originID == originID else {return false}
    self.originID = originID
    return true
  }

  /// The anchor must be present in this newly delivered frame. A cached transform
  /// from an earlier frame cannot keep the local coordinate conversion alive.
  @discardableResult
  mutating func observeLocal(runID: UUID, epoch: UInt64, originID: UUID,
    localFromArena: ArenaRigidTransform?, localFromPhone: ArenaRigidTransform?, trackingNormal: Bool,
    frameTimestamp: Double, capturedUptimeMs: Double, nowMs: Double) -> Bool {
    guard accepts(runID: runID, epoch: epoch), self.originID == originID else {return false}
    tick(nowMs: nowMs)
    guard accepts(runID: runID, epoch: epoch), frameTimestamp.isFinite,
      lastFrameTimestamp.map({frameTimestamp > $0}) ?? true else {return false}
    lastFrameTimestamp = frameTimestamp
    guard trackingNormal, fresh(capturedUptimeMs, nowMs: nowMs),
      let localFromArena, let localFromPhone,
      let arenaFromPhone = try? localFromArena.inverse().composed(with: localFromPhone) else {
      revokeLocalMeasurement()
      return false
    }
    measurement = .init(localFromArena: localFromArena, arenaFromPhone: arenaFromPhone,
      capturedUptimeMs: capturedUptimeMs, frameTimestamp: frameTimestamp)
    return true
  }

  @discardableResult
  mutating func receivePose(_ message: SharedOriginWireMessage, at receivedAtMs: Double, evaluatedAt: Double? = nil) -> Bool {
    let nowMs = evaluatedAt ?? receivedAtMs
    tick(nowMs: nowMs)
    guard accepts(runID: message.runID, epoch: message.epoch), fresh(receivedAtMs, nowMs: nowMs),
      case .pose(let origin, let sequence, let captured, let age, let trackingNormal, let matrix) = message.body,
      originID == origin, sequence > peerSequence, captured.isFinite, captured >= 0,
      peerCapturedUptimeMs.map({captured > $0}) ?? true,
      age.isFinite, age >= 0, age <= Self.maximumSampleAgeMs,
      peerReceivedAtMs.map({receivedAtMs >= $0}) ?? true,
      let transform = try? ArenaRigidTransform(columnMajor: matrix) else {return false}
    peerSequence = sequence; peerCapturedUptimeMs = captured; peerSourceAgeMs = age; peerReceivedAtMs = receivedAtMs
    peerArenaFromPhone = trackingNormal ? transform : nil
    if localMeasurement(at: nowMs) != nil, peerArenaFromPhone != nil {phase = .observing}
    return true
  }

  func localMeasurement(at nowMs: Double) -> SharedOriginMeasurement? {
    guard phase == .searching || phase == .observing, let measurement,
      fresh(measurement.capturedUptimeMs, nowMs: nowMs) else {return nil}
    return measurement
  }

  func peerReceiptAge(at nowMs: Double) -> Double? {
    guard let received = peerReceivedAtMs, fresh(received, nowMs: nowMs) else {return nil}
    return nowMs - received
  }

  func localFromPeer(at nowMs: Double) -> ArenaRigidTransform? {
    guard let local = localMeasurement(at: nowMs), peerReceiptAge(at: nowMs) != nil,
      let peerArenaFromPhone else {return nil}
    return try? local.localFromArena.composed(with: peerArenaFromPhone)
  }

  mutating func tick(nowMs: Double) {
    guard nowMs.isFinite else {return}
    if phase == .searching, nowMs - searchStartedAtMs >= Self.searchTimeoutMs {invalidate(.timedOut)}
    if let measurement, !fresh(measurement.capturedUptimeMs, nowMs: nowMs) {self.measurement = nil}
    if peerReceiptAge(at: nowMs) == nil {peerArenaFromPhone = nil}
  }

  mutating func invalidate(_ phase: SharedOriginPhase = .interrupted) {
    self.phase = phase; originID = nil; measurement = nil; lastFrameTimestamp = nil; clearPeer()
  }

  mutating func revokeLocalMeasurement() {measurement = nil; peerArenaFromPhone = nil}

  private func accepts(runID: UUID, epoch: UInt64) -> Bool {
    self.runID == runID && self.epoch == epoch && (phase == .searching || phase == .observing)
  }

  private func fresh(_ captured: Double, nowMs: Double) -> Bool {
    captured.isFinite && nowMs.isFinite && captured >= 0 && nowMs >= captured && nowMs - captured <= Self.maximumSampleAgeMs
  }

  private mutating func clearPeer() {
    peerSequence = 0; peerCapturedUptimeMs = nil; peerSourceAgeMs = nil
    peerReceivedAtMs = nil; peerArenaFromPhone = nil
  }
}

/// ARFrame capture timestamps are seconds since boot, not callback receipt time.
/// Cross-reference: developers.google.com/ar/reference/ios/interface/GARFrame#timestamp
enum SharedOriginSensorTime {
  static func capturedUptimeMs(frameTimestamp: Double, nowMs: Double) -> Double? {
    let captured = frameTimestamp * 1_000
    guard captured.isFinite, captured >= 0, nowMs.isFinite, nowMs >= captured,
      nowMs - captured <= SharedOriginPolicy.maximumSampleAgeMs else {return nil}
    return captured
  }
}
