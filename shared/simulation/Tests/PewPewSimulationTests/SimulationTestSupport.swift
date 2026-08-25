import Foundation

@testable import PewPewSimulation

let playerA = SimulationPlayerID("player-a")
let playerB = SimulationPlayerID("player-b")
let playerC = SimulationPlayerID("player-c")
let playerD = SimulationPlayerID("player-d")

func makeDuel() throws -> MatchSimulation {
  try MatchSimulation(playerIDs: [playerA, playerB])
}

func makeFourPlayerMatch() throws -> MatchSimulation {
  try MatchSimulation(playerIDs: [playerA, playerB, playerC, playerD])
}

/// Advances the simulation `ticks` times, feeding each listed player one pose
/// sample stamped at the post-advance clock so its latest pose is never stale.
func advanceFeedingPoses(
  _ simulation: inout MatchSimulation,
  ticks: Int,
  positions: [(SimulationPlayerID, Vector3)],
  tracking: TrackingState = .normal
) {
  for _ in 0..<ticks {
    let nextClockMs = (simulation.tick + 1) * simulation.configuration.tickDurationMs
    let inputs = positions.map { playerID, position in
      SimulationInput.poseSample(
        playerID,
        PoseSample(timestampMs: nextClockMs, position: position, tracking: tracking)
      )
    }
    simulation.advance(inputs: inputs)
  }
}

func fireClaim(
  shotID: String = "shot-1",
  shooter: SimulationPlayerID,
  target: SimulationPlayerID,
  origin: Vector3,
  direction: Vector3 = Vector3(0, 0, 1),
  firedAtMs: Int64
) -> ShotClaim {
  ShotClaim(
    shotID: shotID,
    shooterID: shooter,
    targetID: target,
    origin: origin,
    direction: direction,
    firedAtMs: firedAtMs
  )
}

/// Replays one recorded input log from a fresh simulation and returns every
/// emitted event in order.
func replay(
  playerIDs: [SimulationPlayerID],
  log: [[SimulationInput]]
) throws -> [SimulationEvent] {
  var simulation = try MatchSimulation(playerIDs: playerIDs)
  var events: [SimulationEvent] = []
  for tickInputs in log {
    events.append(contentsOf: simulation.advance(inputs: tickInputs))
  }
  return events
}

func verdicts(in events: [SimulationEvent]) -> [SpatialVerdict] {
  events.compactMap { event in
    if case .verdict(let record) = event {
      return record.verdict
    }
    return nil
  }
}
