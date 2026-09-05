import Combine
import Foundation

/// App-facing orchestrator for the existing playable targeting session. Network
/// authentication, map distribution, and independent residual measurements stay
/// with app composition; this object never owns a second camera or AR delegate.
@MainActor
final class DuelFrameProvider: ObservableObject {
  @Published private(set) var snapshot = DuelFrameSnapshot()
  private let targeting: any DuelFrameSessionDriving
  private var policy = DuelFramePolicy()
  private var installedMap: DuelFrameMap?
  private var observationsTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?

  init(targeting: any DuelFrameSessionDriving) {
    self.targeting = targeting
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

  func beginCalibration(epoch: UInt16) async throws {
    try policy.beginCalibration(epoch: epoch)
    installedMap = nil
    publish()
    startWatchdog()
    let token = policy.operationToken!
    do {
      try await targeting.beginFrameMapping(epoch: epoch)
      guard policy.accepts(token) else { throw DuelFrameFailure.operationSuperseded }
    } catch {
      fail(error, ifCurrent: token)
      throw error
    }
  }

  func captureMap() async throws -> DuelFrameMap {
    guard snapshot.stage == .mapReady, let token = policy.operationToken else { throw DuelFrameFailure.mapNotReady }
    let bytes = try await targeting.captureFrameMap(epoch: token.epoch)
    guard policy.accepts(token), snapshot.stage == .mapReady else { throw DuelFrameFailure.operationSuperseded }
    return try DuelFrameMap(epoch: token.epoch, bytes: bytes)
  }

  /// Both the capturing phone and every receiving phone install identical bytes.
  /// ARKit relocalizes in world tracking before a second, map-seeded body run.
  func installMap(_ map: DuelFrameMap) async throws {
    try policy.beginInstall(map, at: Date())
    installedMap = map
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
    try policy.recordResidual(frameID: frameID, epoch: epoch, translationMeters: translationMeters,
      yawDegrees: yawDegrees, observedAt: observedAt, now: Date())
  }

  func invalidate(reason: DuelFrameFailure) {
    policy.invalidate(reason: reason)
    installedMap = nil
    publish()
  }

  func stop() async {
    policy.stop()
    installedMap = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    publish()
    await targeting.endFrameMapping()
  }

  private func receive(_ observation: DuelFrameObservation) async {
    let switchToBody = policy.ingest(observation, at: Date())
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
        policy.tick(at: Date())
        publish()
      }
    }
  }

  private func fail(_ error: any Error, ifCurrent token: DuelFrameOperationToken) {
    guard policy.accepts(token) else { return }
    policy.invalidate(reason: error as? DuelFrameFailure ?? .cameraUnavailable)
    installedMap = nil
    publish()
  }

  private func publish() {
    if snapshot != policy.snapshot { snapshot = policy.snapshot }
  }
}

/// Latest-only delivery bounds the camera→UI queue independently of frame rate.
final class DuelFrameObservationHub: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<DuelFrameObservation>.Continuation] = [:]

  func stream() -> AsyncStream<DuelFrameObservation> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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

  func yield(_ observation: DuelFrameObservation) {
    lock.lock()
    let current = Array(continuations.values)
    lock.unlock()
    for continuation in current { continuation.yield(observation) }
  }

  func finish() {
    lock.lock()
    let current = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in current { continuation.finish() }
  }
}
