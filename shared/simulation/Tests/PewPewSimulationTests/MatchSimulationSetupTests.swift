import XCTest

@testable import PewPewSimulation

final class MatchSimulationSetupTests: XCTestCase {
  func testAcceptsPlayerSetsWithinCapacity() throws {
    XCTAssertEqual(try makeDuel().playerOrder, [playerA, playerB])
    XCTAssertEqual(
      try MatchSimulation(playerIDs: [playerA, playerB, playerC]).playerOrder,
      [playerA, playerB, playerC]
    )
    XCTAssertEqual(
      try makeFourPlayerMatch().playerOrder,
      [playerA, playerB, playerC, playerD]
    )
  }

  func testRejectsPlayerSetsOutsideCapacity() {
    XCTAssertThrowsError(try MatchSimulation(playerIDs: [playerA])) { error in
      XCTAssertEqual(error as? SimulationSetupError, .invalidPlayerCount(1))
    }
    XCTAssertThrowsError(
      try MatchSimulation(playerIDs: [
        playerA, playerB, playerC, playerD, SimulationPlayerID("player-e"),
      ])
    ) { error in
      XCTAssertEqual(error as? SimulationSetupError, .invalidPlayerCount(5))
    }
  }

  func testRejectsDuplicatePlayerIDs() {
    XCTAssertThrowsError(try MatchSimulation(playerIDs: [playerA, playerA])) { error in
      XCTAssertEqual(error as? SimulationSetupError, .duplicatePlayerID(playerA))
    }
  }

  func testClockAdvancesOnlyByTicks() throws {
    var simulation = try makeDuel()
    XCTAssertEqual(simulation.tick, 0)
    XCTAssertEqual(simulation.clockMs, 0)

    simulation.advance()
    simulation.advance()

    XCTAssertEqual(simulation.tick, 2)
    XCTAssertEqual(simulation.clockMs, 100)
  }

  func testEveryPlayerStartsAliveAtFullHealth() throws {
    let simulation = try makeFourPlayerMatch()
    for id in simulation.playerOrder {
      let player = try XCTUnwrap(simulation.player(id))
      XCTAssertEqual(player.health, 100)
      XCTAssertEqual(player.lifeState, .alive)
      XCTAssertEqual(player.kills, 0)
      XCTAssertEqual(player.deaths, 0)
    }
  }

  func testFireOutsidePlayerSetIsRejectedInvalidTarget() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )

    let selfShot = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "self", shooter: playerA, target: playerA,
          origin: .zero, firedAtMs: simulation.clockMs))
    ])
    let unknownTarget = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "unknown", shooter: playerA, target: playerC,
          origin: .zero, firedAtMs: simulation.clockMs))
    ])

    XCTAssertEqual(verdicts(in: selfShot), [.rejected(.invalidTarget)])
    XCTAssertEqual(verdicts(in: unknownTarget), [.rejected(.invalidTarget)])
  }

  func testDeadShooterCannotFire() throws {
    var simulation = try makeDuel()
    let positions: [(SimulationPlayerID, Vector3)] = [
      (playerA, .zero), (playerB, Vector3(0, 0, 10)),
    ]
    advanceFeedingPoses(&simulation, ticks: 20, positions: positions)

    for shot in 1...3 {
      simulation.advance(inputs: [
        .fire(
          fireClaim(
            shotID: "kill-\(shot)", shooter: playerA, target: playerB,
            origin: .zero, firedAtMs: simulation.clockMs))
      ])
      advanceFeedingPoses(&simulation, ticks: 1, positions: positions)
    }
    XCTAssertEqual(simulation.player(playerB)?.lifeState, .dead)

    let events = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "from-the-grave", shooter: playerB, target: playerA,
          origin: Vector3(0, 0, 10), direction: Vector3(0, 0, -1),
          firedAtMs: simulation.clockMs))
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.shooterNotAlive)])
  }
}
