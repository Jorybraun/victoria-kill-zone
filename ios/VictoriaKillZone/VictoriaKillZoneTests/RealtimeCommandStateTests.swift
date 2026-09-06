import Foundation
import XCTest
@testable import VictoriaKillZone

final class RealtimeCommandStateTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 5000)

  func testUnconfirmedShotsReserveMagazineUntilAuthorityResult() {
    var commands = RealtimeCommandState()
    for index in 0..<8 {commands.queued(.fire, id: "shot-\(index)")}
    XCTAssertEqual(commands.availableAmmo(8), 0)
    commands.resolve(id: "shot-0", accepted: true, reason: nil, at: now)
    XCTAssertEqual(commands.availableAmmo(7), 0, "Accepted shot consumes authority ammo and releases only its reservation")
    commands.resolve(id: "shot-1", accepted: false, reason: "cooldown", at: now)
    XCTAssertEqual(commands.availableAmmo(7), 1, "A refusal returns the local reservation without granting authority ammo")
    XCTAssertEqual(commands.availableAmmo(0), 0)
  }

  func testPendingBeginResolvesToActionableFeedbackWithoutChangingGamePhase() {
    var commands = RealtimeCommandState()
    commands.queued(.start, id: "begin")
    XCTAssertTrue(commands.contains(.start))
    commands.resolve(id: "begin", accepted: false, reason: "notReady", at: now)
    XCTAssertFalse(commands.contains(.start))
    XCTAssertEqual(commands.notice, "Keep every player and their phone visible, then try Begin match again.")
    commands.tick(at: now.addingTimeInterval(3.9)); XCTAssertNotNil(commands.notice)
    commands.tick(at: now.addingTimeInterval(4)); XCTAssertNil(commands.notice)
  }

  func testSplitSpawnPlayerAndResultBatchesNeverDoubleReserveAcceptedAmmo() {
    var commands = RealtimeCommandState()
    commands.queued(.fire, id: "command", shotID: "shot")
    XCTAssertEqual(commands.availableAmmo(2), 1)
    commands.projectileSpawned(shotID: "shot", atMs: 1000)
    XCTAssertEqual(commands.availableAmmo(2), 1, "Spawn alone does not mean the player update arrived")
    commands.playerChanged(lastFireAtMs: 900)
    XCTAssertEqual(commands.availableAmmo(2), 1, "An older player change cannot release this reservation")
    commands.playerChanged(lastFireAtMs: 1000)
    XCTAssertEqual(commands.availableAmmo(1), 1, "Player state already includes accepted ammo consumption")
    commands.queued(.fire, id: "next", shotID: "next-shot")
    XCTAssertEqual(commands.availableAmmo(1), 0)
    commands.resolve(id: "command", accepted: true, reason: nil, at: now)
    XCTAssertEqual(commands.availableAmmo(1), 0, "Late result releases no extra ammunition")
  }

  func testReplayAndOldResultsCannotReplaceNewerActionFeedback() {
    var commands = RealtimeCommandState()
    commands.queued(.fire, id: "older"); commands.queued(.slowField, id: "newer")
    commands.resolve(id: "newer", accepted: false, reason: "abilityCooldown", at: now)
    let notice = commands.notice
    commands.resolve(id: "older", accepted: false, reason: "outOfAmmo", at: now)
    commands.resolve(id: "newer", accepted: false, reason: "private raw error", at: now)
    XCTAssertEqual(commands.notice, notice)
  }

  func testSnapshotReleasesReflectedActionsButRetainsExactReplayReservations() {
    var commands = RealtimeCommandState()
    commands.queued(.fire, id: "committed"); commands.queued(.fire, id: "retry")
    commands.queued(.reload, id: "reload")
    commands.reconcile(pendingIDs: ["retry"])
    XCTAssertEqual(commands.availableAmmo(7), 6)
    XCTAssertFalse(commands.contains(.reload))
    commands.resolve(id: "retry", accepted: false, reason: "tooLate", at: now)
    XCTAssertEqual(commands.availableAmmo(7), 7)
    XCTAssertNotNil(commands.notice)
  }

  func testUnknownFailureDoesNotExposeRawTransportText() {
    var commands = RealtimeCommandState()
    commands.queued(.start, id: "begin")
    commands.resolve(id: "begin", accepted: false, reason: "untrusted transport text", at: now)
    XCTAssertEqual(commands.notice, "The action was not accepted. Try again when the arena is ready.")
  }

  func testRejectedReadinessRetriesAtBoundedCadenceUntilAuthorityAgrees() {
    var readiness = RealtimeReadinessState()
    XCTAssertTrue(readiness.shouldSubmit(ready: true, authoritative: false, at: now))
    readiness.queued(id: "first", ready: true, at: now)
    XCTAssertFalse(readiness.shouldSubmit(ready: true, authoritative: false, at: now.addingTimeInterval(0.1)))
    readiness.resolve(id: "first")
    XCTAssertFalse(readiness.shouldSubmit(ready: true, authoritative: false, at: now.addingTimeInterval(0.2)))
    XCTAssertTrue(readiness.shouldSubmit(ready: true, authoritative: false, at: now.addingTimeInterval(0.25)))
    readiness.queued(id: "retry", ready: true, at: now.addingTimeInterval(0.25))
    readiness.resolve(id: "retry")
    XCTAssertFalse(readiness.shouldSubmit(ready: true, authoritative: true, at: now.addingTimeInterval(0.5)))
  }

  func testTrackingLossOverridesPendingReadyAndOldResultCannotAcknowledgeNewTransition() {
    var readiness = RealtimeReadinessState()
    readiness.queued(id: "enable", ready: true, at: now)
    XCTAssertTrue(readiness.shouldSubmit(ready: false, authoritative: false, at: now.addingTimeInterval(0.01)))
    readiness.queued(id: "disable", ready: false, at: now.addingTimeInterval(0.01))
    readiness.resolve(id: "enable")
    XCTAssertFalse(readiness.shouldSubmit(ready: false, authoritative: true, at: now.addingTimeInterval(0.3)))
    XCTAssertTrue(readiness.shouldSubmit(ready: false, authoritative: true, at: now.addingTimeInterval(1.02)))
  }
}
