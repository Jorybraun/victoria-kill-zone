import Foundation
import PewPewSimulation

public struct PoseInput: Equatable, Sendable {
  public let slot: UInt8
  public let sequence: UInt32
  public let sample: PoseSample

  public init(slot: UInt8, sequence: UInt32, sample: PoseSample) {
    self.slot = slot
    self.sequence = sequence
    self.sample = sample
  }
}

public struct FireInput: Equatable, Sendable {
  public let slot: UInt8
  public let sequence: UInt32
  public let claim: ShotClaim

  public init(slot: UInt8, sequence: UInt32, claim: ShotClaim) {
    self.slot = slot
    self.sequence = sequence
    self.claim = claim
  }
}

public struct ReloadInput: Equatable, Sendable {
  public let slot: UInt8
  public let sequence: UInt32
  public let requestedAtMs: Int64

  public init(slot: UInt8, sequence: UInt32, requestedAtMs: Int64) {
    self.slot = slot
    self.sequence = sequence
    self.requestedAtMs = requestedAtMs
  }
}

public struct VerdictFrame: Equatable, Sendable {
  public let sequence: UInt32
  public let tick: Int64
  public let event: SimulationEvent

  public init(sequence: UInt32, tick: Int64, event: SimulationEvent) {
    self.sequence = sequence
    self.tick = tick
    self.event = event
  }
}

public struct PlayerSnapshot: Equatable, Sendable {
  public let slot: UInt8
  public var health: Int
  public var lifeState: SimulationLifeState
  public var kills: Int
  public var deaths: Int
  public var ammo: Int
  public var reloadEndsAtMs: Int64?
  public var respawnAtMs: Int64?
  public var spawnProtectedUntilMs: Int64?
  public var fireLocked: Bool

  public init(
    slot: UInt8,
    health: Int,
    lifeState: SimulationLifeState,
    kills: Int,
    deaths: Int,
    ammo: Int,
    reloadEndsAtMs: Int64?,
    respawnAtMs: Int64?,
    spawnProtectedUntilMs: Int64?,
    fireLocked: Bool
  ) {
    self.slot = slot
    self.health = health
    self.lifeState = lifeState
    self.kills = kills
    self.deaths = deaths
    self.ammo = ammo
    self.reloadEndsAtMs = reloadEndsAtMs
    self.respawnAtMs = respawnAtMs
    self.spawnProtectedUntilMs = spawnProtectedUntilMs
    self.fireLocked = fireLocked
  }
}

public struct StateSnapshot: Equatable, Sendable {
  public let sequence: UInt32
  public let tick: Int64
  public let clockMs: Int64
  public let players: [PlayerSnapshot]

  public init(sequence: UInt32, tick: Int64, clockMs: Int64, players: [PlayerSnapshot]) {
    self.sequence = sequence
    self.tick = tick
    self.clockMs = clockMs
    self.players = players
  }
}

public enum AuthorityMessage: Equatable, Sendable {
  case pose(PoseInput)
  case fire(FireInput)
  case reload(ReloadInput)
  case verdict(VerdictFrame)
  case snapshot(StateSnapshot)
}
