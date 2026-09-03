import Foundation
import XCTest

@testable import VictoriaKillZone

final class SharedArenaFrameTests: XCTestCase {
  // MARK: - Rigid approximation of sensor matrices

  func testRigidApproximationAcceptsFloatPrecisionNoise() throws {
    let yaw = 0.7
    var storage = ArenaRigidTransform.identityStorage
    storage[0] = cos(yaw)
    storage[2] = -sin(yaw)
    storage[8] = sin(yaw)
    storage[10] = cos(yaw)
    storage[12] = 1.5
    storage[13] = -0.2
    storage[14] = 4
    // Single-precision rotation blocks from ARKit carry ~1e-7..1e-5 errors;
    // perturb well past the strict 1e-6 tolerance but inside sensor noise.
    var noisy = storage.map { Double(Float($0)) }
    noisy[0] += 2e-5
    noisy[5] -= 3e-5
    noisy[9] += 1e-5

    XCTAssertThrowsError(try ArenaRigidTransform(columnMajor: noisy))
    let repaired = try ArenaRigidTransform.rigidApproximation(columnMajor: noisy)
    let exact = try ArenaRigidTransform(columnMajor: storage)
    for index in 0..<16 {
      XCTAssertEqual(repaired.columnMajor[index], exact.columnMajor[index], accuracy: 1e-4)
    }
    XCTAssertEqual(repaired.translation.x, 1.5, accuracy: 1e-6)
    XCTAssertEqual(repaired.translation.y, -0.2, accuracy: 1e-6)
    XCTAssertEqual(repaired.translation.z, 4, accuracy: 1e-6)
  }

  func testRigidApproximationRejectsScaleShearAndReflection() {
    var scaled = ArenaRigidTransform.identityStorage
    scaled[0] = 1.1
    XCTAssertThrowsError(try ArenaRigidTransform.rigidApproximation(columnMajor: scaled))

    var sheared = ArenaRigidTransform.identityStorage
    sheared[4] = 0.05
    XCTAssertThrowsError(try ArenaRigidTransform.rigidApproximation(columnMajor: sheared))

    var reflected = ArenaRigidTransform.identityStorage
    reflected[10] = -1
    XCTAssertThrowsError(try ArenaRigidTransform.rigidApproximation(columnMajor: reflected))

    var nonFinite = ArenaRigidTransform.identityStorage
    nonFinite[12] = .nan
    XCTAssertThrowsError(try ArenaRigidTransform.rigidApproximation(columnMajor: nonFinite))
  }

  func testYawAndResidualAreGravityAxisOnly() throws {
    let identity = ArenaRigidTransform.identity
    XCTAssertEqual(identity.yawDegrees, 0, accuracy: 1e-9)

    let rotated = try yawTransform(degrees: 30, translation: ArenaVector3(x: 0.05, y: 0, z: 0))
    XCTAssertEqual(rotated.yawDegrees, 30, accuracy: 1e-9)

    let residual = ArenaRigidTransform.residual(reported: rotated, observed: identity)
    XCTAssertEqual(residual.translationMeters, 0.05, accuracy: 1e-9)
    XCTAssertEqual(residual.yawDegrees, 30, accuracy: 1e-9)

    let wrapped = ArenaRigidTransform.residual(
      reported: try yawTransform(degrees: 179, translation: .zero),
      observed: try yawTransform(degrees: -179, translation: .zero)
    )
    XCTAssertEqual(wrapped.yawDegrees, 2, accuracy: 1e-6, "Yaw residual must wrap across ±180°")
  }

  // MARK: - Peer sample codec

  func testPeerSampleCodecRoundTripsExactly() throws {
    let sample = ArenaPeerSample(
      playerId: "player-b",
      sequence: 42,
      timestampMs: 1_700_000_000_123,
      tracking: .normal,
      arenaFromPhone: try yawTransform(degrees: -12.5, translation: ArenaVector3(x: 3, y: 1.4, z: -8.25))
    )
    let encoded = try ArenaPeerSampleCodec.encode(sample)
    XCTAssertEqual(encoded.count, 1 + 8 + 8 + 8 + 1 + 12 * 8)
    XCTAssertEqual(try ArenaPeerSampleCodec.decode(encoded), sample)
  }

  func testPeerSampleCodecRejectsMalformedInput() throws {
    let sample = ArenaPeerSample(
      playerId: "a",
      sequence: 1,
      timestampMs: 1,
      tracking: .lost,
      arenaFromPhone: .identity
    )
    let encoded = try ArenaPeerSampleCodec.encode(sample)

    XCTAssertThrowsError(try ArenaPeerSampleCodec.decode(encoded.dropLast())) { error in
      XCTAssertEqual(error as? ArenaPeerSampleCodecError, .truncated)
    }
    XCTAssertThrowsError(try ArenaPeerSampleCodec.decode(encoded + Data([0]))) { error in
      XCTAssertEqual(error as? ArenaPeerSampleCodecError, .trailingBytes)
    }

    var badTracking = encoded
    badTracking[1 + 1 + 16] = 7
    XCTAssertThrowsError(try ArenaPeerSampleCodec.decode(badTracking)) { error in
      XCTAssertEqual(error as? ArenaPeerSampleCodecError, .invalidTracking)
    }

    var scaledRotation = encoded
    let firstRotationOffset = 1 + 1 + 16 + 1
    withUnsafeBytes(of: (2.0).bitPattern.littleEndian) {
      scaledRotation.replaceSubrange(firstRotationOffset..<firstRotationOffset + 8, with: $0)
    }
    XCTAssertThrowsError(try ArenaPeerSampleCodec.decode(scaledRotation)) { error in
      XCTAssertEqual(error as? ArenaPeerSampleCodecError, .invalidTransform(.nonUnitScale))
    }

    XCTAssertThrowsError(
      try ArenaPeerSampleCodec.encode(
        ArenaPeerSample(playerId: "", sequence: 1, timestampMs: 1, tracking: .normal, arenaFromPhone: .identity)
      )
    )
    XCTAssertThrowsError(
      try ArenaPeerSampleCodec.encode(
        ArenaPeerSample(playerId: "a", sequence: 0, timestampMs: 1, tracking: .normal, arenaFromPhone: .identity)
      )
    )
  }

  // MARK: - Lock policy

  func testLockRequiresEveryGateAndAConsecutiveStreak() {
    var policy = SharedArenaLockPolicy(thresholds: thresholds(streak: 3))

    XCTAssertEqual(
      policy.evaluate(observation(localTracking: .limited(.initializing)), nowMs: 0).state,
      .aligning(.localTracking)
    )
    XCTAssertEqual(
      policy.evaluate(observation(mapping: .extending), nowMs: 10).state,
      .aligning(.mapping),
      "Initial lock demands a fully mapped scene"
    )
    XCTAssertEqual(policy.evaluate(observation(merge: false), nowMs: 20).state, .aligning(.awaitingMerge))
    XCTAssertEqual(policy.evaluate(observation(peer: nil), nowMs: 30).state, .aligning(.awaitingPeer))
    XCTAssertEqual(
      policy.evaluate(observation(peer: peer(tracking: .lost)), nowMs: 40).state,
      .aligning(.peerTracking)
    )
    XCTAssertEqual(policy.evaluate(observation(peer: peer(ageMs: 101)), nowMs: 50).state, .aligning(.peerStale))
    XCTAssertEqual(
      policy.evaluate(observation(peer: peer(residual: residual(0.11, 0.1))), nowMs: 60).state,
      .aligning(.residualTranslation)
    )
    XCTAssertEqual(
      policy.evaluate(observation(peer: peer(residual: residual(0.05, 0.6))), nowMs: 70).state,
      .aligning(.residualYaw)
    )

    XCTAssertEqual(policy.evaluate(observation(), nowMs: 80).state, .aligning(.stabilizing))
    XCTAssertEqual(policy.evaluate(observation(), nowMs: 90).state, .aligning(.stabilizing))
    let locked = policy.evaluate(observation(), nowMs: 100)
    XCTAssertEqual(locked.state, .lockReady)
    XCTAssertNil(locked.recoveryMs, "First lock is not a recovery")
    XCTAssertFalse(locked.clearsHistory)
  }

  func testLossClearsHistoryOnceAndRecoveryIsMeasuredAndStreakGated() {
    var policy = SharedArenaLockPolicy(thresholds: thresholds(streak: 2))
    _ = policy.evaluate(observation(), nowMs: 0)
    XCTAssertEqual(policy.evaluate(observation(), nowMs: 50).state, .lockReady)

    // Once locked, `extending` is acceptable — the map legitimately toggles.
    XCTAssertEqual(policy.evaluate(observation(mapping: .extending), nowMs: 100).state, .lockReady)

    let lost = policy.evaluate(observation(localTracking: .limited(.relocalizing)), nowMs: 150)
    XCTAssertEqual(lost.state, .trackingLost(.localTracking))
    XCTAssertTrue(lost.clearsHistory, "Leaving lockReady must drop buffered transforms")

    let stillLost = policy.evaluate(observation(peer: peer(ageMs: 500)), nowMs: 200)
    XCTAssertEqual(stillLost.state, .trackingLost(.peerStale))
    XCTAssertFalse(stillLost.clearsHistory, "History is cleared exactly once per loss")

    // A single good evaluation after a loss must not re-open the gate.
    XCTAssertEqual(policy.evaluate(observation(), nowMs: 250).state, .trackingLost(.stabilizing))
    let recovered = policy.evaluate(observation(), nowMs: 300)
    XCTAssertEqual(recovered.state, .lockReady)
    XCTAssertEqual(recovered.recoveryMs, 150)

    // A flap in the middle of the streak restarts it.
    _ = policy.evaluate(observation(merge: false), nowMs: 350)
    _ = policy.evaluate(observation(), nowMs: 400)
    _ = policy.evaluate(observation(peer: peer(tracking: .lost)), nowMs: 450)
    XCTAssertEqual(policy.evaluate(observation(), nowMs: 500).state, .trackingLost(.stabilizing))
  }

  func testLockPolicyWithoutResidualSignalStillLocks() {
    var policy = SharedArenaLockPolicy(thresholds: thresholds(streak: 1))
    XCTAssertEqual(
      policy.evaluate(observation(peer: peer(residual: nil)), nowMs: 0).state,
      .lockReady,
      "World-map runs have no participant anchor; residual is optional, not assumed"
    )
  }

  // MARK: - Metrics

  func testMetricsTrackLossOutOfOrderIntervalsAndAge() {
    var metrics = ArenaFrameMetrics()
    XCTAssertTrue(metrics.recordPeerSample(sequence: 1, arrivalMs: 1_000))
    XCTAssertTrue(metrics.recordPeerSample(sequence: 2, arrivalMs: 1_050))
    XCTAssertTrue(metrics.recordPeerSample(sequence: 5, arrivalMs: 1_100), "Gap of two lost samples")
    XCTAssertFalse(metrics.recordPeerSample(sequence: 4, arrivalMs: 1_110), "Late sample is rejected")
    XCTAssertFalse(metrics.recordPeerSample(sequence: 5, arrivalMs: 1_120), "Duplicate is rejected")
    XCTAssertTrue(metrics.recordPeerSample(sequence: 6, arrivalMs: 1_300))

    let summary = metrics.summary(nowMs: 1_340)
    XCTAssertEqual(summary.samplesAccepted, 4)
    XCTAssertEqual(summary.samplesOutOfOrder, 2)
    XCTAssertEqual(summary.samplesLost, 2)
    XCTAssertEqual(summary.updateIntervalP50Ms, 50)
    XCTAssertEqual(summary.updateIntervalP95Ms, 200)
    XCTAssertEqual(summary.updateIntervalP99Ms, 200)
    XCTAssertEqual(summary.latestPoseAgeMs, 40)

    metrics.resetPeerSequence()
    XCTAssertTrue(metrics.recordPeerSample(sequence: 1, arrivalMs: 2_000))
    XCTAssertEqual(metrics.summary(nowMs: 2_000).samplesLost, 2, "Reconnect is not a loss burst")
  }

  func testMetricsRecoveryStatsAndPercentileEdges() {
    var metrics = ArenaFrameMetrics()
    XCTAssertEqual(metrics.summary(nowMs: 0), .empty)

    metrics.recordLockLoss()
    metrics.recordRecovery(ms: 400)
    metrics.recordLockLoss()
    metrics.recordRecovery(ms: 1_200)
    let summary = metrics.summary(nowMs: 0)
    XCTAssertEqual(summary.lockLosses, 2)
    XCTAssertEqual(summary.recoveryMsMax, 1_200)
    XCTAssertEqual(summary.recoveryMsMean, 800)

    XCTAssertNil(ArenaFrameMetrics.percentile([], 50))
    XCTAssertEqual(ArenaFrameMetrics.percentile([7], 99), 7)
    XCTAssertEqual(ArenaFrameMetrics.percentile([1, 2, 3, 4], 50), 2)
    XCTAssertEqual(ArenaFrameMetrics.percentile([1, 2, 3, 4], 100), 4)
  }

  func testLogRecordCsvIsStableAndEscaped() throws {
    XCTAssertEqual(
      ArenaLogRecord.csvHeader,
      "elapsed_ms,role,method,local_tracking,mapping_status,lock_state,peer_seq,peer_age_ms,"
        + "inter_phone_distance_m,residual_translation_m,residual_yaw_deg,bytes_in,bytes_out,thermal_state"
    )
    let record = ArenaLogRecord(
      elapsedMs: 1_500,
      role: .guest,
      method: .collaborative,
      localTracking: .limited(.insufficientFeatures),
      mappingStatus: .extending,
      lockState: .trackingLost(.localTracking),
      peerSequence: 88,
      peerAgeMs: 33,
      interPhoneDistanceMeters: 7.98765,
      residual: residual(0.0421, 0.31),
      bytesIn: 2_048,
      bytesOut: 512,
      thermalState: "fair, \"hot\""
    )
    XCTAssertEqual(
      record.csvLine,
      "1500,guest,collaborative,limited:insufficientFeatures,extending,trackingLost:localTracking,"
        + "88,33,7.9877,0.0421,0.3100,2048,512,\"fair, \"\"hot\"\"\""
    )
    let sparse = ArenaLogRecord(
      elapsedMs: 0, role: .host, method: .worldMap, localTracking: .normal, mappingStatus: .mapped,
      lockState: .lockReady, peerSequence: nil, peerAgeMs: nil, interPhoneDistanceMeters: nil,
      residual: nil, bytesIn: 0, bytesOut: 0, thermalState: "nominal"
    )
    XCTAssertEqual(sparse.csvLine, "0,host,worldMap,normal,mapped,lockReady,,,,,,0,0,nominal")
  }

  // MARK: - Link framing

  func testLinkCodecRoundTripsEveryKindThroughAFragmentedStream() throws {
    let sample = ArenaPeerSample(
      playerId: "host-1",
      sequence: 9,
      timestampMs: 5_000,
      tracking: .normal,
      arenaFromPhone: try yawTransform(degrees: 90, translation: ArenaVector3(x: 0, y: 1.2, z: -3))
    )
    let anchors = [
      ArenaNamedAnchor(name: "arena-anchor-0", transform: .identity),
      ArenaNamedAnchor(name: "arena-anchor-1", transform: try .translation(x: 2, y: 0, z: 0)),
    ]
    let messages: [ArenaLinkMessage] = [
      .hello(playerId: "host-1", role: .host, method: .collaborative),
      .poseSample(sample),
      .collaboration(Data(repeating: 0xAB, count: 3_000)),
      .worldMap(Data(repeating: 0xCD, count: 70_000)),
      .anchorSet(anchors),
    ]
    let stream = try messages.map(ArenaLinkCodec.encode).reduce(Data(), +)

    var buffer = Data()
    var decoded: [ArenaLinkMessage] = []
    var cursor = stream.startIndex
    while cursor < stream.endIndex {
      let next = min(stream.endIndex, cursor + 1_234)
      buffer.append(stream[cursor..<next])
      decoded += try ArenaLinkCodec.drainFrames(from: &buffer)
      cursor = next
    }
    XCTAssertEqual(decoded, messages)
    XCTAssertTrue(buffer.isEmpty)
    XCTAssertEqual(try anchors[1].transform().translation, ArenaVector3(x: 2, y: 0, z: 0))
  }

  func testLinkCodecRejectsUnknownKindOversizeAndMalformedPayload() throws {
    var unknown = Data()
    withUnsafeBytes(of: UInt32(1).littleEndian) { unknown.append(contentsOf: $0) }
    unknown.append(99)
    XCTAssertThrowsError(try ArenaLinkCodec.drainFrames(from: &unknown)) { error in
      XCTAssertEqual(error as? ArenaLinkCodecError, .unknownKind)
    }

    var oversize = Data()
    withUnsafeBytes(of: UInt32(ArenaLinkCodec.maxPayloadLength + 1).littleEndian) {
      oversize.append(contentsOf: $0)
    }
    XCTAssertThrowsError(try ArenaLinkCodec.drainFrames(from: &oversize)) { error in
      XCTAssertEqual(error as? ArenaLinkCodecError, .payloadTooLarge)
    }

    var malformedPose = Data()
    withUnsafeBytes(of: UInt32(4).littleEndian) { malformedPose.append(contentsOf: $0) }
    malformedPose.append(contentsOf: [2, 0, 0, 0])
    XCTAssertThrowsError(try ArenaLinkCodec.drainFrames(from: &malformedPose)) { error in
      XCTAssertEqual(error as? ArenaLinkCodecError, .malformedPayload)
    }

    var partial = try ArenaLinkCodec.encode(.worldMap(Data(count: 100)))
    partial.removeLast()
    XCTAssertEqual(try ArenaLinkCodec.drainFrames(from: &partial), [])
    XCTAssertEqual(partial.count, 4 + 1 + 99, "Partial frame stays buffered")
  }

  // MARK: - Helpers

  private func yawTransform(degrees: Double, translation: ArenaVector3) throws -> ArenaRigidTransform {
    let radians = degrees * .pi / 180
    var storage = ArenaRigidTransform.identityStorage
    storage[0] = cos(radians)
    storage[2] = -sin(radians)
    storage[8] = sin(radians)
    storage[10] = cos(radians)
    storage[12] = translation.x
    storage[13] = translation.y
    storage[14] = translation.z
    return try ArenaRigidTransform(columnMajor: storage)
  }

  private func thresholds(streak: Int) -> ArenaLockThresholds {
    var thresholds = ArenaLockThresholds.phaseOne
    thresholds.lockConsecutiveEvaluations = streak
    return thresholds
  }

  private func residual(_ translation: Double, _ yaw: Double) -> ArenaAlignmentResidual {
    ArenaAlignmentResidual(translationMeters: translation, yawDegrees: yaw)
  }

  private func peer(
    tracking: ArenaTrackingQuality = .normal,
    ageMs: Int64 = 40,
    residual: ArenaAlignmentResidual? = ArenaAlignmentResidual(translationMeters: 0.04, yawDegrees: 0.2)
  ) -> ArenaPeerObservation {
    ArenaPeerObservation(tracking: tracking, ageMs: ageMs, residual: residual)
  }

  private func observation(
    localTracking: ArenaLocalTracking = .normal,
    mapping: ArenaMappingStatus = .mapped,
    merge: Bool = true,
    peer: ArenaPeerObservation? = ArenaPeerObservation(
      tracking: .normal,
      ageMs: 40,
      residual: ArenaAlignmentResidual(translationMeters: 0.04, yawDegrees: 0.2)
    )
  ) -> ArenaLockObservation {
    ArenaLockObservation(
      localTracking: localTracking,
      mappingStatus: mapping,
      mergeObserved: merge,
      peer: peer
    )
  }
}
