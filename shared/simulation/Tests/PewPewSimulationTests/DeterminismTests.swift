import XCTest

@testable import PewPewSimulation

/// Replays each recorded input log twice through fresh simulations and asserts
/// the emitted event sequences (verdicts, rewinds, kills, ticks) are identical.
final class DeterminismTests: XCTestCase {

  private func assertDeterministicReplay(
    playerIDs: [SimulationPlayerID],
    log: [[SimulationInput]],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let firstRun = try replay(playerIDs: playerIDs, log: log)
    let secondRun = try replay(playerIDs: playerIDs, log: log)
    XCTAssertFalse(firstRun.isEmpty, "scenario produced no events", file: file, line: line)
    XCTAssertEqual(firstRun, secondRun, file: file, line: line)
  }

  private func poseInputs(
    at timestampMs: Int64,
    _ entries: [(SimulationPlayerID, Vector3)],
    tracking: TrackingState = .normal
  ) -> [SimulationInput] {
    entries.map { playerID, position in
      .poseSample(
        playerID,
        PoseSample(timestampMs: timestampMs, position: position, tracking: tracking))
    }
  }

  func testTwoPlayerExchangeReplaysIdentically() throws {
    var log: [[SimulationInput]] = []
    for tickIndex in 1...20 {
      let t = Int64(tickIndex) * 50
      var inputs = poseInputs(
        at: t,
        [(playerA, .zero), (playerB, Vector3(0, 0, Double(4 + tickIndex % 5)))]
      )
      if tickIndex == 10 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "a-1", shooter: playerA, target: playerB,
              origin: .zero, firedAtMs: 450)))
      }
      if tickIndex == 12 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "b-1", shooter: playerB, target: playerA,
              origin: Vector3(0, 0, 6), direction: Vector3(0, 0, -1), firedAtMs: 580)))
      }
      if tickIndex == 18 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "a-2", shooter: playerA, target: playerB,
              origin: .zero, direction: Vector3(0, 1, 0), firedAtMs: 880)))
      }
      log.append(inputs)
    }

    try assertDeterministicReplay(playerIDs: [playerA, playerB], log: log)
  }

  func testFourPlayerCrossfireReplaysIdentically() throws {
    let layout: [(SimulationPlayerID, Vector3)] = [
      (playerA, .zero),
      (playerB, Vector3(10, 0, 0)),
      (playerC, Vector3(0, 0, 10)),
      (playerD, Vector3(10, 0, 10)),
    ]
    var log: [[SimulationInput]] = []
    for tickIndex in 1...40 {
      let t = Int64(tickIndex) * 50
      var inputs = poseInputs(at: t, layout)
      if tickIndex % 8 == 0 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "a-c-\(tickIndex)", shooter: playerA, target: playerC,
              origin: .zero, firedAtMs: t - 50)))
        inputs.append(
          .fire(
            fireClaim(
              shotID: "b-d-\(tickIndex)", shooter: playerB, target: playerD,
              origin: Vector3(10, 0, 0), firedAtMs: t - 50)))
      }
      log.append(inputs)
    }

    try assertDeterministicReplay(playerIDs: [playerA, playerB, playerC, playerD], log: log)
  }

  /// C tracks normally through tick 4, degrades to lost tracking during ticks
  /// 5–9, then stops producing poses entirely. Shots land while C is degraded
  /// (→ trackingLost), while C is silent (→ trackingLost from the lost latest
  /// sample), and 400 ms late (→ shotTooLate).
  private func degradedScenarioLog() -> [[SimulationInput]] {
    var log: [[SimulationInput]] = []
    for tickIndex in 1...30 {
      let t = Int64(tickIndex) * 50
      var inputs = poseInputs(at: t, [(playerA, .zero), (playerB, Vector3(10, 0, 0))])
      switch tickIndex {
      case 5..<10:
        inputs.append(
          contentsOf: poseInputs(at: t, [(playerC, Vector3(0, 0, 8))], tracking: .lost))
      case 10...:
        break
      default:
        inputs.append(contentsOf: poseInputs(at: t, [(playerC, Vector3(0, 0, 8))]))
      }
      if tickIndex == 8 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "while-degraded", shooter: playerA, target: playerC,
              origin: .zero, firedAtMs: t)))
      }
      if tickIndex == 20 {
        inputs.append(
          .fire(
            fireClaim(
              shotID: "while-silent", shooter: playerA, target: playerC,
              origin: .zero, firedAtMs: t)))
        inputs.append(
          .fire(
            fireClaim(
              shotID: "too-late", shooter: playerB, target: playerA,
              origin: Vector3(10, 0, 0), direction: Vector3(-1, 0, 0), firedAtMs: t - 400)))
      }
      log.append(inputs)
    }
    return log
  }

  func testDegradedConditionsReplayIdentically() throws {
    try assertDeterministicReplay(
      playerIDs: [playerA, playerB, playerC],
      log: degradedScenarioLog()
    )
  }

  func testDegradedConditionsProduceExpectedVerdictSequence() throws {
    let events = try replay(playerIDs: [playerA, playerB, playerC], log: degradedScenarioLog())

    // Same-tick claims resolve by firedAtMs ascending, so the 400 ms-late claim precedes the claim stamped at the current clock.
    XCTAssertEqual(
      verdicts(in: events),
      [
        .rejected(.trackingLost),
        .rejected(.shotTooLate),
        .rejected(.trackingLost),
      ]
    )
  }
}
