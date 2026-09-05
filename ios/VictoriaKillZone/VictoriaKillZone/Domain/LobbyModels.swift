import Foundation

enum LobbyRole: String, Equatable, Sendable {
  case host
  case guest
}

struct LobbyPlayer: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let role: LobbyRole
  var isReady: Bool
  var isConnected: Bool
  var health: Int
  var ammo: Int
  var kills: Int
  var deaths: Int
  var lifeState: PlayerLifeState
  var respawnAt: Double?

  init(
    id: String,
    displayName: String,
    role: LobbyRole,
    isReady: Bool,
    isConnected: Bool = true,
    health: Int = 100,
    ammo: Int = 8,
    kills: Int = 0,
    deaths: Int = 0,
    lifeState: PlayerLifeState = .alive,
    respawnAt: Double? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.role = role
    self.isReady = isReady
    self.isConnected = isConnected
    self.health = health
    self.ammo = ammo
    self.kills = kills
    self.deaths = deaths
    self.lifeState = lifeState
    self.respawnAt = respawnAt
  }

  init(snapshot: PlayerSnapshot) {
    self.init(
      id: snapshot.id,
      displayName: snapshot.displayName,
      role: LobbyRole(rawValue: snapshot.role.rawValue) ?? .guest,
      isReady: snapshot.ready,
      isConnected: snapshot.connected,
      health: snapshot.health,
      ammo: snapshot.ammo,
      kills: snapshot.kills,
      deaths: snapshot.deaths,
      lifeState: snapshot.lifeState,
      respawnAt: snapshot.respawnAt
    )
  }
}

struct WaitingRoom: Equatable, Sendable {
  let matchID: String
  let code: String
  let arenaRadiusMeters: Double
  let localPlayerID: String
  let hostPlayerID: String
  var players: [LobbyPlayer]
  var combatMode: CombatMode? = nil
  var maxPlayers: Int = 2

  var localPlayer: LobbyPlayer? {
    players.first { $0.id == localPlayerID }
  }

  var localRole: LobbyRole? {
    localPlayer?.role
  }

  var isFull: Bool {
    players.count >= maxPlayers
  }

  var allPlayersReady: Bool {
    players.count >= 2 && players.count <= maxPlayers
      && players.allSatisfy { $0.isReady && $0.isConnected }
  }

  var canLocalPlayerStart: Bool {
    localPlayerID == hostPlayerID && allPlayersReady
  }
}

struct ActiveDuel: Equatable, Sendable {
  let matchID: String
  let code: String
  let localPlayerID: String
  let players: [LobbyPlayer]
  let phase: MatchPhase
  let durationMilliseconds: Int
  let startsAt: Double?
  let endsAt: Double?
  let serverNow: Double
  let syncedAt: Date
  let events: [EventSnapshot]

  init(
    matchID: String,
    code: String,
    localPlayerID: String,
    players: [LobbyPlayer],
    phase: MatchPhase = .running,
    durationMilliseconds: Int = 180_000,
    startsAt: Double? = nil,
    endsAt: Double? = nil,
    serverNow: Double = 0,
    syncedAt: Date = .distantPast,
    events: [EventSnapshot] = []
  ) {
    self.matchID = matchID
    self.code = code
    self.localPlayerID = localPlayerID
    self.players = players
    self.phase = phase
    self.durationMilliseconds = durationMilliseconds
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.serverNow = serverNow
    self.syncedAt = syncedAt
    self.events = events
  }

  var durationSeconds: Int {
    durationMilliseconds / 1_000
  }

  var localPlayer: LobbyPlayer? {
    players.first { $0.id == localPlayerID }
  }

  var opponent: LobbyPlayer? {
    players.first { $0.id != localPlayerID }
  }

  var localRole: LobbyRole? {
    localPlayer?.role
  }
}

enum LobbyRoute: Equatable, Sendable {
  case home
  case join
  case waiting(WaitingRoom)
  case active(ActiveDuel)
}

enum LobbyAction: Equatable, Sendable {
  case showJoin
  case cancelJoin
  case create(displayName: String, code: String)
  case join(displayName: String, code: String)
  case opponentJoined(displayName: String)
  case readinessChanged(playerID: String, isReady: Bool)
  case startRequested
  case matchStarted
  case leave
}

enum LobbyTransitionError: Error, Equatable, Sendable {
  case invalidTransition
  case invalidDisplayName
  case invalidJoinCode
  case opponentSlotUnavailable
  case unknownPlayer
  case hostOnly
  case playersNotReady
}

extension LobbyTransitionError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidTransition:
      "That action is not available from the current screen."
    case .invalidDisplayName:
      "Enter a display name between 1 and 20 characters."
    case .invalidJoinCode:
      "Enter a six-character duel code."
    case .opponentSlotUnavailable:
      "This duel already has two players."
    case .unknownPlayer:
      "The player is no longer in this lobby."
    case .hostOnly:
      "Only the host can start this duel."
    case .playersNotReady:
      "Both players must be ready before the duel starts."
    }
  }
}
