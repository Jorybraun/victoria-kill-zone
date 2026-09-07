import Foundation
import XCTest
@testable import VictoriaKillZone

final class SharedOriginExperimentTests: XCTestCase {
  private let run = UUID(), origin = UUID()

  func testDifferentTranslatedRotatedLocalOriginsProduceSameArenaCoordinates() throws {
    let localAFromArena = try transform(yaw: 35, x: 5, y: 1, z: -3)
    let localBFromArena = try transform(yaw: -110, x: -7, y: 0.4, z: 11)
    let arenaFromA = try transform(yaw: 12, x: 1, y: 1.3, z: 2)
    let arenaFromB = try transform(yaw: 175, x: 4, y: 1.5, z: -2)
    var a = try started(), b = try started()
    XCTAssertTrue(observe(&a, localFromArena: localAFromArena, localFromPhone: try localAFromArena.composed(with: arenaFromA)))
    XCTAssertTrue(observe(&b, localFromArena: localBFromArena, localFromPhone: try localBFromArena.composed(with: arenaFromB)))
    assertTransform(try XCTUnwrap(a.localMeasurement(at: 1_000)).arenaFromPhone, arenaFromA)
    assertTransform(try XCTUnwrap(b.localMeasurement(at: 1_000)).arenaFromPhone, arenaFromB)
    XCTAssertTrue(a.receivePose(pose(transform: arenaFromB), at: 1_000))
    XCTAssertTrue(b.receivePose(pose(transform: arenaFromA), at: 1_000))
    assertTransform(try XCTUnwrap(a.localFromPeer(at: 1_000)), try localAFromArena.composed(with: arenaFromB))
    assertTransform(try XCTUnwrap(b.localFromPeer(at: 1_000)), try localBFromArena.composed(with: arenaFromA))
    XCTAssertGreaterThan((localAFromArena.translation - localBFromArena.translation).length, 10,
      "The fixture must not accidentally use the same local origin on both phones")
  }

  func testMissingOriginNeverFallsBackToIdentityAndLosingAnchorClearsMeasurement() throws {
    var policy = SharedOriginPolicy(runID: run)
    try policy.begin(epoch: 1, nowMs: 0)
    XCTAssertFalse(observe(&policy))
    XCTAssertNil(policy.localMeasurement(at: 1_000))
    XCTAssertTrue(policy.adoptOrigin(runID: run, epoch: 1, originID: origin))
    XCTAssertTrue(observe(&policy))
    XCTAssertTrue(policy.receivePose(pose(), at: 1_000))
    XCTAssertNotNil(policy.localFromPeer(at: 1_000))
    XCTAssertFalse(observe(&policy, time: 1_010, localFromArena: nil))
    XCTAssertNil(policy.localFromPeer(at: 1_010))
    XCTAssertNil(policy.localMeasurement(at: 1_010))
  }

  func testFreshnessIsCheckedAtReadWithoutWaitingForTimerAndNoRawPeerPoseIsRendered() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    XCTAssertTrue(policy.receivePose(pose(), at: 1_000))
    XCTAssertNotNil(policy.localFromPeer(at: 1_100))
    XCTAssertNil(policy.localFromPeer(at: 1_100.01))
    XCTAssertTrue(observe(&policy, time: 1_110))
    XCTAssertNil(policy.localFromPeer(at: 1_110), "A new local frame does not make the old peer receipt fresh")
    XCTAssertTrue(policy.receivePose(pose(sequence: 2, captured: 9_020), at: 1_110))
    XCTAssertNotNil(policy.localFromPeer(at: 1_110))
  }

  func testWrongRunEpochOriginAndRepeatedCameraFramesCannotReplaceMeasurement() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    let original = policy.measurement
    for (wrongRun, wrongEpoch, wrongOrigin) in [(UUID(), UInt64(1), origin), (run, UInt64(2), origin), (run, UInt64(1), UUID())] {
      XCTAssertFalse(policy.observeLocal(runID: wrongRun, epoch: wrongEpoch, originID: wrongOrigin,
        localFromArena: .identity, localFromPhone: try .translation(x: 50, y: 0, z: 0), trackingNormal: true,
        frameTimestamp: 2, capturedUptimeMs: 1_020, nowMs: 1_020))
      XCTAssertEqual(policy.measurement, original)
    }
    XCTAssertFalse(observe(&policy, localFromPhone: try .translation(x: 50, y: 0, z: 0)))
    XCTAssertEqual(policy.measurement, original)
  }

  func testPeerReplayOldEpochAndWrongOriginCannotReplaceAcceptedCoordinates() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    XCTAssertTrue(policy.receivePose(pose(), at: 1_000))
    let accepted = policy.peerArenaFromPhone
    let rejected = [pose(), pose(sequence: 2, captured: 8_999), pose(sequence: 2, runID: UUID()),
      pose(sequence: 2, epoch: 2), pose(sequence: 2, originID: UUID())]
    for message in rejected {
      XCTAssertFalse(policy.receivePose(message, at: 1_010))
      XCTAssertEqual(policy.peerSequence, 1)
      XCTAssertEqual(policy.peerArenaFromPhone, accepted)
    }
  }

  func testStopInterruptionAndNewEpochRejectLateCameraAndPeerCallbacks() throws {
    for phase in [SharedOriginPhase.stopped, .interrupted] {
      var policy = try started()
      XCTAssertTrue(observe(&policy))
      XCTAssertTrue(policy.receivePose(pose(), at: 1_000))
      policy.invalidate(phase)
      XCTAssertNil(policy.localFromPeer(at: 1_010))
      XCTAssertNil(policy.originID)
      XCTAssertFalse(observe(&policy, time: 1_010))
      XCTAssertFalse(policy.receivePose(pose(sequence: 2), at: 1_010))
      XCTAssertThrowsError(try policy.begin(epoch: 1, nowMs: 1_020))
      try policy.begin(epoch: 2, nowMs: 1_020)
      XCTAssertTrue(policy.adoptOrigin(runID: run, epoch: 2, originID: origin))
      XCTAssertFalse(observe(&policy, time: 1_030))
      XCTAssertFalse(policy.receivePose(pose(sequence: 3), at: 1_030))
      XCTAssertNil(policy.localFromPeer(at: 1_030))
    }
  }

  func testReceiptAgeDoesNotPretendToMeasureCrossPhoneCaptureLatency() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    // Uptime clocks differ. This field is ordering evidence, not a local-age clock.
    XCTAssertTrue(policy.receivePose(pose(captured: 5_000_000, age: 12), at: 1_000))
    XCTAssertEqual(policy.peerReceiptAge(at: 1_020), 20)
    XCTAssertEqual(policy.peerSourceAgeMs, 12)
    XCTAssertEqual(policy.peerCapturedUptimeMs, 5_000_000)
    XCTAssertFalse(policy.receivePose(pose(sequence: 2, captured: 5_000_020, age: 100.01), at: 1_020))
    XCTAssertEqual(policy.peerSequence, 1)
  }

  func testSearchTimesOutWithoutFramesAndDelayedPeerCannotBypassDeadline() throws {
    var policy = try started()
    policy.tick(nowMs: 30_000)
    XCTAssertEqual(policy.phase, .timedOut)
    XCTAssertFalse(observe(&policy, time: 30_001))
    XCTAssertFalse(policy.receivePose(pose(), at: 30_001))
    var late = try started()
    XCTAssertTrue(observe(&late, time: 29_999))
    XCTAssertFalse(late.receivePose(pose(), at: 30_000))
    XCTAssertEqual(late.phase, .timedOut)
    var queued = try started()
    XCTAssertTrue(observe(&queued, time: 29_999))
    XCTAssertFalse(queued.receivePose(pose(), at: 29_999, evaluatedAt: 30_001))
    XCTAssertEqual(queued.phase, .timedOut, "A queued receipt cannot move evaluation back before the deadline")
  }

  func testLocalTrackingLossAndStaleFramesDoNotProducePoseMessages() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    XCTAssertFalse(policy.observeLocal(runID: run, epoch: 1, originID: origin,
      localFromArena: .identity, localFromPhone: .identity, trackingNormal: false,
      frameTimestamp: 2, capturedUptimeMs: 1_020, nowMs: 1_020))
    XCTAssertNil(policy.localMeasurement(at: 1_020))
    XCTAssertFalse(policy.observeLocal(runID: run, epoch: 1, originID: origin,
      localFromArena: .identity, localFromPhone: .identity, trackingNormal: true,
      frameTimestamp: 3, capturedUptimeMs: 1_000, nowMs: 1_101))
    XCTAssertNil(policy.localMeasurement(at: 1_101))
  }

  func testStalledFinalCameraCallbackKeepsItsCaptureTimeEvenOnFirstDelivery() {
    // A stopped camera leaves currentFrame equal to the delayed callback frame.
    // Relative currentFrame subtraction would incorrectly report zero age here.
    XCTAssertNil(SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: 10, nowMs: 10_500))
    XCTAssertEqual(SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: 10, nowMs: 10_020), 10_000)
    XCTAssertNil(SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: 10, nowMs: 9_999))
    XCTAssertNil(SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: .nan, nowMs: 10_020))
    XCTAssertNil(SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: .infinity, nowMs: 10_020))
  }

  func testLocalRevocationHidesPeerImmediatelyWithoutTimerOrNewFrame() throws {
    var policy = try started()
    XCTAssertTrue(observe(&policy))
    XCTAssertTrue(policy.receivePose(pose(), at: 1_000))
    XCTAssertNotNil(policy.localFromPeer(at: 1_000))
    policy.revokeLocalMeasurement()
    XCTAssertNil(policy.localFromPeer(at: 1_000))
    XCTAssertNil(policy.localMeasurement(at: 1_000))
  }

  func testWireRoundTripAndMalformedPoseBoundaries() throws {
    let messages: [SharedOriginWireMessage] = [
      .init(runID: run, epoch: 1, body: .hello(sessionID: UUID(), role: .host)),
      .init(runID: run, epoch: 1, body: .origin(originID: origin)), pose(),
    ]
    for message in messages {XCTAssertEqual(try SharedOriginWireMessage.decode(message.encoded()), message)}
    for message in [pose(sequence: 0), pose(captured: -.infinity), pose(age: -.leastNonzeroMagnitude), pose(age: 101), pose(epoch: 0)] {
      XCTAssertThrowsError(try message.encoded())
    }
    var scaled = ArenaRigidTransform.identityStorage; scaled[0] = 2
    XCTAssertThrowsError(try SharedOriginWireMessage(runID: run, epoch: 1, body: .pose(originID: origin,
      sequence: 1, capturedUptimeMs: 1, sourceAgeMs: 0, trackingNormal: true, arenaFromPhone: scaled)).encoded())
    XCTAssertThrowsError(try SharedOriginWireMessage.decode(Data()))
    XCTAssertThrowsError(try SharedOriginWireMessage.decode(Data(repeating: 0, count: 4_097)))
    let malformed = Data("{\"version\":2}".utf8)
    XCTAssertThrowsError(try SharedOriginWireMessage.decode(malformed))
  }

  func testExperimentCredentialsArePerRunAndCodeParsingReproducesOnlySameScope() throws {
    let first = SharedOriginCredentials.create(), second = SharedOriginCredentials.create()
    XCTAssertNotEqual(first.runID, second.runID)
    XCTAssertFalse(first.joinSecret == second.joinSecret)
    XCTAssertFalse(first.runID.uuidString.lowercased() == first.joinSecret)
    let parsed = try SharedOriginCredentials(code: " \n" + first.joinSecret.uppercased() + " ")
    XCTAssertTrue(parsed == first, "The code should reproduce the same run without logging credential values")
    XCTAssertThrowsError(try SharedOriginCredentials(code: ""))
    XCTAssertThrowsError(try SharedOriginCredentials(code: "invalid-code"))
  }

  #if DEBUG
  func testMeasurementLogContainsNoCredentialsIdentifiersOrFalseLockLabels() {
    var log = SharedOriginMeasurementLog()
    var snapshot = SharedArenaSnapshot(role: .host)
    snapshot.phase = .observing; snapshot.elapsedMs = 1_000
    snapshot.originObserved = true; snapshot.localArenaPosition = .init(x: 1, y: 2, z: 3)
    snapshot.peerReceiptAgeMs = 15; snapshot.peerSourceAgeMs = 5
    snapshot.errorMessage = "This field must never be exported"
    log.append(snapshot)
    let exported = log.lines.joined(separator: "\n")
    XCTAssertTrue(exported.contains("peer_receipt_age_ms"))
    XCTAssertFalse(exported.contains("lockReady"))
    XCTAssertFalse(exported.contains("This field must never be exported"))
    XCTAssertFalse(exported.contains(run.uuidString))
    XCTAssertFalse(exported.contains(origin.uuidString))
  }
  #endif

  private func started() throws -> SharedOriginPolicy {
    var policy = SharedOriginPolicy(runID: run)
    try policy.begin(epoch: 1, nowMs: 0)
    XCTAssertTrue(policy.adoptOrigin(runID: run, epoch: 1, originID: origin))
    return policy
  }
  @discardableResult
  private func observe(_ policy: inout SharedOriginPolicy, time: Double = 1_000,
    localFromArena: ArenaRigidTransform? = .identity, localFromPhone: ArenaRigidTransform = .identity) -> Bool {
    policy.observeLocal(runID: run, epoch: 1, originID: origin, localFromArena: localFromArena,
      localFromPhone: localFromPhone, trackingNormal: true, frameTimestamp: time / 1_000,
      capturedUptimeMs: time, nowMs: time)
  }
  private func pose(sequence: UInt64 = 1, captured: Double = 9_000, age: Double = 0,
    runID: UUID? = nil, epoch: UInt64 = 1, originID: UUID? = nil,
    transform: ArenaRigidTransform = .identity) -> SharedOriginWireMessage {
    .init(runID: runID ?? run, epoch: epoch, body: .pose(originID: originID ?? origin,
      sequence: sequence, capturedUptimeMs: captured, sourceAgeMs: age, trackingNormal: true,
      arenaFromPhone: transform.columnMajor))
  }
  private func transform(yaw: Double, x: Double, y: Double, z: Double) throws -> ArenaRigidTransform {
    let radians = yaw * .pi / 180
    var matrix = ArenaRigidTransform.identityStorage
    matrix[0] = cos(radians); matrix[2] = -sin(radians); matrix[8] = sin(radians); matrix[10] = cos(radians)
    matrix[12] = x; matrix[13] = y; matrix[14] = z
    return try ArenaRigidTransform(columnMajor: matrix)
  }
  private func assertTransform(_ actual: ArenaRigidTransform, _ expected: ArenaRigidTransform,
    file: StaticString = #filePath, line: UInt = #line) {
    for (left, right) in zip(actual.columnMajor, expected.columnMajor) {
      XCTAssertEqual(left, right, accuracy: 1e-9, file: file, line: line)
    }
  }
}
