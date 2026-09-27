import Foundation
import XCTest

@testable import VictoriaKillZone

final class RealtimeArenaPresentationTests: XCTestCase {
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

  func testSightingCopyNeverMentionsSharedFrameCeremony() {
    let forbidden = ["align", "scan", "share arena", "shared arena", "linking", "relocaliz", "calibrat"]
    var copies = [
      RealtimeArenaPresentation.Sighting.startTitle,
      RealtimeArenaPresentation.Sighting.retryTrackingTitle,
    ]
    for stage in RealtimeArenaPresentation.Sighting.allStages {
      for clockReady in [true, false] {
        copies.append(RealtimeArenaPresentation.Sighting.title(stage: stage, clockReady: clockReady))
        for roundHasStarted in [true, false] {
          copies.append(RealtimeArenaPresentation.Sighting.guidance(
            stage: stage, clockReady: clockReady, roundHasStarted: roundHasStarted))
        }
      }
    }
    for connected in [true, false] {
      for health in [0, 50, 100] {
        copies.append(RealtimeArenaPresentation.Sighting.rosterStatus(
          connected: connected, health: health))
        copies.append(RealtimeArenaPresentation.Sighting.rosterAccessibilityStatus(
          connected: connected))
      }
    }
    for copy in copies {
      for term in forbidden {
        XCTAssertFalse(copy.lowercased().contains(term),
          "Sighting copy must not contain \(term): \(copy)")
      }
    }
    // Spot-check the settled labels so the audit cannot pass on empty copy.
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.startTitle, "PLAY")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.retryTrackingTitle, "Retry camera")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.title(stage: .awaitingMembers, clockReady: true),
      "Waiting for opponent")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.title(stage: .unavailable, clockReady: true),
      "Body tracking unavailable")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.title(stage: .paused, clockReady: false),
      "Stabilizing connection")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.guidance(
      stage: .paused, clockReady: true, roundHasStarted: false),
      "Point your camera at your opponent. The host can start once both players are ready.")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.rosterStatus(
      connected: true, health: 0), "Respawning")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.rosterStatus(
      connected: true, health: 66), "66 health")
    XCTAssertEqual(RealtimeArenaPresentation.Sighting.rosterStatus(
      connected: false, health: 66), "Disconnected")
  }

  func testSightingEligibilityReasonsStayFreeOfSharedFrameCeremony() {
    var snapshot = RealtimeCombatTests.snapshot()
    snapshot.phase = .calibrating
    var reasons: [String] = []
    for clock in [true, false] {
      for pose in [true, false] {
        for connected in [true, false] {
          snapshot.players[1].connected = connected
          reasons.append(RealtimeActionEligibility.evaluate(
          snapshot: snapshot, localPlayerID: "p1", clockReady: clock,
            sceneActive: true, canSubmit: true, poseFresh: pose, localFireAtMs: nil,
            matchTimeMs: 5000).reason)
        }
      }
    }
    snapshot.players[1].connected = true
    snapshot.phase = .running
    reasons.append(RealtimeActionEligibility.evaluate(
      snapshot: snapshot, localPlayerID: "p1", clockReady: true,
      sceneActive: true, canSubmit: true, poseFresh: true, localFireAtMs: nil,
      matchTimeMs: 5000).reason)
    let forbidden = ["align", "scan", "share arena", "linking", "relocaliz", "calibrat"]
    for reason in reasons {
      for term in forbidden {
        XCTAssertFalse(reason.lowercased().contains(term),
          "Sighting eligibility reason must not contain \(term): \(reason)")
      }
    }
  }

  private func field(owner: String, start: Double, end: Double) -> CombatWire.SlowField {
    .init(fieldId: "\(owner)-\(start)", ownerId: owner, center: [0, 0, 0], radius: 2,
      startsAtMs: start, endsAtMs: end, scale: 0.25)
  }
}
