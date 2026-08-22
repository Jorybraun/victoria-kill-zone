import Foundation
import XCTest
@testable import VictoriaKillZone

final class TargetingStateMachineTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000)
  private let bounds = NormalizedTargetingRect(
    minX: 0.25,
    minY: 0.2,
    width: 0.5,
    height: 0.65
  )
  private let torsoBounds = NormalizedTargetingRect(
    minX: 0.33,
    minY: 0.35,
    width: 0.34,
    height: 0.35
  )

  func testSessionMovesFromUnavailableThroughCameraStartingToSearching() {
    var machine = TargetingStateMachine(now: t0)
    XCTAssertEqual(machine.snapshot.state, .targetingUnavailable)

    machine.sessionStarted(at: time(0.01))
    XCTAssertEqual(machine.snapshot.state, .cameraStarting)

    machine.cameraBecameReady(at: time(0.02))
    XCTAssertEqual(machine.snapshot.state, .searching)
  }

  func testValidBodyWithoutTorsoProducesBodyLock() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.72),
      evaluatedAt: time(0.06)
    )

    XCTAssertEqual(machine.snapshot.state, .bodyLock)
    XCTAssertTrue(machine.snapshot.bodyDetected)
    XCTAssertFalse(machine.snapshot.torsoDetected)
    XCTAssertTrue(machine.snapshot.isPoseFresh(at: time(0.2)))
  }

  func testValidShouldersAndLowerAnchorProduceTorsoLock() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.78, torsoConfidence: 0.66),
      evaluatedAt: time(0.06)
    )

    XCTAssertEqual(machine.snapshot.state, .bodyLock)
    XCTAssertNil(machine.snapshot.hitZone)

    machine.ingest(
      observation(at: 0.13, bodyConfidence: 0.78, torsoConfidence: 0.66),
      evaluatedAt: time(0.14)
    )

    XCTAssertEqual(machine.snapshot.state, .torsoLock)
    XCTAssertTrue(machine.snapshot.bodyDetected)
    XCTAssertTrue(machine.snapshot.torsoDetected)
    XCTAssertEqual(machine.snapshot.hitZone, .torso)
    XCTAssertEqual(machine.snapshot.torsoBounds, torsoBounds)
  }

  func testHeadRegionWinsWhenHeadAndTorsoOverlapCrosshair() {
    var machine = readyMachine()
    let overlappingHead = NormalizedTargetingEllipse(
      centerX: 0.5,
      centerY: 0.5,
      radiusX: 0.08,
      radiusY: 0.1
    )
    machine.ingest(
      observation(
        at: 0.05,
        bodyConfidence: 0.84,
        torsoConfidence: 0.7,
        headRegion: overlappingHead
      ),
      evaluatedAt: time(0.06)
    )

    XCTAssertEqual(machine.snapshot.state, .bodyLock)
    XCTAssertNil(machine.snapshot.hitZone)

    machine.ingest(
      observation(
        at: 0.13,
        bodyConfidence: 0.84,
        torsoConfidence: 0.7,
        headRegion: overlappingHead
      ),
      evaluatedAt: time(0.14)
    )

    XCTAssertEqual(machine.snapshot.state, .bodyLock)
    XCTAssertEqual(machine.snapshot.hitZone, .head)
  }

  func testTorsoOffCrosshairKeepsBodyLockWithoutAimSolution() {
    var machine = readyMachine()
    let offCenterTorso = NormalizedTargetingPolygon(points: [
      point(0.08, 0.7), point(0.3, 0.7), point(0.28, 0.3), point(0.1, 0.3),
    ])
    machine.ingest(
      observation(
        at: 0.05,
        bodyConfidence: 0.8,
        torsoConfidence: 0.7,
        torsoRegion: offCenterTorso
      ),
      evaluatedAt: time(0.06)
    )

    XCTAssertEqual(machine.snapshot.state, .bodyLock)
    XCTAssertTrue(machine.snapshot.torsoDetected)
    XCTAssertNil(machine.snapshot.hitZone)
  }

  func testHeadFallbackUsesNeckAndShoulderScale() throws {
    let region = try XCTUnwrap(
      TargetingRegionBuilder.headRegion(
        facialPoints: [],
        neck: point(0.5, 0.55),
        leftShoulder: point(0.3, 0.5),
        rightShoulder: point(0.7, 0.5)
      )
    )

    XCTAssertEqual(region.centerX, 0.5, accuracy: 0.0001)
    XCTAssertEqual(region.centerY, 0.678, accuracy: 0.0001)
    XCTAssertEqual(region.radiusX, 0.096, accuracy: 0.0001)
    XCTAssertEqual(region.radiusY, 0.128, accuracy: 0.0001)
    XCTAssertTrue(region.contains(x: 0.5, y: 0.678))
  }

  func testHeadRegionUsesConfidentFacialJointMean() throws {
    let region = try XCTUnwrap(
      TargetingRegionBuilder.headRegion(
        facialPoints: [
          point(0.46, 0.7, confidence: 0.7),
          point(0.54, 0.7, confidence: 0.8),
          point(0.9, 0.9, confidence: 0.59),
        ],
        neck: nil,
        leftShoulder: point(0.3, 0.5),
        rightShoulder: point(0.7, 0.5)
      )
    )

    XCTAssertEqual(region.centerX, 0.5, accuracy: 0.0001)
    XCTAssertEqual(region.centerY, 0.7, accuracy: 0.0001)
  }

  func testTorsoRegionBuildsJointPolygonAroundCenter() throws {
    let region = try XCTUnwrap(
      TargetingRegionBuilder.torsoRegion(
        leftShoulder: point(0.3, 0.7),
        rightShoulder: point(0.7, 0.7),
        leftHip: point(0.35, 0.3),
        rightHip: point(0.65, 0.3),
        root: nil
      )
    )

    XCTAssertTrue(region.contains(x: 0.5, y: 0.5))
    XCTAssertFalse(region.contains(x: 0.1, y: 0.5))
  }

  func testPoseBecomesStaleBeforeTrackingIsDeclaredLost() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.78, torsoConfidence: 0.66),
      evaluatedAt: time(0.06)
    )
    machine.ingest(
      observation(at: 0.15, bodyConfidence: 0.78, torsoConfidence: 0.66),
      evaluatedAt: time(0.16)
    )

    machine.tick(at: time(0.36))

    XCTAssertEqual(machine.snapshot.state, .torsoLock)
    XCTAssertFalse(machine.snapshot.isPoseFresh(at: time(0.36)))
    XCTAssertNil(machine.snapshot.hitZone)
  }

  func testTrackingLostThenSearchingUseExplicitAgeThresholds() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.78, torsoConfidence: 0.66),
      evaluatedAt: time(0.06)
    )

    machine.noBodyObserved(capturedAt: time(0.4), evaluatedAt: time(0.41))
    XCTAssertEqual(machine.snapshot.state, .trackingLost)
    XCTAssertFalse(machine.snapshot.bodyDetected)

    machine.tick(at: time(1.06))
    XCTAssertEqual(machine.snapshot.state, .searching)
  }

  func testTargetReacquiredIsHeldBeforeReturningToLockState() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.78),
      evaluatedAt: time(0.06)
    )
    machine.tick(at: time(0.41))
    XCTAssertEqual(machine.snapshot.state, .trackingLost)

    machine.ingest(
      observation(at: 0.42, bodyConfidence: 0.82, torsoConfidence: 0.7),
      evaluatedAt: time(0.43)
    )
    XCTAssertEqual(machine.snapshot.state, .targetReacquired)
    XCTAssertTrue(machine.snapshot.torsoDetected)

    machine.ingest(
      observation(at: 0.51, bodyConfidence: 0.82, torsoConfidence: 0.7),
      evaluatedAt: time(0.52)
    )
    XCTAssertEqual(machine.snapshot.state, .targetReacquired)
    XCTAssertTrue(machine.snapshot.torsoDetected)

    machine.tick(at: time(0.74))
    XCTAssertEqual(machine.snapshot.state, .torsoLock)
  }

  func testLowConfidenceAndLateObservationsCannotAcquireTarget() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.44, torsoConfidence: 0.8),
      evaluatedAt: time(0.06)
    )
    XCTAssertEqual(machine.snapshot.state, .searching)

    machine.ingest(
      observation(at: 0.1, bodyConfidence: 0.9, torsoConfidence: 0.9),
      evaluatedAt: time(0.31)
    )
    XCTAssertEqual(machine.snapshot.state, .searching)
  }

  func testOutOfOrderVisionResultCannotReplaceNewerPose() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.1, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.11)
    )
    machine.ingest(
      observation(at: 0.19, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.20)
    )
    machine.ingest(
      observation(at: 0.09, bodyConfidence: 0.9),
      evaluatedAt: time(0.21)
    )

    XCTAssertEqual(machine.snapshot.state, .torsoLock)
    XCTAssertEqual(machine.snapshot.poseObservedAt, time(0.19))
  }

  func testUnavailableClearsPoseAndCameraRay() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.06)
    )
    machine.updateCameraRay(
      TargetingCameraRay(
        origin: TargetingVector3(x: 0, y: 1, z: 2),
        direction: TargetingVector3(x: 0, y: 0, z: -1),
        capturedAtMonotonic: 123.45
      ),
      at: time(0.07)
    )

    machine.sessionBecameUnavailable(at: time(0.08))

    XCTAssertEqual(machine.snapshot.state, .targetingUnavailable)
    XCTAssertNil(machine.snapshot.poseObservedAt)
    XCTAssertNil(machine.snapshot.cameraRay)
  }

  func testPreviewTransformConvertsVisionCoordinatesIntoPortraitAspectFillViewport() {
    let transform = TargetingPreviewTransform(
      imageWidth: 1_440,
      imageHeight: 1_920,
      viewportWidth: 390,
      viewportHeight: 844
    )

    XCTAssertEqual(transform.convert(x: 0.5, y: 0.5).x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(transform.convert(x: 0.5, y: 0.5).y, 0.5, accuracy: 0.0001)
    XCTAssertLessThan(transform.convert(x: 0, y: 0.5).x, 0)
    XCTAssertGreaterThan(transform.convert(x: 1, y: 0.5).x, 1)
    XCTAssertEqual(transform.convert(x: 0.5, y: 1).y, 1, accuracy: 0.0001)
    XCTAssertEqual(transform.convert(x: 0.5, y: 0).y, 0, accuracy: 0.0001)
  }

  func testAimPublishesAfterTwoSameZoneObservationsSpanningStableDuration() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.06)
    )
    XCTAssertNil(machine.snapshot.hitZone)

    machine.ingest(
      observation(at: 0.15, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.16)
    )
    XCTAssertEqual(machine.snapshot.hitZone, .torso)
  }

  func testAimDoesNotPublishWhenTwoSameZoneObservationsAreUnderStableDuration() {
    var machine = readyMachine()
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.06)
    )
    XCTAssertNil(machine.snapshot.hitZone)

    machine.ingest(
      observation(at: 0.10, bodyConfidence: 0.8, torsoConfidence: 0.7),
      evaluatedAt: time(0.11)
    )
    XCTAssertNil(machine.snapshot.hitZone)
  }

  func testObservationPublishesPreviewSpaceJoints() {
    var machine = readyMachine()
    let joints = [point(0.4, 0.6), point(0.6, 0.6)]
    machine.ingest(
      observation(at: 0.05, bodyConfidence: 0.8, joints: joints),
      evaluatedAt: time(0.06)
    )

    XCTAssertEqual(machine.snapshot.joints, joints)
  }

  func testCameraRayCarriesMonotonicTimestamp() {
    let ray = TargetingCameraRay(
      origin: TargetingVector3(x: 0, y: 1, z: 2),
      direction: TargetingVector3(x: 0, y: 0, z: -1),
      capturedAtMonotonic: 987.65
    )

    XCTAssertEqual(ray.capturedAtMonotonic, 987.65)
  }

  private func readyMachine() -> TargetingStateMachine {
    var machine = TargetingStateMachine(now: t0)
    machine.sessionStarted(at: time(0.01))
    machine.cameraBecameReady(at: time(0.02))
    return machine
  }

  private func observation(
    at offset: TimeInterval,
    bodyConfidence: Double,
    torsoConfidence: Double? = nil,
    headRegion: NormalizedTargetingEllipse? = nil,
    torsoRegion: NormalizedTargetingPolygon? = nil,
    joints: [NormalizedTargetingPoint] = []
  ) -> TargetingObservation {
    let resolvedTorsoRegion = torsoConfidence == nil
      ? nil
      : torsoRegion ?? NormalizedTargetingPolygon(points: [
        point(0.33, 0.7),
        point(0.67, 0.7),
        point(0.67, 0.35),
        point(0.33, 0.35),
      ])
    return TargetingObservation(
      capturedAt: time(offset),
      bodyConfidence: bodyConfidence,
      torsoConfidence: torsoConfidence,
      bodyBounds: bounds,
      torsoBounds: resolvedTorsoRegion?.bounds,
      headRegion: headRegion,
      torsoRegion: resolvedTorsoRegion,
      joints: joints
    )
  }

  private func point(
    _ x: Double,
    _ y: Double,
    confidence: Double = 0.8
  ) -> NormalizedTargetingPoint {
    NormalizedTargetingPoint(x: x, y: y, confidence: confidence)
  }

  private func time(_ offset: TimeInterval) -> Date {
    t0.addingTimeInterval(offset)
  }
}
