import Foundation

enum MatchPhase: String, Codable, Equatable, Sendable {
  case lobby
  case countdown
  case running
  case finished
  case cancelled
}

enum PlayerRole: String, Codable, Equatable, Sendable {
  case host
  case guest
}

enum PlayerLifeState: String, Codable, Equatable, Sendable {
  case alive
  case dead
  case respawning
  case disconnected
}

enum HitZone: String, Codable, Equatable, Sendable {
  case head
  case torso
  case limbs
}

enum MatchEventType: String, Codable, Equatable, Sendable {
  case joined
  case ready
  case started
  case shot
  case hit
  case eliminated
  case respawned
  case outOfZone = "out_of_zone"
  case finished
}

struct MatchSummary: Codable, Equatable, Sendable {
  let id: String
  let code: String
  let phase: MatchPhase
  let durationMs: Int
  let startsAt: Double?
  let endsAt: Double?
  let winnerPlayerId: String?

  init(
    id: String,
    code: String,
    phase: MatchPhase,
    durationMs: Int,
    startsAt: Double?,
    endsAt: Double?,
    winnerPlayerId: String? = nil
  ) {
    self.id = id
    self.code = code
    self.phase = phase
    self.durationMs = durationMs
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.winnerPlayerId = winnerPlayerId
  }
}

struct PlayerSnapshot: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let role: PlayerRole
  let ready: Bool
  let connected: Bool
  let health: Int
  let ammo: Int
  let kills: Int
  let deaths: Int
  let lifeState: PlayerLifeState
  let respawnAt: Double?

  init(
    id: String,
    displayName: String,
    role: PlayerRole,
    ready: Bool,
    connected: Bool,
    health: Int,
    ammo: Int,
    kills: Int = 0,
    deaths: Int = 0,
    lifeState: PlayerLifeState = .alive,
    respawnAt: Double? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.role = role
    self.ready = ready
    self.connected = connected
    self.health = health
    self.ammo = ammo
    self.kills = kills
    self.deaths = deaths
    self.lifeState = lifeState
    self.respawnAt = respawnAt
  }
}

struct EventSnapshot: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let type: MatchEventType
  let message: String
  let createdAt: Double
  let actorPlayerId: String?
  let targetPlayerId: String?
  let zone: String?
  let damage: Int?
}

struct MatchSnapshot: Codable, Equatable, Sendable {
  let serverNow: Double
  let match: MatchSummary
  let localPlayerId: String
  let players: [PlayerSnapshot]
  let events: [EventSnapshot]
}

/// Match-scoped capability returned only to the phone that created or joined a duel.
///
/// Its textual representations are intentionally redacted so accidental logging does
/// not expose the session secret.
struct PlayerSession: Decodable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let matchId: String
  let code: String
  let playerId: String
  let sessionSecret: String

  var description: String {
    "PlayerSession(matchId: \(matchId), code: \(code), playerId: \(playerId), sessionSecret: <redacted>)"
  }

  var debugDescription: String { description }
}

enum DebugFireOutcome: String, Codable, Equatable, Sendable {
  case hit
  case rejected
}

struct DebugFireResult: Codable, Equatable, Sendable {
  let accepted: Bool
  let outcome: DebugFireOutcome
  let clientShotId: String
  let replayed: Bool
  let damage: Int
  let shooterAmmo: Int
  let targetHealth: Int
  let eventId: String?
  let rejectReason: BackendErrorCode?
}

enum FireShotOutcome: String, Codable, Equatable, Sendable {
  case miss
  case hit
  case kill
  case rejected
}

enum FireRejectReason: String, Codable, Equatable, Sendable {
  case matchNotRunning = "MATCH_NOT_RUNNING"
  case connectionStale = "CONNECTION_STALE"
  case shooterNotAlive = "SHOOTER_NOT_ALIVE"
  case reloading = "RELOADING"
  case outOfArena = "OUT_OF_ARENA"
  case locationStale = "LOCATION_STALE"
  case outOfAmmo = "OUT_OF_AMMO"
  case fireCooldown = "FIRE_COOLDOWN"
  case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
  case invalidTarget = "INVALID_TARGET"
  case targetNotAlive = "TARGET_NOT_ALIVE"
}

struct FireShotRequest: Equatable, Sendable {
  let clientShotId: String
  let targetId: String?
  let zone: HitZone?
  let poseConfidence: Double?
  let origin: [Double]?
  let direction: [Double]?
  let firedAtClient: Double
}

struct FireShotResult: Codable, Equatable, Sendable {
  let accepted: Bool
  let outcome: FireShotOutcome
  let clientShotId: String
  let replayed: Bool
  let damage: Int
  let shooterAmmo: Int
  let targetHealth: Int?
  let targetLifeState: PlayerLifeState?
  let eventId: String?
  let rejectReason: FireRejectReason?
}

enum BackendErrorCode: String, Codable, Equatable, Sendable {
  case invalidDisplayName = "INVALID_DISPLAY_NAME"
  case invalidCode = "INVALID_CODE"
  case matchNotFound = "MATCH_NOT_FOUND"
  case matchFull = "MATCH_FULL"
  case matchAlreadyStarted = "MATCH_ALREADY_STARTED"
  case invalidSession = "INVALID_SESSION"
  case playersNotReady = "PLAYERS_NOT_READY"
  case playersNotConnected = "PLAYERS_NOT_CONNECTED"
  case hostOnly = "HOST_ONLY"
  case matchNotRunning = "MATCH_NOT_RUNNING"
  case connectionStale = "CONNECTION_STALE"
  case invalidArena = "INVALID_ARENA"
  case invalidLocation = "INVALID_LOCATION"
  case matchAlreadyFinished = "MATCH_ALREADY_FINISHED"
  case playerNotAlive = "PLAYER_NOT_ALIVE"
  case magazineFull = "MAGAZINE_FULL"
  case alreadyReloading = "ALREADY_RELOADING"
}

enum GameSessionConnectionState: Equatable, Sendable {
  case connecting
  case connected
}
