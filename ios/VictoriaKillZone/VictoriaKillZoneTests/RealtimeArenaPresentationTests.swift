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

  func testRelocalizedFrameNeverShowsReferenceControls() {
    for stage in [RealtimeArenaStage.mapping, .mapReady] {
      let controls = RealtimeArenaPresentation.ReferenceSetup(stage: stage, isHost: true,
        usesSavedArena: false, usesQuickPlayFrame: true)
      XCTAssertFalse(controls.isVisible, "Quick Play shares the raw map; there is no reference step")
      XCTAssertFalse(controls.captureAvailable)
    }
  }

  func testCollaborativeSetupNamesLinkingWithoutLegacyScanCopy() {
    for stage in [RealtimeArenaStage.mapping, .relocalizing] {
      let setup = RealtimeArenaPresentation.CollaborativeSetup(stage: stage,
        frameStage: .mapping, aligned: 0, total: 2)
      XCTAssertEqual(setup.title, "Linking play area")
      XCTAssertFalse(setup.guidance.lowercased().contains("scan"))
      XCTAssertFalse(setup.guidance.lowercased().contains("share"))
      XCTAssertFalse(setup.guidance.lowercased().contains("host"))
      XCTAssertTrue(setup.showsProgress)
    }
    let relocalizingFrame = RealtimeArenaPresentation.CollaborativeSetup(stage: .awaitingMembers,
      frameStage: .relocalizingWorld, aligned: 1, total: 3)
    XCTAssertEqual(relocalizingFrame.title, "Linking play area")

    let awaiting = RealtimeArenaPresentation.CollaborativeSetup(stage: .awaitingMembers,
      frameStage: .aligned, aligned: 1, total: 3)
    XCTAssertEqual(awaiting.title, "Aligned")
    XCTAssertTrue(awaiting.guidance.contains("(1/3)"))
    XCTAssertFalse(awaiting.showsProgress)

    let degraded = RealtimeArenaPresentation.CollaborativeSetup(stage: .paused,
      frameStage: .degraded, aligned: 1, total: 3)
    XCTAssertEqual(degraded.title, "Re-aligning")
    XCTAssertEqual(degraded.guidance, "Hold steady — re-aligning")
    XCTAssertTrue(degraded.showsProgress)

    let lost = RealtimeArenaPresentation.CollaborativeSetup(stage: .paused,
      frameStage: .lost, aligned: 1, total: 3)
    XCTAssertEqual(lost.title, "Alignment lost")
    XCTAssertFalse(lost.guidance.lowercased().contains("host"))
    XCTAssertFalse(lost.showsProgress)

    let running = RealtimeArenaPresentation.CollaborativeSetup(stage: .running,
      frameStage: .aligned, aligned: 2, total: 2)
    XCTAssertEqual(running.title, RealtimeArenaStage.running.title)
    XCTAssertFalse(running.showsProgress)
  }

  func testCollaborativeModeHidesScanControls() {
    XCTAssertFalse(RealtimeArenaPresentation.showsScanControls(isHost: true,
      usesSavedArena: false, usesCollaborativeFrame: true, stage: .mapping, scanTimedOut: false))
    XCTAssertFalse(RealtimeArenaPresentation.showsScanControls(isHost: true,
      usesSavedArena: false, usesCollaborativeFrame: true, stage: .running, scanTimedOut: true))
    XCTAssertTrue(RealtimeArenaPresentation.showsScanControls(isHost: true,
      usesSavedArena: false, usesCollaborativeFrame: false, stage: .mapping, scanTimedOut: false))
    XCTAssertTrue(RealtimeArenaPresentation.showsScanControls(isHost: true,
      usesSavedArena: false, usesCollaborativeFrame: false, stage: .paused, scanTimedOut: true))
    XCTAssertFalse(RealtimeArenaPresentation.showsScanControls(isHost: false,
      usesSavedArena: false, usesCollaborativeFrame: false, stage: .mapping, scanTimedOut: false))
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

  func testRendezvousCopyNamesTheRitualWithoutLegacySetupWords() {
    let phases: [NearbyRendezvousPhase] = [
      .awaitingTokens(received: 1, expected: 3), .pointing(solved: 0, expected: 3),
      .retryFacing(pending: 2), .solved(count: 3), .permissionDenied,
    ]
    for phase in phases {
      let setup = RealtimeArenaPresentation.RendezvousSetup(phase: phase)
      XCTAssertFalse(setup.guidance.lowercased().contains("share"), "\(phase)")
      XCTAssertFalse(setup.guidance.lowercased().contains("host"), "\(phase)")
    }
    for phase in [NearbyRendezvousPhase.pointing(solved: 0, expected: 2), .solved(count: 2),
      .retryFacing(pending: 1), .awaitingTokens(received: 0, expected: 2)] {
      let setup = RealtimeArenaPresentation.RendezvousSetup(phase: phase)
      XCTAssertFalse(setup.guidance.lowercased().contains("scan"), "\(phase)")
    }
  }

  func testRendezvousProgressAndRecoveryFlags() {
    XCTAssertTrue(RealtimeArenaPresentation.RendezvousSetup(phase: .awaitingTokens(received: 1, expected: 2)).showsProgress)
    XCTAssertTrue(RealtimeArenaPresentation.RendezvousSetup(phase: .pointing(solved: 0, expected: 2)).showsProgress)
    XCTAssertTrue(RealtimeArenaPresentation.RendezvousSetup(phase: .retryFacing(pending: 1)).showsRetry)
    let denied = RealtimeArenaPresentation.RendezvousSetup(phase: .permissionDenied)
    XCTAssertTrue(denied.showsRetry); XCTAssertTrue(denied.showsSettings)
    XCTAssertNil(RealtimeArenaPresentation.rendezvousSetup(phase: .inactive))
    XCTAssertNil(RealtimeArenaPresentation.rendezvousSetup(phase: .unsupported))
    XCTAssertNotNil(RealtimeArenaPresentation.rendezvousSetup(phase: .solved(count: 2)))
    let lost = RealtimeArenaPresentation.RendezvousSetup(phase: .sessionLost)
    XCTAssertEqual(lost.title, "Nearby Interaction dropped")
    XCTAssertTrue(lost.showsRetry); XCTAssertFalse(lost.showsSettings)
    XCTAssertFalse(lost.guidance.lowercased().contains("scan"))
    XCTAssertFalse(lost.guidance.lowercased().contains("host"))
  }

  private func field(owner: String, start: Double, end: Double) -> CombatWire.SlowField {
    .init(fieldId: "\(owner)-\(start)", ownerId: owner, center: [0, 0, 0], radius: 2,
      startsAtMs: start, endsAtMs: end, scale: 0.25)
  }
}
