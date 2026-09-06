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

  private func field(owner: String, start: Double, end: Double) -> CombatWire.SlowField {
    .init(fieldId: "\(owner)-\(start)", ownerId: owner, center: [0, 0, 0], radius: 2,
      startsAtMs: start, endsAtMs: end, scale: 0.25)
  }
}
