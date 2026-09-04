import Foundation
import PewPewSimulation

public struct AuthorityHostConfiguration: Equatable, Sendable {
  public var simulation: SimulationConfiguration
  public var snapshotIntervalTicks: Int
  public var memberTimeoutMs: Int64

  public init(
    simulation: SimulationConfiguration = .init(),
    snapshotIntervalTicks: Int = 10,
    memberTimeoutMs: Int64 = 1_000
  ) {
    self.simulation = simulation
    self.snapshotIntervalTicks = snapshotIntervalTicks
    self.memberTimeoutMs = memberTimeoutMs
  }
}

public enum InputRejection: Equatable, Sendable {
  case slotMismatch
  case unknownSlot
  case memberFireLocked
  case staleSequence
  case hostDoesNotAcceptVerdicts
}

public enum AuthorityHostEffect: Equatable, Sendable {
  case broadcast(AuthorityMessage)
  case rejectedInput(slot: UInt8, reason: InputRejection)
  case memberFireLocked(slot: UInt8)
  case memberFireUnlocked(slot: UInt8)
}

public struct AuthorityHost: Equatable, Sendable {
  public let roster: AuthorityRoster
  public let configuration: AuthorityHostConfiguration
  public let startedAtMs: Int64
  public private(set) var simulation: MatchSimulation
  public private(set) var verdictSequence: UInt32 = 0
  public private(set) var verdictLog: [VerdictFrame] = []
  public var fireLockedSlots: Set<UInt8> = []

  private var pendingInputs: [SimulationInput] = []
  private var lastSequences: [UInt8: [InputKind: UInt32]] = [:]
  private var lastHeardAtMs: [UInt8: Int64] = [:]

  private enum InputKind: Hashable, Sendable {
    case pose
    case fire
    case reload
  }

  public init(
    roster: AuthorityRoster,
    configuration: AuthorityHostConfiguration = .init(),
    startedAtMs: Int64
  ) throws {
    self.roster = roster
    self.configuration = configuration
    self.startedAtMs = startedAtMs
    self.simulation = try MatchSimulation(
      configuration: configuration.simulation,
      playerIDs: roster.orderedPlayerIDs
    )
    for slot in roster.members.keys {
      lastSequences[slot] = [:]
      lastHeardAtMs[slot] = startedAtMs
    }
  }

  public mutating func ingest(
    _ message: AuthorityMessage,
    from senderSlot: UInt8,
    atMs: Int64
  ) -> [AuthorityHostEffect] {
    guard roster.playerID(for: senderSlot) != nil else {
      return [.rejectedInput(slot: senderSlot, reason: .unknownSlot)]
    }

    if fireLockedSlots.contains(senderSlot) {
      if case .fire = message {
        return [
          .rejectedInput(slot: senderSlot, reason: .memberFireLocked)
        ]
      }
      let recovered = memberRecovered(senderSlot, atMs: atMs)
      lastHeardAtMs[senderSlot] = atMs
      return recovered + ingestUnlocked(message, from: senderSlot, atMs: atMs)
    }
    lastHeardAtMs[senderSlot] = atMs
    return ingestUnlocked(message, from: senderSlot, atMs: atMs)
  }

  public mutating func advance(nowMs: Int64) -> [AuthorityHostEffect] {
    var effects: [AuthorityHostEffect] = []
    for slot in roster.members.keys.sorted()
      where slot != 0 && !fireLockedSlots.contains(slot)
    {
      guard let lastHeard = lastHeardAtMs[slot],
            nowMs - lastHeard > configuration.memberTimeoutMs
      else { continue }
      effects += memberDropped(slot, atMs: nowMs)
    }

    let duration = configuration.simulation.tickDurationMs
    while startedAtMs + (simulation.tick + 1) * duration <= nowMs {
      let events = simulation.advance(inputs: pendingInputs)
      pendingInputs.removeAll(keepingCapacity: true)
      for event in events {
        verdictSequence &+= 1
        let frame = VerdictFrame(
          sequence: verdictSequence,
          tick: simulation.tick,
          event: event
        )
        verdictLog.append(frame)
        effects.append(.broadcast(.verdict(frame)))
      }
      if configuration.snapshotIntervalTicks > 0,
         simulation.tick % Int64(configuration.snapshotIntervalTicks) == 0
      {
        effects.append(.broadcast(.snapshot(snapshot())))
      }
    }
    return effects
  }

  public mutating func memberDropped(
    _ slot: UInt8,
    atMs: Int64
  ) -> [AuthorityHostEffect] {
    guard slot != 0, roster.playerID(for: slot) != nil else { return [] }
    lastHeardAtMs[slot] = atMs
    guard fireLockedSlots.insert(slot).inserted else {
      return [.broadcast(.snapshot(snapshot()))]
    }
    pendingInputs.removeAll { input in
      switch input {
      case let .poseSample(id, _), let .reload(id):
        return roster.slot(for: id) == slot
      case let .fire(claim):
        return roster.slot(for: claim.shooterID) == slot
      }
    }
    return [
      .memberFireLocked(slot: slot),
      .broadcast(.snapshot(snapshot())),
    ]
  }

  public mutating func memberRecovered(
    _ slot: UInt8,
    atMs: Int64
  ) -> [AuthorityHostEffect] {
    guard roster.playerID(for: slot) != nil else { return [] }
    lastHeardAtMs[slot] = atMs
    guard fireLockedSlots.remove(slot) != nil else { return [] }
    return [
      .memberFireUnlocked(slot: slot),
      .broadcast(.snapshot(snapshot())),
    ]
  }

  public func snapshot() -> StateSnapshot {
    let players = (0..<UInt8(roster.playerCount)).compactMap { slot -> PlayerSnapshot? in
      guard let id = roster.playerID(for: slot),
            let state = simulation.player(id)
      else { return nil }
      return PlayerSnapshot(
        slot: slot,
        health: state.health,
        lifeState: state.lifeState,
        kills: state.kills,
        deaths: state.deaths,
        ammo: state.ammo,
        reloadEndsAtMs: state.reloadEndsAtMs,
        respawnAtMs: state.respawnAtMs,
        spawnProtectedUntilMs: state.spawnProtectedUntilMs,
        fireLocked: fireLockedSlots.contains(slot)
      )
    }
    return StateSnapshot(
      sequence: verdictSequence,
      tick: simulation.tick,
      clockMs: simulation.clockMs,
      players: players
    )
  }

  private mutating func ingestUnlocked(
    _ message: AuthorityMessage,
    from senderSlot: UInt8,
    atMs: Int64
  ) -> [AuthorityHostEffect] {
    switch message {
    case let .pose(input):
      guard input.slot == senderSlot else {
        return [.rejectedInput(slot: senderSlot, reason: .slotMismatch)]
      }
      guard isNew(input.sequence, for: senderSlot, kind: .pose) else {
        return [.rejectedInput(slot: senderSlot, reason: .staleSequence)]
      }
      mark(input.sequence, for: senderSlot, kind: .pose)
      guard let id = roster.playerID(for: senderSlot) else {
        return [.rejectedInput(slot: senderSlot, reason: .unknownSlot)]
      }
      pendingInputs.append(.poseSample(id, input.sample))
      return []
    case let .fire(input):
      guard input.slot == senderSlot else {
        return [.rejectedInput(slot: senderSlot, reason: .slotMismatch)]
      }
      guard isNew(input.sequence, for: senderSlot, kind: .fire) else { return [] }
      guard input.claim.shooterID == roster.playerID(for: senderSlot) else {
        return [.rejectedInput(slot: senderSlot, reason: .slotMismatch)]
      }
      mark(input.sequence, for: senderSlot, kind: .fire)
      pendingInputs.append(.fire(input.claim))
      return []
    case let .reload(input):
      guard input.slot == senderSlot else {
        return [.rejectedInput(slot: senderSlot, reason: .slotMismatch)]
      }
      guard isNew(input.sequence, for: senderSlot, kind: .reload) else { return [] }
      mark(input.sequence, for: senderSlot, kind: .reload)
      guard let id = roster.playerID(for: senderSlot) else {
        return [.rejectedInput(slot: senderSlot, reason: .unknownSlot)]
      }
      pendingInputs.append(.reload(id))
      return []
    case .verdict, .snapshot:
      return [
        .rejectedInput(slot: senderSlot, reason: .hostDoesNotAcceptVerdicts)
      ]
    }
  }

  private func isNew(
    _ sequence: UInt32,
    for slot: UInt8,
    kind: InputKind
  ) -> Bool {
    guard let previous = lastSequences[slot]?[kind] else { return true }
    return sequence > previous
  }

  private mutating func mark(
    _ sequence: UInt32,
    for slot: UInt8,
    kind: InputKind
  ) {
    lastSequences[slot, default: [:]][kind] = sequence
  }
}
