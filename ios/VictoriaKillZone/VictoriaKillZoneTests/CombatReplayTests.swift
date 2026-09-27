#if DEBUG
import Foundation
import XCTest

@testable import VictoriaKillZone

final class CombatReplayTests: XCTestCase {
  func testBundledEngineScenariosApplyThroughReplicaAndEndExactlyOnce() throws {
    let fixture = try CombatReplayFixture.bundled()
    XCTAssertEqual(Set(fixture.scenarios.map(\.id)), Set(CombatReplayFixture.ScenarioID.allCases))
    for scenario in fixture.scenarios {
      var session = try CombatReplaySession(scenario: scenario)
      try session.advance(to: scenario.endsAtMs)
      XCTAssertTrue(session.isComplete)
      XCTAssertEqual(session.acceptedSpawns, 1, scenario.id.rawValue)
      XCTAssertEqual(session.terminals.count, 1, scenario.id.rawValue)
      XCTAssertTrue(session.snapshot.projectiles.isEmpty)
      XCTAssertEqual(session.snapshot.players.first(where: { $0.id == "a" })?.ammo, 7)
      XCTAssertEqual(session.snapshot.players.first(where: { $0.id == "b" })?.health, scenario.id == .hit ? 66 : 100)
      XCTAssertEqual(session.terminals.first?.reason,
        scenario.id == .hit ? "bodyHit" : "missExpired")
      XCTAssertEqual(session.terminals.first?.damage, scenario.id == .hit ? 34 : 0)
    }
  }

  func testDuplicateHitPacketCannotChangeHealthOrAwardASecondTerminal() throws {
    var session = try makeSession(.hit)
    try session.advance(to: 600)
    let accepted = session.snapshot
    let sequence = session.replica.eventSequence
    let ignored = try session.replayLastPacket()
    XCTAssertGreaterThan(ignored, 0)
    XCTAssertEqual(session.snapshot, accepted)
    XCTAssertEqual(session.replica.eventSequence, sequence)
    XCTAssertEqual(session.acceptedSpawns, 1)
    XCTAssertEqual(session.terminals.count, 1)
    XCTAssertEqual(session.terminals.first?.damage, 34)
    XCTAssertEqual(session.duplicateEventsIgnored, ignored)
  }

  func testClearBlocksLateFramesAndRestartResetsAllEventIdentities() throws {
    var session = try makeSession(.hit)
    try session.advance(to: 600)
    session.clear()
    let snapshot = session.snapshot
    try session.advance(to: 950)
    XCTAssertEqual(session.snapshot, snapshot)
    XCTAssertTrue(session.presentation.projectiles.isEmpty)
    XCTAssertTrue(session.terminals.isEmpty)
    XCTAssertEqual(try session.replayLastPacket(), 0)
    try session.restart()
    XCTAssertFalse(session.isCleared)
    XCTAssertEqual(session.acceptedSpawns, 0)
    XCTAssertEqual(session.acceptedSegments, 0)
    XCTAssertEqual(session.replica.eventSequence, 0)
    XCTAssertEqual(session.duplicateEventsIgnored, 0)
    XCTAssertTrue(session.terminals.isEmpty)
    XCTAssertTrue(session.recentEvents.isEmpty)
    XCTAssertTrue(session.snapshot.players.allSatisfy { $0.health == 100 && $0.ammo == 8 })
    try session.advance(to: 600)
    XCTAssertEqual(session.acceptedSpawns, 1)
    XCTAssertEqual(session.terminals.count, 1)
    XCTAssertEqual(session.snapshot.players.first(where: { $0.id == "b" })?.health, 66)
  }

  func testLoaderRejectsOversizedUnknownVersionAndInvalidTimelines() throws {
    XCTAssertThrowsError(try CombatReplayFixture.decode(Data(repeating: 32, count: CombatReplayFixture.maximumBytes + 1))) {
      XCTAssertEqual($0 as? CombatReplayFixture.Failure, .sizeLimit)
    }
    try assertInvalidFixture { $0["version"] = 2 }
    try assertInvalidFixture { $0["scenarios"] = [] }
    try assertInvalidFixture { root in
      var scenarios = root["scenarios"] as! [[String: Any]]
      var frames = scenarios[0]["frames"] as! [[String: Any]]
      frames[0]["atMs"] = 99
      scenarios[0]["frames"] = frames
      root["scenarios"] = scenarios
    }
    try assertInvalidFixture { root in
      var scenarios = root["scenarios"] as! [[String: Any]]
      var frames = scenarios[0]["frames"] as! [[String: Any]]
      var events = frames[0]["events"] as! [[String: Any]]
      events[0]["eventSequence"] = 20
      frames[0]["events"] = events
      scenarios[0]["frames"] = frames
      root["scenarios"] = scenarios
    }
    try assertInvalidFixture { root in
      var scenarios = root["scenarios"] as! [[String: Any]]
      var frames = scenarios[0]["frames"] as! [[String: Any]]
      let first = frames[0]["events"] as! [[String: Any]]
      frames[0]["events"] = Array(repeating: first[0], count: CombatReplayFixture.maximumEventsPerFrame + 1)
      scenarios[0]["frames"] = frames
      root["scenarios"] = scenarios
    }
  }

  func testNonFiniteAndBackwardsClocksDoNotAdvanceTheReplay() throws {
    var session = try makeSession(.miss)
    try session.advance(to: 200)
    let snapshot = session.snapshot
    for invalid in [Double.nan, .infinity, -1, 199, 1_000_000] {
      try session.advance(to: invalid)
      XCTAssertEqual(session.snapshot, snapshot)
      XCTAssertEqual(session.matchTimeMs, 200)
    }
  }

  private func makeSession(_ id: CombatReplayFixture.ScenarioID) throws -> CombatReplaySession {
    try CombatReplaySession(scenario: XCTUnwrap(CombatReplayFixture.bundled().scenarios.first(where: { $0.id == id })))
  }

  private func assertInvalidFixture(_ mutate: (inout [String: Any]) -> Void) throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CombatReplayFixture.bundledData()) as? [String: Any])
    mutate(&object)
    XCTAssertThrowsError(try CombatReplayFixture.decode(JSONSerialization.data(withJSONObject: object)))
  }
}

#endif
