#if DEBUG
import Foundation

/// One bounded recording, advanced by a caller-owned clock. It applies accepted
/// events through CombatReplica; health, ammo and terminals are never fabricated.
struct CombatReplaySession {
  let scenario: CombatReplayFixture.Scenario
  private(set) var replica: CombatReplica
  private(set) var presentation = RealtimeCombatPresentation()
  private(set) var nextFrame = 0
  private(set) var matchTimeMs: Double
  private(set) var acceptedSpawns = 0
  private(set) var acceptedSegments = 0
  private(set) var terminals: [CombatWire.Terminal] = []
  private(set) var duplicateEventsIgnored = 0
  private(set) var recentEvents: [String] = []
  private var lastBatch: [CombatWire.ServerEvent] = []
  private(set) var isCleared = false

  var snapshot: CombatWire.Snapshot { replica.snapshot ?? scenario.initial }
  var isComplete: Bool { nextFrame == scenario.frames.count }
  var durationMs: Double { scenario.endsAtMs - scenario.initial.matchTimeMs }
  var progress: Double { min(1, max(0, (matchTimeMs - scenario.initial.matchTimeMs) / durationMs)) }

  init(scenario: CombatReplayFixture.Scenario) throws {
    self.scenario = scenario
    replica = CombatReplica(matchID: scenario.initial.matchId, localPlayerID: scenario.localPlayerID)
    matchTimeMs = scenario.initial.matchTimeMs
    try replica.replace(scenario.initial, eventSequence: scenario.initialEventSequence, clientSequence: 0)
    presentation.update(scenario.initial, matchTimeMs: matchTimeMs, localTime: matchTimeMs / 1000)
  }

  mutating func advance(to time: Double, deliverPackets: Bool = true) throws {
    guard !isCleared, time.isFinite, time >= matchTimeMs,
      time <= scenario.endsAtMs + RealtimeCombatPresentation.staleMs + 1000
    else { return }
    matchTimeMs = time
    if deliverPackets {
      while nextFrame < scenario.frames.count, scenario.frames[nextFrame].atMs <= time {
        let frame = scenario.frames[nextFrame]
        let fresh = try replica.apply(frame.events)
        record(fresh)
        lastBatch = frame.events
        nextFrame += 1
      }
    }
    presentation.update(snapshot, matchTimeMs: matchTimeMs, localTime: matchTimeMs / 1000)
  }

  /// Re-deliver exactly the last accepted packet to the production replica.
  /// No hit flashes or counters can be created by already-seen event identities.
  @discardableResult
  mutating func replayLastPacket() throws -> Int {
    guard !isCleared else { return 0 }
    let fresh = try replica.apply(lastBatch)
    let ignored = lastBatch.count - fresh.count
    duplicateEventsIgnored += ignored
    record(fresh)
    return ignored
  }

  mutating func clear() {
    presentation.clear()
    lastBatch.removeAll()
    terminals.removeAll()
    recentEvents.removeAll()
    isCleared = true
  }

  mutating func restart() throws { self = try Self(scenario: scenario) }

  private mutating func record(_ fresh: [CombatWire.ServerEvent]) {
    for wrapped in fresh {
      let description: String?
      switch wrapped.event {
      case .projectileSpawn:
        acceptedSpawns += 1
        description = "Projectile accepted"
      case .projectileSegment(_, _, _, let scale):
        acceptedSegments += 1
        description = scale < 1 ? "Entered slow segment" : "Returned to full speed"
      case .projectileTerminal(let terminal):
        terminals.append(terminal)
        if terminals.count > RealtimeCombatPresentation.projectileCapacity { terminals.removeFirst() }
        description = Self.terminalTitle(terminal)
      default:
        description = nil
      }
      if let description {
        recentEvents.append(description)
        if recentEvents.count > 6 { recentEvents.removeFirst() }
      }
    }
  }

  static func terminalTitle(_ terminal: CombatWire.Terminal) -> String {
    switch terminal.reason {
    case "bodyHit": "Hit accepted · \(terminal.damage) damage"
    case "missExpired": "Miss · projectile expired"
    case "cancelled": "Projectile cancelled"
    case "shieldBlocked": "Shield block accepted"
    default: "Projectile ended"
    }
  }
}
#endif
