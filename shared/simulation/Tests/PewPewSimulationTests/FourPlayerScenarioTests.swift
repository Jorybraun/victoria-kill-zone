import XCTest

@testable import PewPewSimulation

/// Player-set scenarios at the Phase 1 cap of 4. Arena layout used throughout:
///   A (0,0,0)   B (10,0,0)   C (0,0,10)   D (10,0,10)
/// so A→C and B→D are both 10 m shots along +z. Repeated shots by one shooter are
/// spaced 8 ticks (400 ms) apart to clear the 350 ms Sidearm cooldown.
final class FourPlayerScenarioTests: XCTestCase {
  private let layout: [(SimulationPlayerID, Vector3)] = [
    (playerA, .zero),
    (playerB, Vector3(10, 0, 0)),
    (playerC, Vector3(0, 0, 10)),
    (playerD, Vector3(10, 0, 10)),
  ]

  private func warmedUpMatch(ticks: Int = 20) throws -> MatchSimulation {
    var simulation = try makeFourPlayerMatch()
    advanceFeedingPoses(&simulation, ticks: ticks, positions: layout)
    return simulation
  }

  func testTwoShootersHitDistinctTargetsInTheSameTick() throws {
    var simulation = try warmedUpMatch()
    let firedAtMs = simulation.clockMs

    let events = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "shot-a-c", shooter: playerA, target: playerC,
          origin: .zero, firedAtMs: firedAtMs)),
      .fire(
        fireClaim(
          shotID: "shot-b-d", shooter: playerB, target: playerD,
          origin: Vector3(10, 0, 0), firedAtMs: firedAtMs)),
    ])

    XCTAssertEqual(
      verdicts(in: events),
      [.hit(zone: .torso, appliedDamage: 34), .hit(zone: .torso, appliedDamage: 34)]
    )
    XCTAssertEqual(simulation.player(playerC)?.health, 66)
    XCTAssertEqual(simulation.player(playerD)?.health, 66)
    XCTAssertEqual(simulation.player(playerA)?.shotsHit, 1)
    XCTAssertEqual(simulation.player(playerB)?.shotsHit, 1)
  }

  func testFireAtDeadTargetIsRejectedTargetNotAlive() throws {
    var simulation = try warmedUpMatch()

    for shot in 1...3 {
      let firedAtMs = simulation.clockMs
      simulation.advance(inputs: [
        .fire(
          fireClaim(
            shotID: "kill-\(shot)", shooter: playerA, target: playerC,
            origin: .zero, firedAtMs: firedAtMs))
      ])
      advanceFeedingPoses(&simulation, ticks: 7, positions: layout)
    }
    XCTAssertEqual(simulation.player(playerC)?.lifeState, .dead)

    let events = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "shot-at-corpse", shooter: playerB, target: playerC,
          origin: Vector3(10, 0, 0), direction: Vector3(-10, 0, 10),
          firedAtMs: simulation.clockMs))
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.targetNotAlive)])
    XCTAssertEqual(simulation.player(playerC)?.deaths, 1)
    // Always-fire: the trigger cleared the shooter-side checks, so the round is spent.
    XCTAssertEqual(simulation.player(playerB)?.shotsFired, 1)
    XCTAssertEqual(simulation.player(playerB)?.ammo, SidearmRules.magazineSize - 1)
  }

  func testFireAtStalePoseTargetIsRejectedPoseTooOld() throws {
    var simulation = try makeFourPlayerMatch()
    advanceFeedingPoses(&simulation, ticks: 10, positions: layout)
    let trackedLayout = layout.filter { id, _ in id != playerD }
    advanceFeedingPoses(&simulation, ticks: 10, positions: trackedLayout)

    let firedAtMs = simulation.clockMs
    let events = simulation.advance(inputs: [
      .fire(
        fireClaim(
          shotID: "shot-stale", shooter: playerB, target: playerD,
          origin: Vector3(10, 0, 0), firedAtMs: firedAtMs))
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.poseTooOld)])
  }

  func testFullKillAccountingSequence() throws {
    var simulation = try warmedUpMatch()
    var allEvents: [SimulationEvent] = []

    for shot in 1...3 {
      let firedAtMs = simulation.clockMs
      allEvents.append(
        contentsOf: simulation.advance(inputs: [
          .fire(
            fireClaim(
              shotID: "kill-\(shot)", shooter: playerA, target: playerC,
              origin: .zero, firedAtMs: firedAtMs))
        ]))
      advanceFeedingPoses(&simulation, ticks: 7, positions: layout)
    }

    XCTAssertEqual(
      verdicts(in: allEvents),
      [.hit(zone: .torso, appliedDamage: 34), .hit(zone: .torso, appliedDamage: 34), .hit(zone: .torso, appliedDamage: 32)]
    )
    XCTAssertEqual(
      allEvents.last,
      .playerKilled(target: playerC, by: playerA, atTick: 37)
    )

    let shooter = try XCTUnwrap(simulation.player(playerA))
    XCTAssertEqual(shooter.shotsFired, 3)
    XCTAssertEqual(shooter.shotsHit, 3)
    XCTAssertEqual(shooter.damageDealt, 100)
    XCTAssertEqual(shooter.kills, 1)
    XCTAssertEqual(shooter.deaths, 0)

    let target = try XCTUnwrap(simulation.player(playerC))
    XCTAssertEqual(target.health, 0)
    XCTAssertEqual(target.lifeState, .dead)
    XCTAssertEqual(target.deaths, 1)

    XCTAssertEqual(simulation.player(playerB)?.health, 100)
    XCTAssertEqual(simulation.player(playerD)?.health, 100)
  }
}
