import Foundation
import XCTest

@testable import PewPewSimulation

final class ScenarioFixtureTests: XCTestCase {
  private struct Fixture: Decodable {
    let name: String
    let description: String
    let clock: Clock
    let players: [Player]
    let timeline: [TimelineEntry]
    let expect: [ExpectedEvent]
  }

  private struct Clock: Decodable {
    let tickMs: Int64
  }

  private struct Player: Decodable {
    let id: String
  }

  private struct TimelineEntry: Decodable {
    let atMs: Int64
    let poseSample: PoseEntry?
    let fire: FireEntry?

    func inputs() -> [SimulationInput] {
      var result: [SimulationInput] = []
      if let poseSample {
        result.append(
          .poseSample(
            SimulationPlayerID(poseSample.player),
            PoseSample(
              timestampMs: poseSample.stampedAtMs ?? atMs,
              position: Vector3(poseSample.pos[0], poseSample.pos[1], poseSample.pos[2]),
              tracking: TrackingState(rawValue: poseSample.tracking ?? "normal")!
            )
          )
        )
      }
      if let fire {
        result.append(
          .fire(
            ShotClaim(
              shotID: fire.shotId,
              shooterID: SimulationPlayerID(fire.shooter),
              targetID: SimulationPlayerID(fire.target),
              origin: Vector3(fire.origin[0], fire.origin[1], fire.origin[2]),
              direction: Vector3(fire.dir[0], fire.dir[1], fire.dir[2]),
              firedAtMs: fire.claimedAtMs
            )
          )
        )
      }
      return result
    }
  }

  private struct PoseEntry: Decodable {
    let player: String
    let pos: [Double]
    let stampedAtMs: Int64?
    let tracking: String?
  }

  private struct FireEntry: Decodable {
    let shooter: String
    let target: String
    let origin: [Double]
    let dir: [Double]
    let claimedAtMs: Int64
    let shotId: String
  }

  private struct ExpectedEvent: Decodable {
    let verdict: ExpectedVerdict?
    let killed: ExpectedKilled?
  }

  private struct ExpectedVerdict: Decodable {
    let shotId: String
    let outcome: String
    let appliedDamage: Int?
    let reason: String?
    let rewindMs: Int64
  }

  private struct ExpectedKilled: Decodable {
    let target: String
    let by: String
    let atMs: Int64
  }

  private enum NormalizedEvent: Equatable {
    case verdict(shotID: String, outcome: String, appliedDamage: Int?, reason: String?, rewindMs: Int64)
    case killed(target: String, by: String, atMs: Int64)
  }

  func testEveryCommittedScenarioFixture() throws {
    let directory = scenariosDirectory()
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertGreaterThanOrEqual(files.count, 9)

    for file in files {
      let fixture: Fixture
      do {
        fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
      } catch {
        XCTFail("failed to decode \(file.lastPathComponent): \(error)")
        continue
      }
      try assertFixture(fixture, file: file)
    }
  }

  private func assertFixture(_ fixture: Fixture, file: URL) throws {
    XCTAssertFalse(fixture.description.isEmpty, file.lastPathComponent)
    XCTAssertGreaterThan(fixture.clock.tickMs, 0, file.lastPathComponent)
    XCTAssertFalse(fixture.players.isEmpty, file.lastPathComponent)

    for entry in fixture.timeline {
      XCTAssertGreaterThan(entry.atMs, 0, file.lastPathComponent)
      XCTAssertEqual(entry.atMs % fixture.clock.tickMs, 0, file.lastPathComponent)
      XCTAssertEqual(entry.inputs().count, 1, file.lastPathComponent)
    }

    let actual = try run(fixture)
    let expected = fixture.expect.map(normalized)
    XCTAssertEqual(actual.map(normalized), expected, file.lastPathComponent)

    let replayed = try run(fixture)
    XCTAssertEqual(try encoded(actual), try encoded(replayed), file.lastPathComponent)

    let grouped = Dictionary(grouping: fixture.timeline, by: \.atMs)
    for atMs in grouped.keys.sorted() {
      guard let entries = grouped[atMs], entries.count > 1 else { continue }
      var replacement = fixture.timeline
      for (index, entry) in fixture.timeline.enumerated() where entry.atMs == atMs {
        replacement[index] = entries.reversed().first { candidate in
          candidate.inputs() == entry.inputs()
        } ?? entry
      }
      let permuted = Fixture(
        name: fixture.name,
        description: fixture.description,
        clock: fixture.clock,
        players: fixture.players,
        timeline: replacement,
        expect: fixture.expect
      )
      let permutedEvents = try run(permuted)
      XCTAssertEqual(try encoded(actual), try encoded(permutedEvents), file.lastPathComponent)
    }
  }

  private func run(_ fixture: Fixture) throws -> [SimulationEvent] {
    let playerIDs = fixture.players.map { SimulationPlayerID($0.id) }
    var simulation = try MatchSimulation(playerIDs: playerIDs)
    let maxAtMs = fixture.timeline.map(\.atMs).max() ?? 0
    var events: [SimulationEvent] = []

    for tick in 1...(maxAtMs / fixture.clock.tickMs) {
      let atMs = tick * fixture.clock.tickMs
      let inputs = fixture.timeline
        .filter { $0.atMs == atMs }
        .flatMap { $0.inputs() }
      events.append(contentsOf: simulation.advance(inputs: inputs))
    }
    return events
  }

  private func normalized(_ expected: ExpectedEvent) -> NormalizedEvent {
    if let verdict = expected.verdict {
      return .verdict(
        shotID: verdict.shotId,
        outcome: verdict.outcome,
        appliedDamage: verdict.appliedDamage,
        reason: verdict.reason,
        rewindMs: verdict.rewindMs
      )
    }
    let killed = expected.killed!
    return .killed(target: killed.target, by: killed.by, atMs: killed.atMs)
  }

  private func normalized(_ event: SimulationEvent) -> NormalizedEvent {
    switch event {
    case .verdict(let record):
      switch record.verdict {
      case .hit(let appliedDamage):
        return .verdict(
          shotID: record.shot.shotID,
          outcome: "hit",
          appliedDamage: appliedDamage,
          reason: nil,
          rewindMs: record.rewindMilliseconds
        )
      case .miss:
        return .verdict(
          shotID: record.shot.shotID,
          outcome: "miss",
          appliedDamage: nil,
          reason: nil,
          rewindMs: record.rewindMilliseconds
        )
      case .rejected(let reason):
        return .verdict(
          shotID: record.shot.shotID,
          outcome: "rejected",
          appliedDamage: nil,
          reason: reason.rawValue,
          rewindMs: record.rewindMilliseconds
        )
      }
    case .playerKilled(let target, let by, let atTick):
      return .killed(target: target.rawValue, by: by.rawValue, atMs: atTick * 50)
    }
  }

  private func encoded(_ events: [SimulationEvent]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(events)
  }

  private func scenariosDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("scenarios")
  }
}
