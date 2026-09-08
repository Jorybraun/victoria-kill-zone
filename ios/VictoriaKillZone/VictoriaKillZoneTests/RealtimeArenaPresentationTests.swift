import Foundation
import XCTest

@testable import VictoriaKillZone

final class RealtimeArenaPresentationTests: XCTestCase {
  func testReferenceControlsRemainVisibleThroughRecordedMappingReadinessDips() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, at: start)
    let samples: [(DuelFrameTracking, Bool)] = [
      (.normal, false), (.normal, true), (.limited, true),
      (.normal, true), (.normal, false), (.normal, true),
    ]
    for (index, sample) in samples.enumerated() {
      let time = start.addingTimeInterval(Double(index) / 10)
      _ = policy.ingest(.init(epoch: 1, frameID: nil, phase: .mapping, tracking: sample.0,
        isMapped: sample.1, pose: nil, observedAt: time, failure: nil), at: time)
      let stage: RealtimeArenaStage = policy.snapshot.stage == .mapReady ? .mapReady : .mapping
      let controls = RealtimeArenaPresentation.ReferenceSetup(stage: stage, isHost: true, usesSavedArena: false)
      XCTAssertTrue(controls.isVisible, "Capture must not disappear when tracking quality changes")
      XCTAssertEqual(controls.captureAvailable, sample.0 == .normal && sample.1)
      XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: time))
    }
  }

  func testReferenceCaptureControlsDoNotLeakIntoGuestSavedOrInterruptedFlows() {
    for stage in [RealtimeArenaStage.mapping, .mapReady] {
      XCTAssertFalse(RealtimeArenaPresentation.ReferenceSetup(stage: stage, isHost: false, usesSavedArena: false).isVisible)
      XCTAssertFalse(RealtimeArenaPresentation.ReferenceSetup(stage: stage, isHost: true, usesSavedArena: true).isVisible)
    }
    for stage in [RealtimeArenaStage.reconnecting, .paused, .unavailable, .transferringMap, .relocalizing, .running] {
      let controls = RealtimeArenaPresentation.ReferenceSetup(stage: stage, isHost: true, usesSavedArena: false)
      XCTAssertFalse(controls.isVisible)
      XCTAssertFalse(controls.captureAvailable)
    }
  }

  func testOnlyCurrentLocalFieldOverridesCooldownAndExpiresAtBoundary() {
    let fields = [field(owner: "local", start: 1000, end: 3000), field(owner: "remote", start: 1000, end: 9000)]
    XCTAssertEqual(RealtimeArenaPresentation.slowFieldStatus(fields: fields, localPlayerID: "local", readyAt: 11000, now: 1000), .active(seconds: 2))
    XCTAssertEqual(RealtimeArenaPresentation.slowFieldStatus(fields: fields, localPlayerID: "local", readyAt: 11000, now: 2999), .active(seconds: 1))
    XCTAssertEqual(RealtimeArenaPresentation.slowFieldStatus(fields: fields, localPlayerID: "local", readyAt: 11000, now: 3000), .cooldown(seconds: 8))
    XCTAssertEqual(RealtimeArenaPresentation.slowFieldStatus(fields: fields, localPlayerID: "local", readyAt: 11000, now: 11000), .ready)
  }

  func testFutureOrOtherPlayersFieldsDoNotClaimLocalAbilityIsActive() {
    let fields = [field(owner: "local", start: 5000, end: 7000), field(owner: "remote", start: 0, end: 9000)]
    XCTAssertEqual(RealtimeArenaPresentation.slowFieldStatus(fields: fields, localPlayerID: "local", readyAt: 0, now: 1000), .ready)
  }

  func testProtectionAndReloadReachTheirExactAuthorityTimeBoundaries() {
    XCTAssertNotNil(RealtimeArenaPresentation.protectionDetail(until: 2000, now: 1999))
    XCTAssertNil(RealtimeArenaPresentation.protectionDetail(until: 2000, now: 2000))
    XCTAssertNil(RealtimeArenaPresentation.protectionDetail(until: nil, now: 1000))
    XCTAssertEqual(RealtimeArenaPresentation.reloadProgress(until: 2250, duration: 1250, now: 1000), 0)
    XCTAssertEqual(RealtimeArenaPresentation.reloadProgress(until: 2250, duration: 1250, now: 1625), 0.5)
    XCTAssertEqual(RealtimeArenaPresentation.reloadProgress(until: 2250, duration: 1250, now: 2250), 1)
  }

  func testInvalidTimingCannotProduceNonfiniteProgressOrOverflow() {
    XCTAssertEqual(RealtimeArenaPresentation.secondsRemaining(until: .infinity, at: 1), 0)
    XCTAssertEqual(RealtimeArenaPresentation.secondsRemaining(until: 1, at: .nan), 0)
    XCTAssertEqual(RealtimeArenaPresentation.reloadProgress(until: 2000, duration: 0, now: 1000), 0)
    XCTAssertEqual(RealtimeArenaPresentation.reloadProgress(until: 2000, duration: 1250, now: .nan), 0)
  }

  private func field(owner: String, start: Double, end: Double) -> CombatWire.SlowField {
    .init(fieldId: "\(owner)-\(start)", ownerId: owner, center: [0, 0, 0], radius: 2,
      startsAtMs: start, endsAtMs: end, scale: 0.25)
  }
}
