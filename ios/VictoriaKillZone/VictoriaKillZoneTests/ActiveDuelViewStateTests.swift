import XCTest

@testable import VictoriaKillZone

final class ActiveDuelViewStateTests: XCTestCase {
  func testVoiceEligibilityRequiresEverySafetyGate() {
    let eligible = VoiceFireEligibility(
      duelIsRunning: true,
      storeCanDebugFire: true,
      networkIsFresh: true,
      poseIsFresh: true,
      hasStableHitZone: true
    )
    XCTAssertTrue(eligible.isEligible)

    XCTAssertFalse(VoiceFireEligibility(
      duelIsRunning: false,
      storeCanDebugFire: true,
      networkIsFresh: true,
      poseIsFresh: true,
      hasStableHitZone: true
    ).isEligible)
    XCTAssertFalse(VoiceFireEligibility(
      duelIsRunning: true,
      storeCanDebugFire: false,
      networkIsFresh: true,
      poseIsFresh: true,
      hasStableHitZone: true
    ).isEligible)
    XCTAssertFalse(VoiceFireEligibility(
      duelIsRunning: true,
      storeCanDebugFire: true,
      networkIsFresh: false,
      poseIsFresh: true,
      hasStableHitZone: true
    ).isEligible)
    XCTAssertFalse(VoiceFireEligibility(
      duelIsRunning: true,
      storeCanDebugFire: true,
      networkIsFresh: true,
      poseIsFresh: false,
      hasStableHitZone: true
    ).isEligible)
    XCTAssertFalse(VoiceFireEligibility(
      duelIsRunning: true,
      storeCanDebugFire: true,
      networkIsFresh: true,
      poseIsFresh: true,
      hasStableHitZone: false
    ).isEligible)
  }

  func testOutgoingLaserHasDeterministicTargetAndLifetime() {
    let start = Date(timeIntervalSince1970: 100)
    let target = LaserPoint(x: 0.3, y: 0.7)
    var state = ActiveDuelEffectState()

    state.triggerOutgoing(target: target, at: start, duration: 0.2)

    XCTAssertEqual(state.outgoing?.direction, .outgoing(target: target))
    XCTAssertTrue(state.outgoing?.isVisible(at: start.addingTimeInterval(0.199)) == true)
    state.expire(at: start.addingTimeInterval(0.2))
    XCTAssertNil(state.outgoing)
  }

  func testIncomingLaserOnlyAppearsForNewOpponentAuthoredHitOnLocalPlayer() {
    let start = Date(timeIntervalSince1970: 200)
    let historical = event(id: "old", actor: "opponent", target: "local")
    let localHit = event(id: "mine", actor: "local", target: "opponent")
    let opponentHit = event(id: "new", actor: "opponent", target: "local")
    var state = ActiveDuelEffectState()

    XCTAssertFalse(state.observe(events: [historical], localPlayerID: "local", at: start))
    XCTAssertNil(state.incoming)
    XCTAssertFalse(state.observe(events: [localHit, historical], localPlayerID: "local", at: start))
    XCTAssertNil(state.incoming)
    XCTAssertTrue(state.observe(events: [opponentHit, localHit, historical], localPlayerID: "local", at: start))
    XCTAssertNotNil(state.incoming)

    let first = state.incoming
    XCTAssertFalse(state.observe(events: [opponentHit, localHit, historical], localPlayerID: "local", at: start))
    XCTAssertEqual(state.incoming, first)
    state.expire(at: start.addingTimeInterval(0.2))
    XCTAssertNil(state.incoming)
  }

  private func event(id: String, actor: String, target: String) -> EventSnapshot {
    EventSnapshot(
      id: id,
      type: .hit,
      message: "hit",
      createdAt: 1,
      actorPlayerId: actor,
      targetPlayerId: target,
      zone: "torso",
      damage: 34
    )
  }
}
