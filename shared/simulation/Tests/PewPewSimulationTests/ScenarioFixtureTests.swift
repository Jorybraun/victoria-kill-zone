import Foundation
import XCTest

@testable import PewPewSimulation

final class ScenarioFixtureTests: XCTestCase {
  private enum FixtureValidationError: Error, CustomStringConvertible {
    case invalidTracking(fileName: String, value: String)
    case invalidExpectedEvent(fileName: String)
    case invalidVector(fileName: String, field: String)

    var description: String {
      switch self {
      case .invalidTracking(let fileName, let value):
        return "\(fileName): unknown tracking value \(value)"
      case .invalidExpectedEvent(let fileName):
        return "\(fileName): expected event must contain either verdict or killed"
      case .invalidVector(let fileName, let field):
        return "\(fileName): \(field) must contain exactly three values"
      }
    }
  }

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

  private struct TimelineEntry: Decodable, Equatable {
    let atMs: Int64
    let poseSample: PoseEntry?
    let fire: FireEntry?

    func inputs(fileName: String) throws -> [SimulationInput] {
      var result: [SimulationInput] = []
      if let poseSample {
        guard poseSample.pos.count == 3 else {
          throw FixtureValidationError.invalidVector(fileName: fileName, field: "poseSample.pos")
        }
        let trackingValue = poseSample.tracking ?? "normal"
        guard let tracking = TrackingState(rawValue: trackingValue) else {
          throw FixtureValidationError.invalidTracking(fileName: fileName, value: trackingValue)
        }
        result.append(
          .poseSample(
            SimulationPlayerID(poseSample.player),
            PoseSample(
              timestampMs: poseSample.stampedAtMs ?? atMs,
              position: Vector3(poseSample.pos[0], poseSample.pos[1], poseSample.pos[2]),
              tracking: tracking
            )
          )
        )
      }
      if let fire {
        guard fire.origin.count == 3 else {
          throw FixtureValidationError.invalidVector(fileName: fileName, field: "fire.origin")
        }
        guard fire.dir.count == 3 else {
          throw FixtureValidationError.invalidVector(fileName: fileName, field: "fire.dir")
        }
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

  private struct PoseEntry: Decodable, Equatable {
    let player: String
    let pos: [Double]
    let stampedAtMs: Int64?
    let tracking: String?
  }

  private struct FireEntry: Decodable, Equatable {
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
    XCTAssertGreaterThanOrEqual(files.count, 10)

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
    XCTAssertFalse(fixture.timeline.isEmpty, file.lastPathComponent)
    guard fixture.clock.tickMs > 0 else {
      XCTFail("\(file.lastPathComponent): tickMs must be positive")
      return
    }

    for entry in fixture.timeline {
      XCTAssertGreaterThan(entry.atMs, 0, file.lastPathComponent)
      XCTAssertEqual(entry.atMs % fixture.clock.tickMs, 0, file.lastPathComponent)
      do {
        let inputCount = try entry.inputs(fileName: file.lastPathComponent).count
        XCTAssertEqual(inputCount, 1, file.lastPathComponent)
      } catch {
        XCTFail("\(error)")
        return
      }
    }

    let actual = try run(fixture, fileName: file.lastPathComponent)
    let expected: [NormalizedEvent]
    do {
      expected = try fixture.expect.map {
        try normalized($0, fileName: file.lastPathComponent)
      }
    } catch {
      XCTFail("\(error)")
      return
    }
    XCTAssertEqual(
      actual.map { normalized($0, tickMs: fixture.clock.tickMs) },
      expected,
      file.lastPathComponent
    )

    let replayed = try run(fixture, fileName: file.lastPathComponent)
    XCTAssertEqual(try encoded(actual), try encoded(replayed), file.lastPathComponent)

    let grouped = Dictionary(grouping: fixture.timeline, by: \.atMs)
    let multiEntryTicks = grouped.keys.sorted().compactMap { atMs in
      grouped[atMs].flatMap { $0.count > 1 ? $0 : nil }
    }
    let permutedTimelines = permutedTimelines(
      fixture.timeline,
      groupedEntries: multiEntryTicks
    )
    if !multiEntryTicks.isEmpty {
      XCTAssertTrue(
        permutedTimelines.contains { $0 != fixture.timeline },
        "\(file.lastPathComponent): generated permutations did not change timeline ordering"
      )
    }
    for replacement in permutedTimelines where replacement != fixture.timeline {
      let permuted = Fixture(
        name: fixture.name,
        description: fixture.description,
        clock: fixture.clock,
        players: fixture.players,
        timeline: replacement,
        expect: fixture.expect
      )
      let permutedEvents = try run(permuted, fileName: file.lastPathComponent)
      XCTAssertEqual(try encoded(actual), try encoded(permutedEvents), file.lastPathComponent)
    }
  }

  private func run(_ fixture: Fixture, fileName: String) throws -> [SimulationEvent] {
    let playerIDs = fixture.players.map { SimulationPlayerID($0.id) }
    let maxAtMs = fixture.timeline.map(\.atMs).max() ?? 0
    guard maxAtMs > 0 else { return [] }
    var simulation = try MatchSimulation(
      configuration: SimulationConfiguration(tickDurationMs: fixture.clock.tickMs),
      playerIDs: playerIDs
    )
    var events: [SimulationEvent] = []

    for tick in 1...(maxAtMs / fixture.clock.tickMs) {
      let atMs = tick * fixture.clock.tickMs
      let inputs = fixture.timeline
        .filter { $0.atMs == atMs }
        .flatMap { entry in
          do {
            return try entry.inputs(fileName: fileName)
          } catch {
            XCTFail("\(error)")
            return []
          }
        }
      events.append(contentsOf: simulation.advance(inputs: inputs))
    }
    return events
  }

  private func normalized(
    _ expected: ExpectedEvent,
    fileName: String
  ) throws -> NormalizedEvent {
    if let verdict = expected.verdict {
      return .verdict(
        shotID: verdict.shotId,
        outcome: verdict.outcome,
        appliedDamage: verdict.appliedDamage,
        reason: verdict.reason,
        rewindMs: verdict.rewindMs
      )
    }
    guard let killed = expected.killed else {
      throw FixtureValidationError.invalidExpectedEvent(fileName: fileName)
    }
    return .killed(target: killed.target, by: killed.by, atMs: killed.atMs)
  }

  private func normalized(
    _ event: SimulationEvent,
    tickMs: Int64
  ) -> NormalizedEvent {
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
      return .killed(target: target.rawValue, by: by.rawValue, atMs: atTick * tickMs)
    }
  }

  private func permutedTimelines(
    _ timeline: [TimelineEntry],
    groupedEntries: [[TimelineEntry]]
  ) -> [[TimelineEntry]] {
    var result: [[TimelineEntry]] = []
    for entries in groupedEntries {
      let arrangements: [[TimelineEntry]]
      if entries.count <= 4 {
        arrangements = permutations(entries)
      } else {
        arrangements = [
          Array(entries.reversed()),
          Array(entries.dropFirst()) + [entries[0]],
        ]
      }
      let indexes = timeline.indices.filter { timeline[$0].atMs == entries[0].atMs }
      for arrangement in arrangements {
        var replacement = timeline
        for (index, entry) in indexes.enumerated() {
          replacement[entry] = arrangement[index]
        }
        result.append(replacement)
      }
    }
    return result
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
