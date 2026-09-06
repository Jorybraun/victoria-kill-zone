import Foundation
import XCTest

@testable import VictoriaKillZone

final class DuelFramePolicyTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)
  private let matrix: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

  func testMapMustBeMappedAndBothConfigurationRunsMustActuallyRelocalize() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1)
    let map = try DuelFrameMap(epoch: 1, bytes: Data([1, 2, 3]))
    ingest(&policy, phase: .mapping, tracking: .normal, time: 0, mapped: false)
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 0.01, mapped: true)
    XCTAssertEqual(policy.snapshot.stage, .mapReady)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base))
    try policy.beginInstall(map, at: base)

    XCTAssertFalse(ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 0.02))
    XCTAssertEqual(policy.snapshot.stage, .relocalizingWorld, "Old normal frames must not prove map installation")
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .relocalizing, time: 0.03)
    XCTAssertTrue(ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 0.04))
    XCTAssertFalse(ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 0.05))
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.06)
    XCTAssertEqual(policy.snapshot.stage, .relocalizingBody)
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .relocalizing, time: 0.07)
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.08)
    XCTAssertEqual(policy.snapshot.stage, .awaitingResidual)
    XCTAssertNotNil(policy.snapshot.localPose, "Pose streaming must bootstrap before fire permission")
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.08)))
  }

  func testThreeFreshIndependentResidualsUnlockAndInstantFreshnessCheckClosesGate() throws {
    var (policy, map) = try awaitingResidual()
    for time in [0.50, 0.54, 0.58] {
      ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: time)
      try residual(&policy, map: map, time: time)
    }
    XCTAssertEqual(policy.snapshot.stage, .aligned)
    XCTAssertTrue(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.59)))
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.69)), "No timer tick is required to expire permission")
    policy.tick(at: base.addingTimeInterval(0.69))
    XCTAssertEqual(policy.snapshot.stage, .degraded)
    XCTAssertNil(policy.snapshot.localPose)
  }

  func testMissingResidualNeverUnlocksEvenAfterManyNormalFrames() throws {
    var (policy, map) = try awaitingResidual()
    for index in 1...100 {
      ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.4 + Double(index) / 20)
    }
    XCTAssertEqual(policy.snapshot.stage, .awaitingResidual)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(5.4)))
  }

  func testBadResidualRevokesPermissionAndCannotReplayOlderEvidence() throws {
    var (policy, map) = try awaitingResidual()
    for time in [0.50, 0.53, 0.56] {
      ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: time)
      try residual(&policy, map: map, time: time)
    }
    XCTAssertThrowsError(try residual(&policy, map: map, time: 0.57, translation: 0.11))
    XCTAssertEqual(policy.snapshot.stage, .degraded)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.57)))
    XCTAssertThrowsError(try residual(&policy, map: map, time: 0.56))
  }

  func testTrackingLossClearsPoseAndNeedsANewEpoch() throws {
    var (policy, map) = try awaitingResidual()
    let token = try XCTUnwrap(policy.operationToken)
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .limited, time: 0.5)
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertNil(policy.snapshot.localPose)
    XCTAssertFalse(policy.accepts(token))
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.6)
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertThrowsError(try policy.beginCalibration(epoch: 1))
    try policy.beginCalibration(epoch: 2)
    XCTAssertEqual(policy.snapshot.stage, .mapping)
  }

  func testOldEpochAndWrongMapCallbacksCannotMutateCurrentCalibration() throws {
    var (policy, map) = try awaitingResidual()
    let token = try XCTUnwrap(policy.operationToken)
    try policy.beginCalibration(epoch: 2)
    XCTAssertFalse(policy.accepts(token))
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.6)
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    XCTAssertThrowsError(try policy.beginInstall(map, at: base))
    let nextMap = try DuelFrameMap(epoch: 2, bytes: Data([9]))
    try policy.beginInstall(nextMap, at: base)
    let wrongMap = try DuelFrameMap(epoch: 2, bytes: Data([8]))
    ingest(&policy, map: wrongMap, phase: .worldRelocalization, tracking: .relocalizing, time: 0.7)
    ingest(&policy, map: nextMap, phase: .worldRelocalization, tracking: .normal, time: 0.8)
    XCTAssertEqual(policy.snapshot.stage, .relocalizingWorld)
  }

  func testRelocalizationTimeoutAlsoAppliesWhenWatchdogWasDelayed() throws {
    var policy = DuelFramePolicy()
    let map = try DuelFrameMap(epoch: 1, bytes: Data([1]))
    try policy.beginCalibration(epoch: 1)
    try policy.beginInstall(map, at: base)
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .relocalizing, time: 1)
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 15.01)
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .relocalizationTimedOut)
  }

  func testInvalidAndStaleResidualsAreRejected() throws {
    var (policy, map) = try awaitingResidual()
    for value in [-1, Double.nan, .infinity] {
      XCTAssertThrowsError(try residual(&policy, map: map, time: 0.41, translation: value))
    }
    XCTAssertThrowsError(try policy.recordResidual(frameID: map.frameID, epoch: map.epoch,
      translationMeters: 0, yawDegrees: 0, observedAt: base, now: base.addingTimeInterval(0.4)))
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.41)))
  }

  func testStopInvalidatesInFlightTokensAndAllowsANewMatchEpochSequence() throws {
    var (policy, _) = try awaitingResidual()
    let token = try XCTUnwrap(policy.operationToken)
    policy.stop()
    XCTAssertFalse(policy.accepts(token))
    XCTAssertEqual(policy.snapshot.stage, .unaligned)
    try policy.beginCalibration(epoch: 1)
    XCTAssertFalse(policy.accepts(token))
  }

  func testMapHashIntegrityAndAllocationBounds() throws {
    let bytes = Data([1, 2, 3])
    let map = try DuelFrameMap(epoch: 1, bytes: bytes)
    XCTAssertEqual(map.frameID.count, 64)
    XCTAssertEqual(try DuelFrameMap(epoch: 1, bytes: bytes, expectedFrameID: map.frameID), map)
    XCTAssertThrowsError(try DuelFrameMap(epoch: 0, bytes: bytes))
    XCTAssertThrowsError(try DuelFrameMap(epoch: 1, bytes: Data()))
    XCTAssertThrowsError(try DuelFrameMap(epoch: 1, bytes: Data([3, 2, 1]), expectedFrameID: map.frameID))
    XCTAssertThrowsError(try DuelFrameMap(epoch: 1, bytes: Data(count: DuelFrameMap.maximumBytes + 1)))
  }

  private func awaitingResidual() throws -> (DuelFramePolicy, DuelFrameMap) {
    var policy = DuelFramePolicy()
    let map = try DuelFrameMap(epoch: 1, bytes: Data([1]))
    try policy.beginCalibration(epoch: 1)
    try policy.beginInstall(map, at: base)
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .relocalizing, time: 0.1)
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 0.2)
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .relocalizing, time: 0.3)
    ingest(&policy, map: map, phase: .bodyRelocalization, tracking: .normal, time: 0.4)
    return (policy, map)
  }

  @discardableResult
  private func ingest(_ policy: inout DuelFramePolicy, map: DuelFrameMap? = nil,
    phase: DuelFrameSessionPhase, tracking: DuelFrameTracking, time: Double, mapped: Bool = false) -> Bool {
    let date = base.addingTimeInterval(time)
    return policy.ingest(DuelFrameObservation(epoch: map?.epoch ?? 1, frameID: map?.frameID,
      phase: phase, tracking: tracking, isMapped: mapped,
      pose: tracking == .normal ? DuelFramePose(columnMajor: matrix, capturedAt: date, frameTimestamp: time) : nil,
      observedAt: date, failure: nil), at: date)
  }

  private func residual(_ policy: inout DuelFramePolicy, map: DuelFrameMap, time: Double, translation: Double = 0.04) throws {
    let date = base.addingTimeInterval(time)
    try policy.recordResidual(frameID: map.frameID, epoch: map.epoch, translationMeters: translation,
      yawDegrees: 0.2, observedAt: date, now: date)
  }
}

@MainActor
final class DuelFrameProviderTests: XCTestCase {
  func testLateCaptureCannotInstallIntoANewMatchWithTheSameEpoch() async throws {
    let driver = DelayedDuelFrameDriver()
    let provider = DuelFrameProvider(targeting: driver)
    try await provider.beginCalibration(epoch: 1)
    driver.emitMapped(epoch: 1)
    for _ in 0..<100 where provider.snapshot.stage != .mapReady {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(provider.snapshot.stage, .mapReady)
    try await provider.captureReference()
    let capture = Task { try await provider.captureMap() }
    await driver.waitForCapture()
    await provider.stop()
    try await provider.beginCalibration(epoch: 1)
    await driver.completeCapture()
    do {
      _ = try await capture.value
      XCTFail("A late old-match map must not be returned as the new match's map")
    } catch {
      XCTAssertEqual(error as? DuelFrameFailure, .operationSuperseded)
    }
    XCTAssertEqual(provider.snapshot.stage, .mapping)
    XCTAssertNil(provider.snapshot.frameID)
    await provider.stop()
  }
}

private actor DelayedDuelFrameDriver: DuelFrameSessionDriving {
  nonisolated let hub = DuelFrameObservationHub()
  private var capture: CheckedContinuation<Data, any Error>?
  private var captureWaiters: [CheckedContinuation<Void, Never>] = []

  nonisolated func duelFrameObservations() -> AsyncStream<DuelFrameObservation> { hub.stream() }
  func beginFrameMapping(epoch: UInt16) async throws {}
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws {}
  func endFrameMapping() async {}
  func captureFrameReference(epoch: UInt16) async throws -> DuelFrameReference {
    try DuelFrameReference(imageData: Data([1, 2, 3]), widthMeters: 1, heightMeters: 0.6,
      mapFromImage: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      sampleCount: 3, maximumCornerDeviationMeters: 0)
  }

  func captureFrameMap(epoch: UInt16) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      capture = continuation
      captureWaiters.forEach { $0.resume() }
      captureWaiters.removeAll()
    }
  }

  func waitForCapture() async {
    if capture != nil { return }
    await withCheckedContinuation { captureWaiters.append($0) }
  }

  func completeCapture() {
    capture?.resume(returning: Data([1, 2, 3]))
    capture = nil
  }

  nonisolated func emitMapped(epoch: UInt16) {
    hub.yield(DuelFrameObservation(epoch: epoch, frameID: nil, phase: .mapping,
      tracking: .normal, isMapped: true, pose: nil, observedAt: Date(), failure: nil))
  }
}
