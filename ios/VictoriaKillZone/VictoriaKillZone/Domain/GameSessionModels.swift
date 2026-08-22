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

enum MatchEventType: String, Codable, Equatable, Sendable {
  case joined
  case ready
  case started
  case hit
}

struct MatchSummary: Codable, Equatable, Sendable {
  let id: String
  let code: String
  let phase: MatchPhase
  let durationMs: Int
  let startsAt: Double?
  let endsAt: Double?
}

struct PlayerSnapshot: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let role: PlayerRole
  let ready: Bool
  let connected: Bool
  let health: Int
  let ammo: Int
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
}

enum GameSessionConnectionState: Equatable, Sendable {
  case connecting
  case connected
}
