import Foundation
import XCTest

@testable import PewPewSimulation

final class SameTickPermutationTests: XCTestCase {
  func testEveryPermutationOfFiveMixedInputsIsByteIdentical() throws {
    let layout: [(SimulationPlayerID, Vector3)] = [
      (playerA, .zero),
      (playerB, Vector3(0, 0, 10)),
      (playerC, Vector3(10, 0, 0)),
      (playerD, Vector3(10, 0, 10)),
    ]
    let warmup = (1...20).map { index in
      layout.map { id, position in
        SimulationInput.poseSample(
          id,
          PoseSample(timestampMs: Int64(index) * 50, position: position)
        )
      }
    }
    let inputs: [SimulationInput] = [
      .poseSample(playerB, PoseSample(timestampMs: 1_000, position: Vector3(0, 0, 10))),
      .poseSample(playerC, PoseSample(timestampMs: 1_000, position: Vector3(10, 0, 0))),
      .fire(fireClaim(shotID: "a-b", shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1_000)),
      .fire(fireClaim(shotID: "c-d", shooter: playerC, target: playerD, origin: Vector3(10, 0, 0), firedAtMs: 1_000)),
      .fire(fireClaim(shotID: "d-a", shooter: playerD, target: playerA, origin: Vector3(10, 0, 10), direction: Vector3(-1, 0, 0), firedAtMs: 1_000)),
    ]

    let expected = try encoded(replay(playerIDs: [playerA, playerB, playerC, playerD], log: warmup + [inputs]))
    for permutation in permutations(inputs) {
      let actual = try replay(
        playerIDs: [playerA, playerB, playerC, playerD],
        log: warmup + [permutation]
      )
      XCTAssertEqual(try encoded(actual), expected)
    }
  }

  func testSimultaneousLethalCreditsOneCanonicalKiller() throws {
    let poses = [
      SimulationInput.poseSample(playerA, PoseSample(timestampMs: 50, position: .zero)),
      SimulationInput.poseSample(playerB, PoseSample(timestampMs: 50, position: Vector3(0, 0, 10))),
      SimulationInput.poseSample(playerC, PoseSample(timestampMs: 50, position: Vector3(10, 0, 0))),
    ]
    let setup: [[SimulationInput]] = [
      poses + [.fire(fireClaim(shotID: "a-1", shooter: playerA, target: playerB, origin: .zero, firedAtMs: 50))],
      [.fire(fireClaim(shotID: "a-2", shooter: playerA, target: playerB, origin: .zero, firedAtMs: 100))],
    ]
    let lethal: [SimulationInput] = [
      .fire(fireClaim(shotID: "c-lethal", shooter: playerC, target: playerB, origin: Vector3(10, 0, 0), direction: Vector3(-1, 0, 1), firedAtMs: 150)),
      .fire(fireClaim(shotID: "a-lethal", shooter: playerA, target: playerB, origin: .zero, firedAtMs: 150)),
    ]

    let expected = try replay(playerIDs: [playerA, playerB, playerC], log: setup + [lethal])
    XCTAssertEqual(
      expected.compactMap { event -> SimulationPlayerID? in
        if case .playerKilled(_, let by, _) = event { return by }
        return nil
      },
      [playerA]
    )
    XCTAssertEqual(
      verdicts(in: expected).last,
      .rejected(.targetNotAlive)
    )
    for permutation in permutations(lethal) {
      let actual = try replay(playerIDs: [playerA, playerB, playerC], log: setup + [permutation])
      XCTAssertEqual(try encoded(actual), try encoded(expected))
    }
  }

  func testTwoPoseSamplesForOnePlayerAreArrivalOrderIndependent() throws {
    let warmup: [[SimulationInput]] = [[
      .poseSample(playerA, PoseSample(timestampMs: 50, position: .zero)),
      .poseSample(playerB, PoseSample(timestampMs: 50, position: Vector3(0, 0, 10))),
    ], []]
    let firstOrder: [SimulationInput] = [
      .poseSample(playerB, PoseSample(timestampMs: 100, position: Vector3(0.6, 0, 10))),
      .poseSample(playerB, PoseSample(timestampMs: 150, position: Vector3(-0.6, 0, 10))),
      .fire(fireClaim(shotID: "bracket", shooter: playerA, target: playerB, origin: .zero, firedAtMs: 125)),
    ]
    let secondOrder = firstOrder.reversed()
    let first = try replay(playerIDs: [playerA, playerB], log: warmup + [firstOrder])
    let second = try replay(playerIDs: [playerA, playerB], log: warmup + [Array(secondOrder)])

    XCTAssertEqual(try encoded(first), try encoded(second))
    XCTAssertEqual(verdicts(in: first), [.hit(appliedDamage: 34)])
  }

  private func encoded(_ events: [SimulationEvent]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(events)
  }

  private func permutations(_ inputs: [SimulationInput]) -> [[SimulationInput]] {
    var result: [[SimulationInput]] = []
    func visit(_ prefix: [SimulationInput], _ remaining: [SimulationInput]) {
      guard !remaining.isEmpty else {
        result.append(prefix)
        return
      }
      for index in remaining.indices {
        visit(
          prefix + [remaining[index]],
          Array(remaining[..<index]) + Array(remaining[(index + 1)...])
        )
      }
    }
    visit([], inputs)
    return result
  }
}
