import XCTest

@testable import PewPewSimulation

final class CorrectionRegressionTests: XCTestCase {
  // At 450 ms, alpha = (450 - 400) / (500 - 400) = 0.5.
  // B's x coordinate is 0.6 + (-0.6 - 0.6) * 0.5 = 0.0 m, so the ray's
  // closest approach is 0.0 m ≤ the 0.35 m proxy radius and the hit applies
  // min(34, 100) = 34 damage. Snapping to B@400 would miss at x = 0.6 m.
  func testInterpolatedHitBetweenPoseSamples() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 8,
      positions: [(playerA, .zero), (playerB, Vector3(0.6, 0, 10))]
    )
    simulation.advance()

    let events = simulation.advance(inputs: [
      .poseSample(
        playerB,
        PoseSample(timestampMs: 500, position: Vector3(-0.6, 0, 10))
      ),
      .fire(
        fireClaim(
          shotID: "interpolated-hit",
          shooter: playerA,
          target: playerB,
          origin: .zero,
          firedAtMs: 450
        )
      ),
    ])

    XCTAssertEqual(verdicts(in: events), [.hit(appliedDamage: 34)])
    XCTAssertEqual(simulation.player(playerB)?.health, 66)
  }

  // At 475 ms, alpha = (475 - 400) / (500 - 400) = 0.75.
  // B's x coordinate is 0.0 + (1.2 - 0.0) * 0.75 = 0.9 m, so the closest
  // approach is 0.9 m > the 0.35 m proxy radius and the shot misses. Snapping
  // to B@400 would incorrectly hit at x = 0.0 m.
  func testInterpolatedMissBetweenPoseSamples() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 8,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )
    simulation.advance()

    let events = simulation.advance(inputs: [
      .poseSample(
        playerB,
        PoseSample(timestampMs: 500, position: Vector3(1.2, 0, 10))
      ),
      .fire(
        fireClaim(
          shotID: "interpolated-miss",
          shooter: playerA,
          target: playerB,
          origin: .zero,
          firedAtMs: 475
        )
      ),
    ])

    XCTAssertEqual(verdicts(in: events), [.miss])
    XCTAssertEqual(simulation.player(playerB)?.health, 100)
  }

  // B@300 and B@460 bracket t=400, but the 160 ms bracket gap exceeds the
  // 100 ms max pose age. The backward age is exactly 100 ms, so the gap rule
  // is the rejection that this regression isolates.
  func testInterpolatedPoseGapIsRejectedPoseTooOld() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 6,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )
    _ = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 350, position: .zero)),
    ])
    let events = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 400, position: .zero)),
      .poseSample(
        playerB,
        PoseSample(timestampMs: 460, position: Vector3(0, 0, 10))
      ),
      .fire(
        fireClaim(
          shotID: "interpolated-gap",
          shooter: playerA,
          target: playerB,
          origin: .zero,
          firedAtMs: 400
        )
      ),
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.poseTooOld)])
  }

  func testEveryPermutationOfMixedSameTickInputsHasSameOutput() throws {
    let inputs: [SimulationInput] = [
      .poseSample(playerB, PoseSample(timestampMs: 1_000, position: Vector3(0, 0, 10))),
      .poseSample(playerC, PoseSample(timestampMs: 1_000, position: Vector3(10, 0, 0))),
      .fire(
        fireClaim(
          shotID: "a-b",
          shooter: playerA,
          target: playerB,
          origin: .zero,
          firedAtMs: 1_000
        )
      ),
      .fire(
        fireClaim(
          shotID: "c-d",
          shooter: playerC,
          target: playerD,
          origin: Vector3(10, 0, 0),
          direction: Vector3(0, 0, 1),
          firedAtMs: 1_000
        )
      ),
      .fire(
        fireClaim(
          shotID: "d-a",
          shooter: playerD,
          target: playerA,
          origin: Vector3(10, 0, 10),
          direction: Vector3(-1, 0, 0),
          firedAtMs: 1_000
        )
      ),
    ]

    let layout: [(SimulationPlayerID, Vector3)] = [
      (playerA, .zero),
      (playerB, Vector3(0, 0, 10)),
      (playerC, Vector3(10, 0, 0)),
      (playerD, Vector3(10, 0, 10)),
    ]
    let warmupLog = (1...20).map { tickIndex in
      layout.map { playerID, position in
        SimulationInput.poseSample(
          playerID,
          PoseSample(timestampMs: Int64(tickIndex) * 50, position: position)
        )
      }
    }
    let expected = try replay(
      playerIDs: [playerA, playerB, playerC, playerD],
      log: warmupLog + [inputs]
    )
    for permutation in permutations(inputs) {
      let actual = try replay(
        playerIDs: [playerA, playerB, playerC, playerD],
        log: warmupLog + [permutation]
      )
      XCTAssertEqual(actual, expected)
    }
  }

}
