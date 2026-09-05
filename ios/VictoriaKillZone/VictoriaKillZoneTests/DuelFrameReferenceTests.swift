import Foundation
import XCTest
@testable import VictoriaKillZone

final class DuelFrameReferenceTests: XCTestCase {
  func testNaturalPlaneUsesMeasuredCornersAndImageAnchorAxisConvention() throws {
    let plane = try referencePlane()
    XCTAssertEqual(plane.widthMeters, 1, accuracy: 0.000001)
    XCTAssertEqual(plane.heightMeters, 0.6, accuracy: 0.000001)
    XCTAssertEqual(Array(plane.mapFromImage[4...6]), [0, 0, 1], "Image anchor +Y points out of the observed surface")
    XCTAssertEqual(Array(plane.mapFromImage[8...10]), [0, -1, 0], "Image anchor -Z points toward image top")
    XCTAssertTrue(DuelFrameReferenceGeometry.isRigid(plane.mapFromImage))
  }

  func testObliqueNonPlanarSmallOrUnstableReferencesFailClosed() throws {
    let good = try referencePlane()
    XCTAssertThrowsError(try DuelFrameReferenceGeometry.plane(corners: good.corners, camera: SIMD3(3, 0, 0.5)))
    var bent = good.corners; bent[2].z = 0.2
    XCTAssertThrowsError(try DuelFrameReferenceGeometry.plane(corners: bent, camera: SIMD3(0, 0, 2)))
    XCTAssertThrowsError(try DuelFrameReferenceGeometry.plane(corners: good.corners.map { $0 * 0.1 }, camera: SIMD3(0, 0, 2)))
    let moved = try DuelFrameReferenceGeometry.plane(corners: good.corners.map { $0 + SIMD3(0.03, 0, 0) }, camera: SIMD3(0, 0, 2))
    XCTAssertThrowsError(try DuelFrameReferenceGeometry.maximumDeviation([good, good, moved]))
    XCTAssertEqual(try DuelFrameReferenceGeometry.maximumDeviation([good, good, good]), 0)
  }

  func testResidualMeasuresKnownTranslationAndConservativeFullOrientationError() throws {
    let reference = try makeFrameReference()
    var observed = reference.mapFromImage; observed[12] += 0.04; observed[14] += 0.03
    XCTAssertEqual(try DuelFrameReferenceGeometry.residual(expected: reference.mapFromImage, observed: observed).translationMeters,
      0.05, accuracy: 0.000001)
    let angle = 0.4 * Double.pi / 180
    let rotation = [cos(angle), 0, -sin(angle), 0, 0, 1, 0, 0, sin(angle), 0, cos(angle), 0, 0, 0, 0, 1.0]
    XCTAssertEqual(try DuelFrameReferenceGeometry.residual(expected: identity, observed: rotation).rotationDegrees,
      0.4, accuracy: 0.000001)
    var reflected = identity; reflected[0] = -1
    XCTAssertThrowsError(try DuelFrameReferenceGeometry.residual(expected: identity, observed: reflected))
  }

  func testOnlyFreshTrackedMatchingSensorEventsCountAndRepeatedTimestampCannotRenew() throws {
    let reference = try makeFrameReference(), date = Date(timeIntervalSince1970: 1_000)
    var policy = DuelFrameReferencePolicy()
    func observation(id: String? = nil, tracked: Bool = true, timestamp: Double = 1, captured: Date? = nil) -> DuelFrameReferenceObservation {
      DuelFrameReferenceObservation(referenceID: id ?? reference.id, mapFromImage: reference.mapFromImage,
        isTracked: tracked, frameTimestamp: timestamp, capturedAt: captured ?? date)
    }
    XCTAssertNotNil(try policy.measure(observation(), expected: reference, now: date))
    XCTAssertNil(try policy.measure(observation(captured: date.addingTimeInterval(0.02)), expected: reference, now: date.addingTimeInterval(0.02)))
    XCTAssertThrowsError(try policy.measure(observation(id: "wrong", timestamp: 2), expected: reference, now: date))
    XCTAssertThrowsError(try policy.measure(observation(tracked: false, timestamp: 2), expected: reference, now: date))
    XCTAssertThrowsError(try policy.measure(observation(timestamp: 2), expected: reference, now: date.addingTimeInterval(0.101)))
    XCTAssertThrowsError(try policy.measure(observation(timestamp: 2, captured: date.addingTimeInterval(0.01)), expected: reference, now: date))
  }

  func testAnchorCallbackTimeIsDerivedFromSensorFrameAndCannotFreshenCachedFrame() {
    let event = DuelFrameReferenceSensorEvent(referenceID: "reference", mapFromImage: identity, isTracked: true, frameTimestamp: 4)
    let date = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(event.observation(cameraTimestamp: 4.05, cameraCapturedAt: date)?.capturedAt.timeIntervalSince1970 ?? 0,
      999.95, accuracy: 0.000001)
    XCTAssertNil(event.observation(cameraTimestamp: 4.101, cameraCapturedAt: date))
    XCTAssertNil(event.observation(cameraTimestamp: 3.99, cameraCapturedAt: date))
  }

  func testDelegateBacklogCannotMakeOldSensorEvidenceFresh() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let capture = try XCTUnwrap(DuelFrameSensorTime.capturedAt(deliveredTimestamp: 5,
      latestTimestamp: 5.3, now: now))
    XCTAssertEqual(capture.timeIntervalSince1970, 999.7, accuracy: 0.000001)
    let event = DuelFrameReferenceSensorEvent(referenceID: "reference", mapFromImage: identity,
      isTracked: true, frameTimestamp: 4.98)
    let observation = try XCTUnwrap(event.observation(cameraTimestamp: 5, cameraCapturedAt: capture))
    XCTAssertFalse(DuelFramePolicy.isFresh(observation.capturedAt, at: now))
    XCTAssertNil(DuelFrameSensorTime.capturedAt(deliveredTimestamp: 5, latestTimestamp: 4.9, now: now))
    XCTAssertNil(DuelFrameSensorTime.capturedAt(deliveredTimestamp: .nan, latestTimestamp: 5, now: now))
  }

  func testValidatedReferenceCannotSilentlyChangeWithinInstalledPolicy() throws {
    let reference = try makeFrameReference(), now = Date()
    var policy = DuelFrameReferencePolicy()
    let observation = DuelFrameReferenceObservation(referenceID: reference.id, mapFromImage: reference.mapFromImage,
      isTracked: true, frameTimestamp: 1, capturedAt: now)
    XCTAssertNotNil(try policy.measure(observation, expected: reference, now: now))
    var changedTransform = reference.mapFromImage; changedTransform[12] += 0.02
    let changed = try DuelFrameReference(imageData: reference.imageData, widthMeters: reference.widthMeters,
      heightMeters: reference.heightMeters, mapFromImage: changedTransform, sampleCount: 3,
      maximumCornerDeviationMeters: 0)
    XCTAssertThrowsError(try policy.measure(observation, expected: changed, now: now))
  }

  func testBundleRoundTripAuthenticatesWholePayloadAndLegacyHasNoReference() throws {
    let reference = try makeFrameReference()
    let archive = Data([8, 7, 6, 5])
    let packet = try DuelFrameCalibrationBundle.encode(worldMap: archive, reference: reference)
    let map = try DuelFrameMap(epoch: 1, bytes: packet)
    XCTAssertEqual(map.worldMapBytes, archive)
    XCTAssertEqual(map.reference, reference)
    XCTAssertEqual(try DuelFrameMap(epoch: 1, bytes: map.bytes, expectedFrameID: map.frameID), map)
    XCTAssertNil(try DuelFrameMap(epoch: 1, bytes: archive).reference)
    var damaged = packet; damaged[damaged.count - 1] ^= 1
    XCTAssertThrowsError(try DuelFrameMap(epoch: 1, bytes: damaged, expectedFrameID: map.frameID))
    XCTAssertThrowsError(try DuelFrameCalibrationBundle.decode(packet + Data([0])))
    XCTAssertThrowsError(try DuelFrameCalibrationBundle.decode(packet.prefix(15)))
    var oversizedHeader = packet
    for index in 8..<12 { oversizedHeader[index] = 255 }
    XCTAssertThrowsError(try DuelFrameCalibrationBundle.decode(oversizedHeader))
    XCTAssertThrowsError(try DuelFrameCalibrationBundle.encode(worldMap: Data(count: DuelFrameMap.maximumBytes), reference: reference))
  }

  func testMalformedReferenceMetadataAndImageDigestAreRejected() throws {
    let reference = try makeFrameReference()
    let data = try JSONEncoder().encode(reference)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["widthMeters"] = -1
    XCTAssertFalse(try JSONDecoder().decode(DuelFrameReference.self, from: JSONSerialization.data(withJSONObject: json)).isValid)
    json["widthMeters"] = 1
    json["id"] = String(repeating: "0", count: 64)
    XCTAssertFalse(try JSONDecoder().decode(DuelFrameReference.self, from: JSONSerialization.data(withJSONObject: json)).isValid)
    XCTAssertThrowsError(try DuelFrameReference(imageData: Data(count: DuelFrameReference.maximumImageBytes + 1),
      widthMeters: 1, heightMeters: 0.6, mapFromImage: identity, sampleCount: 3, maximumCornerDeviationMeters: 0))
  }
}

@MainActor
final class DuelFrameReferenceProviderTests: XCTestCase {
  func testHostMustCaptureReferenceBeforeArchivingAndBundleContainsActualDriverResult() async throws {
    let driver = ReferenceFrameDriver()
    let active = DuelFrameProvider(targeting: driver)
    try await active.beginCalibration(epoch: 1)
    driver.emit(phase: .mapping, tracking: .normal, mapped: true)
    await settle()
    do { _ = try await active.captureMap(); XCTFail("Missing reference must never create a ready bundle") }
    catch { XCTAssertEqual(error as? DuelFrameFailure, .referenceUnavailable) }
    let summary = try await active.captureReference()
    XCTAssertEqual(active.referenceState, .captured(summary))
    XCTAssertEqual(active.referenceImageData, try makeFrameReference().imageData)
    let map = try await active.captureMap()
    XCTAssertEqual(map.reference?.summary, summary)
    XCTAssertEqual(map.worldMapBytes, Data([1, 2, 3]))
    await active.stop()
    XCTAssertNil(active.referenceImageData)
  }

  func testRealReferenceSamplesUnlockThenInvisibleReferenceImmediatelyClosesGate() async throws {
    let driver = ReferenceFrameDriver(), provider = DuelFrameProvider(targeting: driver)
    let reference = try makeFrameReference()
    let map = try DuelFrameMap(epoch: 1, bytes: DuelFrameCalibrationBundle.encode(worldMap: Data([1]), reference: reference))
    try await provider.beginCalibration(epoch: 1)
    try await provider.installMap(map)
    let steps: [(DuelFrameSessionPhase, DuelFrameTracking)] = [
      (.worldRelocalization, .relocalizing), (.worldRelocalization, .normal),
      (.bodyRelocalization, .relocalizing), (.bodyRelocalization, .normal),
    ]
    for (phase, tracking) in steps {
      driver.emit(map: map, phase: phase, tracking: tracking); await settle()
    }
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    for timestamp in [1.0, 1.03, 1.06] {
      let now = Date()
      driver.emit(map: map, phase: .bodyRelocalization, tracking: .normal,
        reference: DuelFrameReferenceObservation(referenceID: reference.id, mapFromImage: reference.mapFromImage,
          isTracked: true, frameTimestamp: timestamp, capturedAt: now))
      await settle()
    }
    XCTAssertTrue(provider.snapshot.permitsSpatialFire())
    driver.emit(map: map, phase: .bodyRelocalization, tracking: .normal,
      reference: DuelFrameReferenceObservation(referenceID: reference.id, mapFromImage: reference.mapFromImage,
        isTracked: false, frameTimestamp: 1.09, capturedAt: Date()))
    await settle()
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    XCTAssertEqual(provider.snapshot.failure, .referenceUnavailable)
    await provider.stop()
  }

  func testLegacyMapCannotGetResidualFromNormalTracking() async throws {
    let driver = ReferenceFrameDriver(), provider = DuelFrameProvider(targeting: driver)
    try await provider.beginCalibration(epoch: 1)
    let legacy = try DuelFrameMap(epoch: 1, bytes: Data([1]))
    try await provider.installMap(legacy)
    let steps: [(DuelFrameSessionPhase, DuelFrameTracking)] = [
      (.worldRelocalization, .relocalizing), (.worldRelocalization, .normal),
      (.bodyRelocalization, .relocalizing), (.bodyRelocalization, .normal),
    ]
    for (phase, tracking) in steps { driver.emit(map: legacy, phase: phase, tracking: tracking); await settle() }
    XCTAssertEqual(provider.referenceState, .unavailable)
    XCTAssertEqual(provider.snapshot.stage, .awaitingResidual, "Missing evidence remains an explicit setup step")
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    XCTAssertNil(provider.snapshot.residual)
    await provider.stop()
  }

  private func settle() async { try? await Task.sleep(for: .milliseconds(12)) }
}

private final class ReferenceFrameDriver: DuelFrameSessionDriving, @unchecked Sendable {
  let hub = DuelFrameObservationHub()
  func duelFrameObservations() -> AsyncStream<DuelFrameObservation> { hub.stream() }
  func beginFrameMapping(epoch: UInt16) async throws {}
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws {}
  func endFrameMapping() async {}
  func captureFrameReference(epoch: UInt16) async throws -> DuelFrameReference { try makeFrameReference() }
  func captureFrameMap(epoch: UInt16) async throws -> Data { Data([1, 2, 3]) }
  func emit(map: DuelFrameMap? = nil, phase: DuelFrameSessionPhase, tracking: DuelFrameTracking,
    mapped: Bool = false, reference: DuelFrameReferenceObservation? = nil) {
    let date = Date()
    hub.yield(DuelFrameObservation(epoch: map?.epoch ?? 1, frameID: map?.frameID, phase: phase,
      tracking: tracking, isMapped: mapped, pose: tracking == .normal
        ? DuelFramePose(columnMajor: identity, capturedAt: date, frameTimestamp: 1) : nil,
      observedAt: date, failure: nil, referenceObservation: reference))
  }
}
private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
private func referencePlane() throws -> DuelFrameReferencePlane {
  try DuelFrameReferenceGeometry.plane(corners: [SIMD3(-0.5, 0.3, 0), SIMD3(0.5, 0.3, 0),
    SIMD3(0.5, -0.3, 0), SIMD3(-0.5, -0.3, 0)], camera: SIMD3(0, 0, 2))
}
private func makeFrameReference() throws -> DuelFrameReference {
  let plane = try referencePlane()
  return try DuelFrameReference(imageData: Data([1, 2, 3]), widthMeters: plane.widthMeters,
    heightMeters: plane.heightMeters, mapFromImage: plane.mapFromImage, sampleCount: 3, maximumCornerDeviationMeters: 0.005)
}
