import Foundation
import XCTest
#if os(iOS) && canImport(ARKit)
import ARKit
#endif

@testable import VictoriaKillZone

final class DuelFramePolicyTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)
  private let matrix: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

  func testScanFeedbackShowsFreshReasonsAndResetsOnBeginAndStop() throws {
    var policy = DuelFramePolicy()
    XCTAssertEqual(policy.snapshot.scanFeedback, .waitingForCamera)
    try policy.beginCalibration(epoch: 1, at: base)
    policy.ingest(scanObservation(time: 0.1, feedback: .movingTooFast), at: base.addingTimeInterval(0.1))
    XCTAssertEqual(policy.snapshot.scanFeedback, .movingTooFast)
    policy.ingest(scanObservation(time: 0.2, feedback: .insufficientDetail), at: base.addingTimeInterval(0.2))
    XCTAssertEqual(policy.snapshot.scanFeedback, .insufficientDetail)
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.2)))
    try policy.beginCalibration(epoch: 2, at: base.addingTimeInterval(1))
    XCTAssertEqual(policy.snapshot.scanFeedback, .waitingForCamera)
    policy.ingest(scanObservation(time: 1.1, epoch: 2, feedback: .initializing), at: base.addingTimeInterval(1.1))
    XCTAssertEqual(policy.snapshot.scanFeedback, .initializing)
    policy.stop()
    XCTAssertEqual(policy.snapshot.scanFeedback, .waitingForCamera)
  }

  func testRejectedScanObservationsCannotReplaceCurrentGuidance() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    policy.ingest(scanObservation(time: 1, feedback: .insufficientDetail), at: base.addingTimeInterval(1))
    let before = policy.snapshot
    let rejected = [
      scanObservation(time: 0.8, feedback: .ready), // Too old.
      scanObservation(time: 1, feedback: .ready), // Already consumed.
      scanObservation(time: 1.2, feedback: .ready), // From the future.
      scanObservation(time: 1.01, epoch: 2, feedback: .ready),
      scanObservation(time: 1.02, phase: .worldRelocalization, feedback: .ready),
      scanObservation(time: 1.03, phase: .bodyRelocalization, feedback: .ready),
    ]
    for observation in rejected {
      policy.ingest(observation, at: base.addingTimeInterval(1.04))
      XCTAssertEqual(policy.snapshot, before)
    }
  }

  func testScanFeedbackFallsBackWithoutChangingReadinessOrTimeout() throws {
    let cases: [(DuelFrameTracking, Bool, DuelFrameScanFeedback)] = [
      (.unavailable, false, .trackingUnavailable), (.limited, true, .trackingLimited),
      (.relocalizing, false, .relocalizing), (.normal, false, .mapping), (.normal, true, .ready),
    ]
    for (tracking, mapped, expected) in cases {
      var policy = DuelFramePolicy()
      try policy.beginCalibration(epoch: 1, at: base)
      policy.ingest(scanObservation(time: 1, tracking: tracking, mapped: mapped), at: base.addingTimeInterval(1))
      XCTAssertEqual(policy.snapshot.scanFeedback, expected)
      XCTAssertEqual(policy.snapshot.stage, expected == .ready ? .mapReady : .mapping)
      XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(1)))
    }
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    for second in 1..<30 {
      // Even an inconsistent diagnostic cannot claim a usable map or extend its deadline.
      policy.ingest(scanObservation(time: Double(second), feedback: .ready), at: base.addingTimeInterval(Double(second)))
      XCTAssertEqual(policy.snapshot.scanFeedback, .trackingLimited)
      XCTAssertEqual(policy.snapshot.stage, .mapping)
    }
    policy.tick(at: base.addingTimeInterval(30))
    XCTAssertEqual(policy.snapshot.failure, .mappingTimedOut)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(30)))
  }

  func testScanFeedbackDoesNotFollowFramesAfterMapInstallationOrFailure() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    policy.ingest(scanObservation(time: 0.1, tracking: .normal, mapped: true), at: base.addingTimeInterval(0.1))
    XCTAssertEqual(policy.snapshot.scanFeedback, .ready)
    let map = try DuelFrameMap(epoch: 1, bytes: Data([1]))
    try policy.beginInstall(map, at: base.addingTimeInterval(0.2))
    let before = policy.snapshot.scanFeedback
    let observation = scanObservation(time: 0.3, frameID: map.frameID, phase: .worldRelocalization,
      tracking: .relocalizing, feedback: .movingTooFast)
    policy.ingest(observation, at: base.addingTimeInterval(0.3))
    XCTAssertEqual(policy.snapshot.scanFeedback, before)
    policy.invalidate(reason: .sessionInterrupted)
    policy.ingest(scanObservation(time: 0.4, feedback: .ready), at: base.addingTimeInterval(0.4))
    XCTAssertEqual(policy.snapshot.scanFeedback, before)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.4)))
  }

  func testMappingWithoutAnyCameraObservationsTimesOutAndStopAllowsRetry() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    let token = try XCTUnwrap(policy.operationToken)
    policy.tick(at: base.addingTimeInterval(29.999))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    policy.tick(at: base.addingTimeInterval(30))
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .mappingTimedOut)
    XCTAssertFalse(policy.accepts(token))
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(30)))
    policy.stop()
    try policy.beginCalibration(epoch: 1, at: base.addingTimeInterval(40))
    policy.tick(at: base.addingTimeInterval(69.999))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 69.999, mapped: true)
    XCTAssertEqual(policy.snapshot.stage, .mapReady)
    XCTAssertNil(policy.snapshot.failure)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(69.999)))
  }

  func testUnusableFramesCannotPostponeDeadlineOrUnlockAfterDelayedWatchdog() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    for second in 0..<30 {
      ingest(&policy, phase: .mapping, tracking: .normal, time: Double(second), mapped: false)
    }
    ingest(&policy, phase: .mapping, tracking: .normal, time: 30, mapped: true)
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .mappingTimedOut)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(30)))
  }

  func testMapReadyClearsDeadlineButLosingMapStartsANewBoundedScan() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 10, mapped: true)
    policy.tick(at: base.addingTimeInterval(120))
    XCTAssertEqual(policy.snapshot.stage, .mapReady, "Choosing a scene reference must not consume the initial scan timeout")
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(120)))
    ingest(&policy, phase: .mapping, tracking: .limited, time: 130, mapped: true)
    policy.tick(at: base.addingTimeInterval(159.999))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 159.999, mapped: false)
    policy.tick(at: base.addingTimeInterval(160))
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .mappingTimedOut)
  }

  func testNewCalibrationEpochReplacesPreviousMappingDeadline() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: base)
    try policy.beginCalibration(epoch: 2, at: base.addingTimeInterval(20))
    policy.tick(at: base.addingTimeInterval(30))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    policy.tick(at: base.addingTimeInterval(50))
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .mappingTimedOut)
  }

  func testGuestCanWaitForHostAcrossMappingChangesButInstallationStillTimesOut() throws {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, captureRequired: false, at: base)
    policy.tick(at: base.addingTimeInterval(40))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 45, mapped: true)
    XCTAssertEqual(policy.snapshot.stage, .mapReady)
    ingest(&policy, phase: .mapping, tracking: .normal, time: 60, mapped: false)
    policy.tick(at: base.addingTimeInterval(90))
    XCTAssertEqual(policy.snapshot.stage, .mapping)
    XCTAssertNil(policy.snapshot.failure)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(90)))
    let map = try DuelFrameMap(epoch: 1, bytes: Data([1]))
    try policy.beginInstall(map, at: base.addingTimeInterval(90))
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .relocalizing, time: 92)
    ingest(&policy, map: map, phase: .worldRelocalization, tracking: .normal, time: 105)
    XCTAssertEqual(policy.snapshot.stage, .lost)
    XCTAssertEqual(policy.snapshot.failure, .relocalizationTimedOut)
  }

  #if os(iOS) && canImport(ARKit)
  func testARScanFeedbackDistinguishesMotionDetailAndCameraStartup() {
    let reasons: [(ARCamera.TrackingState, DuelFrameScanFeedback)] = [
      (.notAvailable, .trackingUnavailable), (.limited(.initializing), .initializing),
      (.limited(.excessiveMotion), .movingTooFast), (.limited(.insufficientFeatures), .insufficientDetail),
      (.limited(.relocalizing), .relocalizing),
    ]
    for (tracking, expected) in reasons {
      // A nominal mapped status cannot override a limited or unavailable camera.
      XCTAssertEqual(DuelFrameMapCaptureEligibility.feedback(mapping: .mapped, tracking: tracking), expected)
      XCTAssertFalse(DuelFrameMapCaptureEligibility.permits(mapping: .mapped, tracking: tracking))
    }
    for status in [ARFrame.WorldMappingStatus.extending, .mapped] {
      XCTAssertEqual(DuelFrameMapCaptureEligibility.feedback(mapping: status, tracking: .normal), .ready)
    }
    for status in [ARFrame.WorldMappingStatus.notAvailable, .limited] {
      XCTAssertEqual(DuelFrameMapCaptureEligibility.feedback(mapping: status, tracking: .normal), .mapping)
    }
  }

  func testARMapCaptureAcceptsExtendingAndMappedOnlyWithNormalTracking() throws {
    for status in [ARFrame.WorldMappingStatus.extending, .mapped] {
      XCTAssertTrue(DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .normal))
      var policy = DuelFramePolicy()
      try policy.beginCalibration(epoch: 1, at: base)
      ingest(&policy, phase: .mapping, tracking: .normal, time: 1,
        mapped: DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .normal))
      XCTAssertEqual(policy.snapshot.stage, .mapReady)
      XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(1)))
      XCTAssertFalse(DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .notAvailable))
      XCTAssertFalse(DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .limited(.initializing)))
      XCTAssertFalse(DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .limited(.relocalizing)))
    }
    for status in [ARFrame.WorldMappingStatus.notAvailable, .limited] {
      XCTAssertFalse(DuelFrameMapCaptureEligibility.permits(mapping: status, tracking: .normal))
    }
  }
  #endif

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

  private func scanObservation(time: Double, epoch: UInt16 = 1, frameID: String? = nil, phase: DuelFrameSessionPhase = .mapping,
    tracking: DuelFrameTracking = .limited, mapped: Bool = false, feedback: DuelFrameScanFeedback? = nil) -> DuelFrameObservation {
    .init(epoch: epoch, frameID: frameID, phase: phase, tracking: tracking, isMapped: mapped,
      pose: nil, observedAt: base.addingTimeInterval(time), failure: nil, scanFeedback: feedback)
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
  func testGuestProviderDoesNotExpireWhileWaitingForHostMap() async throws {
    let driver = DelayedDuelFrameDriver(), clock = MappingTestClock()
    let provider = DuelFrameProvider(targeting: driver, now: {clock.date})
    try await provider.beginCalibration(epoch: 1, captureRequired: false)
    clock.date = clock.date.addingTimeInterval(90)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(provider.snapshot.stage, .mapping)
    XCTAssertNil(provider.snapshot.failure)
    await provider.stop()
  }

  func testWatchdogUsesInjectedTimeAndTimesOutWithoutAnyDriverFrames() async throws {
    let driver = DelayedDuelFrameDriver(), clock = MappingTestClock()
    let provider = DuelFrameProvider(targeting: driver, now: {clock.date})
    try await provider.beginCalibration(epoch: 1)
    clock.date = clock.date.addingTimeInterval(30)
    for _ in 0..<50 where provider.snapshot.stage != .lost {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(provider.snapshot.stage, .lost)
    XCTAssertEqual(provider.snapshot.failure, .mappingTimedOut)
    await provider.stop()
  }

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

@MainActor
private final class MappingTestClock {
  var date = Date(timeIntervalSince1970: 1_000)
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
