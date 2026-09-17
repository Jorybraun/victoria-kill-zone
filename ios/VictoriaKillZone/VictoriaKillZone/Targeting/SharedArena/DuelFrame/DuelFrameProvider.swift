import Combine
import Foundation

/// App-facing orchestrator for the existing playable targeting session. Network
/// authentication, map distribution, and independent residual measurements stay
/// with app composition; this object never owns a second camera or AR delegate.
@MainActor
final class DuelFrameProvider: ObservableObject {
  @Published private(set) var snapshot = DuelFrameSnapshot()
  @Published private(set) var referenceState: DuelFrameReferenceState = .unavailable {
    didSet { recordReferenceChange(from: oldValue) }
  }
  private let targeting: any DuelFrameSessionDriving
  private let now: @MainActor () -> Date
  private var policy = DuelFramePolicy()
  private var installedMap: DuelFrameMap?
  private var capturedReference: DuelFrameReference?
  private var referencePolicy = DuelFrameReferencePolicy()
  private var diagnostics: DuelFrameDiagnostics
  private var lastTrackingDiagnostic: (tracking: DuelFrameTracking, mapped: Bool)?
  private var calibrationStartedAt: Date?
  private var installStartedAt: Date?
  var referenceImageData: Data? { installedMap?.reference?.imageData ?? capturedReference?.imageData }
  private var observationsTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?

  init(targeting: any DuelFrameSessionDriving, now: @escaping @MainActor () -> Date = Date.init) {
    self.targeting = targeting
    self.now = now
    self.diagnostics = DuelFrameDiagnostics(startedAt: now())
    let observations = targeting.duelFrameObservations()
    observationsTask = Task { [weak self] in
      for await observation in observations {
        guard !Task.isCancelled else { return }
        await self?.receive(observation)
      }
    }
  }

  deinit {
    observationsTask?.cancel()
    watchdogTask?.cancel()
  }

  func beginCalibration(epoch: UInt16, captureRequired: Bool = true,
    mode: DuelFrameAlignmentMode = .measured
  ) async throws {
    try policy.beginCalibration(epoch: epoch, captureRequired: captureRequired, mode: mode, at: now())
    diagnostics.reset(at: now())
    diagnostics.record("stage", "beginCalibration epoch=\(epoch) captureRequired=\(captureRequired) mode=\(mode)", at: now())
    calibrationStartedAt = now(); installStartedAt = nil; lastTrackingDiagnostic = nil
    installedMap = nil
    capturedReference = nil
    referenceState = .unavailable
    referencePolicy = DuelFrameReferencePolicy()
    publish()
    startWatchdog()
    let token = policy.operationToken!
    do {
      try await targeting.beginFrameMapping(epoch: epoch, mode: mode)
      guard policy.accepts(token) else { throw DuelFrameFailure.operationSuperseded }
    } catch {
      fail(error, ifCurrent: token)
      throw error
    }
  }

  func captureMap() async throws -> DuelFrameMap {
    guard snapshot.stage == .mapReady, let token = policy.operationToken else { throw DuelFrameFailure.mapNotReady }
    let reference: DuelFrameReference?
    if snapshot.mode == .measured {
      guard let captured = capturedReference, referenceState == .captured(captured.summary) else {
        throw DuelFrameFailure.referenceUnavailable
      }
      reference = captured
    } else {
      reference = nil
    }
    let bytes = try await targeting.captureFrameMap(epoch: token.epoch)
    // The driver validates capture quality. Later scan fluctuations do not
    // invalidate its result; replacement or loss of this mapping run does.
    guard policy.accepts(token) else { throw DuelFrameFailure.operationSuperseded }
    // Relocalized mode shares the raw world-map archive; the bundle decoder
    // reads it back with no reference.
    if let reference {
      return try DuelFrameMap(epoch: token.epoch,
        bytes: try DuelFrameCalibrationBundle.encode(worldMap: bytes, reference: reference))
    }
    return try DuelFrameMap(epoch: token.epoch, bytes: bytes)
  }

  @discardableResult
  func captureReference() async throws -> DuelFrameReferenceSummary {
    guard snapshot.mode == .measured else { throw DuelFrameFailure.referenceUnavailable }
    guard snapshot.stage == .mapReady, let token = policy.operationToken,
      referenceState != .capturing else { throw DuelFrameFailure.mapNotReady }
    capturedReference = nil
    referenceState = .capturing
    do {
      let reference = try await targeting.captureFrameReference(epoch: token.epoch)
      guard policy.accepts(token) else { throw DuelFrameFailure.operationSuperseded }
      guard reference.isValid else { throw DuelFrameFailure.referenceUnsuitable }
      capturedReference = reference
      referenceState = .captured(reference.summary)
      return reference.summary
    } catch {
      if policy.accepts(token) { referenceState = .failed(error as? DuelFrameFailure ?? .referenceUnsuitable) }
      throw error
    }
  }

  /// Both the capturing phone and every receiving phone install identical bytes.
  /// ARKit relocalizes in world tracking before a second, map-seeded body run.
  func installMap(_ map: DuelFrameMap) async throws {
    try policy.beginInstall(map, at: now())
    installStartedAt = now()
    installedMap = map
    referenceState = map.reference.map { .captured($0.summary) } ?? .unavailable
    referencePolicy = DuelFrameReferencePolicy()
    publish()
    let token = policy.operationToken!
    do {
      try await targeting.installFrameMap(map, phase: .worldRelocalization)
      guard policy.accepts(token) else { throw DuelFrameFailure.operationSuperseded }
    } catch {
      fail(error, ifCurrent: token)
      throw error
    }
  }

  /// Supply a measured common-scene residual. Matching saved-map coordinates or
  /// treating a player's independently rotated phone as their head is not proof.
  func recordResidual(
    frameID: String, epoch: UInt16, translationMeters: Double,
    yawDegrees: Double, observedAt: Date
  ) throws {
    defer { publish() }
    try applyResidual(frameID: frameID, epoch: epoch, translationMeters: translationMeters,
      yawDegrees: yawDegrees, observedAt: observedAt, at: now())
  }

  func invalidate(reason: DuelFrameFailure) {
    policy.invalidate(reason: reason)
    diagnostics.record("failure", reason.rawValue, at: now())
    installedMap = nil
    capturedReference = nil
    referenceState = .unavailable
    publish()
  }

  func stop() async {
    policy.stop()
    installedMap = nil
    capturedReference = nil
    referenceState = .unavailable
    referencePolicy = DuelFrameReferencePolicy()
    watchdogTask?.cancel()
    watchdogTask = nil
    publish()
    await targeting.endFrameMapping()
  }

  /// Archived peer-bound ARSession.CollaborationData, in emission order.
  /// Collaborative matches wire this to the match transport; other modes get
  /// an already-finished stream.
  func collaborationOutputs() -> AsyncStream<Data> { targeting.duelFrameCollaboration() }

  /// Forwards a peer's archived collaboration delta into the AR session.
  /// Undecodable deltas are dropped and logged; alignment is unaffected.
  func applyCollaboration(_ data: Data) async {
    do {
      try await targeting.applyFrameCollaboration(data)
    } catch {
      diagnostics.record("collab", "apply-failed \(data.count)B", at: now())
    }
  }

  private func receive(_ observation: DuelFrameObservation) async {
    let evaluatedAt = now()
    recordTracking(observation, at: evaluatedAt)
    let switchToBody = policy.ingest(observation, at: evaluatedAt)
    if observation.phase == .bodyRelocalization, observation.epoch == snapshot.epoch,
      observation.frameID == snapshot.frameID {
      if let expected = installedMap?.reference, let sample = observation.referenceObservation {
        do {
          if let residual = try referencePolicy.measure(sample, expected: expected, now: evaluatedAt) {
            try applyResidual(frameID: observation.frameID!, epoch: observation.epoch,
              translationMeters: residual.translationMeters, yawDegrees: residual.yawDegrees,
              observedAt: residual.observedAt, at: evaluatedAt)
          }
        } catch DuelFrameFailure.residualExceeded {
          // recordResidual already revoked readiness; preserve its useful reason.
        } catch { policy.referenceUnavailable() }
      } else { policy.referenceUnavailable() }
    }
    publish()
    guard switchToBody, let map = installedMap, let token = policy.operationToken else { return }
    do {
      try await targeting.installFrameMap(map, phase: .bodyRelocalization)
      guard policy.accepts(token) else { return }
    } catch {
      fail(error, ifCurrent: token)
    }
  }

  private func startWatchdog() {
    guard watchdogTask == nil else { return }
    watchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard let self else { return }
        policy.tick(at: now())
        publish()
      }
    }
  }

  private func fail(_ error: any Error, ifCurrent token: DuelFrameOperationToken) {
    guard policy.accepts(token) else { return }
    let failure = error as? DuelFrameFailure ?? .cameraUnavailable
    policy.invalidate(reason: failure)
    diagnostics.record("failure", failure.rawValue, at: now())
    installedMap = nil
    capturedReference = nil
    referenceState = .failed(failure)
    publish()
  }

  func exportDiagnostics() throws -> URL { try diagnostics.export() }

  private func publish() {
    let previous = snapshot
    guard previous != policy.snapshot else { return }
    snapshot = policy.snapshot
    let at = now()
    if previous.stage != snapshot.stage {
      var detail = "\(previous.stage.rawValue) -> \(snapshot.stage.rawValue)"
      if let failure = snapshot.failure { detail += " (\(failure.rawValue))" }
      diagnostics.record("stage", detail, at: at)
      if snapshot.stage == .mapReady, let started = calibrationStartedAt {
        diagnostics.record("timing", "mapReady after \(Int64(at.timeIntervalSince(started) * 1000))ms", at: at)
        calibrationStartedAt = nil
      }
      if snapshot.stage == .aligned, let started = installStartedAt {
        diagnostics.record("timing", "aligned after \(Int64(at.timeIntervalSince(started) * 1000))ms", at: at)
        installStartedAt = nil
      }
    }
    if previous.scanFeedback != snapshot.scanFeedback {
      diagnostics.record("scanFeedback", "\(snapshot.scanFeedback)", at: at)
    }
  }

  private func recordTracking(_ observation: DuelFrameObservation, at: Date) {
    let current = (tracking: observation.tracking, mapped: observation.isMapped)
    if let last = lastTrackingDiagnostic, last == current { return }
    lastTrackingDiagnostic = current
    diagnostics.record("tracking",
      "\(observation.tracking) mapped=\(observation.isMapped) phase=\(observation.phase)", at: at)
  }

  private func applyResidual(frameID: String, epoch: UInt16, translationMeters: Double,
    yawDegrees: Double, observedAt: Date, at: Date) throws {
    let outcome: String
    do {
      try policy.recordResidual(frameID: frameID, epoch: epoch, translationMeters: translationMeters,
        yawDegrees: yawDegrees, observedAt: observedAt, now: at)
      outcome = "accepted"
    } catch {
      outcome = (error as? DuelFrameFailure).map { $0 == .residualExceeded ? "exceeded" : $0.rawValue } ?? "error"
      diagnostics.record("residual",
        String(format: "t=%.3fm yaw=%.2fdeg %@", translationMeters, yawDegrees, outcome), at: at)
      throw error
    }
    diagnostics.record("residual",
      String(format: "t=%.3fm yaw=%.2fdeg %@", translationMeters, yawDegrees, outcome), at: at)
  }

  private func recordReferenceChange(from old: DuelFrameReferenceState) {
    guard old != referenceState else { return }
    let detail: String
    switch referenceState {
    case .unavailable: detail = "unavailable"
    case .capturing: detail = "capturing"
    case .captured(let summary):
      let reference = capturedReference ?? installedMap?.reference
      detail = String(format: "captured w=%.3fm h=%.3fm samples=%d deviation=%.3fm",
        summary.widthMeters, summary.heightMeters,
        reference?.sampleCount ?? 0, reference?.maximumCornerDeviationMeters ?? 0)
    case .failed(let failure): detail = "failed \(failure.rawValue)"
    }
    diagnostics.record("reference", detail, at: now())
  }
}

/// Latest-only delivery bounds the camera→UI queue independently of frame rate.
/// Collaboration deltas instead buffer every value: they must apply in order.
final class DuelFrameStreamHub<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
  private let buffering: AsyncStream<Value>.Continuation.BufferingPolicy

  init(buffering: AsyncStream<Value>.Continuation.BufferingPolicy = .bufferingNewest(1)) {
    self.buffering = buffering
  }

  func stream() -> AsyncStream<Value> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: buffering) { continuation in
      lock.lock()
      continuations[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        lock.lock()
        continuations[id] = nil
        lock.unlock()
      }
    }
  }

  func yield(_ value: Value) {
    lock.lock()
    let current = Array(continuations.values)
    lock.unlock()
    for continuation in current { continuation.yield(value) }
  }

  func finish() {
    lock.lock()
    let current = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in current { continuation.finish() }
  }
}

typealias DuelFrameObservationHub = DuelFrameStreamHub<DuelFrameObservation>
