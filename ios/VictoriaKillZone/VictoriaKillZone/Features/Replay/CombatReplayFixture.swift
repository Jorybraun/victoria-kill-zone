#if DEBUG
import Foundation

/// Recorded output from the real engine's explicitly synthetic test driver.
/// This format is local diagnostics only; it is never a combat input protocol.
struct CombatReplayFixture: Decodable, Sendable {
  static let maximumBytes = 1_048_576
  static let maximumFrames = 600
  static let maximumEventsPerFrame = 64
  static let maximumDurationMs: Double = 30_000

  enum ScenarioID: String, CaseIterable, Decodable, Identifiable, Sendable {
    case hit, miss, slow, cancel
    var id: String { rawValue }
    var title: String {
      switch self {
      case .hit: "Hit"
      case .miss: "Miss"
      case .slow: "Slow field"
      case .cancel: "Cancel"
      }
    }
  }

  struct Frame: Decodable, Sendable {
    let atMs: Double
    let events: [CombatWire.ServerEvent]
  }
  struct Scenario: Decodable, Sendable, Identifiable {
    let id: ScenarioID
    let initial: CombatWire.Snapshot
    let initialEventSequence: Int
    let frames: [Frame]
    var localPlayerID: String { initial.players.first(where: { $0.role == "host" })?.playerId ?? "" }
    var endsAtMs: Double { frames.last?.atMs ?? initial.matchTimeMs }
  }
  enum Failure: Error, Equatable {
    case missingResource, sizeLimit, unsupportedVersion, invalidTimeline
  }

  let version: Int
  let source: String
  let scenarios: [Scenario]

  static func bundled() throws -> Self {
    try decode(bundledData())
  }

  static func bundledData() throws -> Data {
    #if SWIFT_PACKAGE
      let bundle = Bundle.module
    #else
      let bundle = Bundle.main
    #endif
    guard let url = bundle.url(forResource: "combat-replay-v1", withExtension: "json", subdirectory: "Fixtures")
      ?? bundle.url(forResource: "combat-replay-v1", withExtension: "json")
    else { throw Failure.missingResource }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= maximumBytes else { throw Failure.sizeLimit }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.sizeLimit }
    return data
  }

  static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.sizeLimit }
    let fixture = try JSONDecoder().decode(Self.self, from: data)
    guard fixture.version == 1 else { throw Failure.unsupportedVersion }
    guard fixture.source.utf8.count <= 512,
      fixture.scenarios.count == ScenarioID.allCases.count,
      Set(fixture.scenarios.map(\.id)).count == fixture.scenarios.count
    else { throw Failure.invalidTimeline }
    for scenario in fixture.scenarios { try validate(scenario) }
    return fixture
  }

  private static func validate(_ scenario: Scenario) throws {
    guard !scenario.frames.isEmpty, scenario.frames.count <= maximumFrames,
      scenario.initial.phase == .running, scenario.initial.players.count >= 2,
      scenario.initial.players.count <= 4, scenario.initial.projectiles.isEmpty,
      scenario.initialEventSequence == 0
    else { throw Failure.invalidTimeline }
    var replica = CombatReplica(matchID: scenario.initial.matchId, localPlayerID: scenario.localPlayerID)
    try replica.replace(scenario.initial, eventSequence: scenario.initialEventSequence, clientSequence: 0)
    var previousTime = scenario.initial.matchTimeMs
    for frame in scenario.frames {
      guard frame.atMs.isFinite, frame.atMs > previousTime,
        frame.atMs - scenario.initial.matchTimeMs <= maximumDurationMs,
        !frame.events.isEmpty, frame.events.count <= maximumEventsPerFrame,
        frame.events.allSatisfy({ $0.matchTimeMs <= frame.atMs })
      else { throw Failure.invalidTimeline }
      let fresh = try replica.apply(frame.events)
      // The canonical recording contains each event once. Duplicates are injected
      // deliberately by the replay controls after loading, never hidden in data.
      guard fresh.count == frame.events.count else { throw Failure.invalidTimeline }
      previousTime = frame.atMs
    }
  }
}
#endif
