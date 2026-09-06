import Foundation

enum GameSessionAvailability: Equatable, Sendable {
  case available
  case notConfigured
}

struct CreateDuelRequest: Equatable, Sendable {
  let displayName: String
  let arenaRadiusMeters: Double
}

struct JoinDuelRequest: Equatable, Sendable {
  let displayName: String
  let code: String
}

protocol GameSessionClient: Sendable {
  var availability: GameSessionAvailability { get }

  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession
  func setReady(session: PlayerSession, isReady: Bool) async throws
  func startDuel(session: PlayerSession) async throws
  func heartbeat(session: PlayerSession) async throws
  func startReload(session: PlayerSession) async throws -> ReloadResult
  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult
  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult
  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error>
  func connectionStates() -> AsyncStream<GameSessionConnectionState>
}

extension GameSessionClient {
  func heartbeat(session: PlayerSession) async throws {}

  func startReload(session: PlayerSession) async throws -> ReloadResult {
    throw GameSessionClientError.notConfigured
  }

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    throw GameSessionClientError.notConfigured
  }
}

enum GameSessionClientError: Error, Equatable, Sendable {
  case notConfigured
  case backend(BackendErrorCode)
  case invalidSnapshot
  case networkUnavailable
  case unknown
}

extension GameSessionClientError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notConfigured:
      "LIVE DUEL SERVICE IS NOT CONFIGURED"
    case .backend(.invalidDisplayName):
      "ENTER A CALLSIGN"
    case .backend(.invalidCode), .backend(.matchNotFound):
      "DUEL CODE NOT FOUND"
    case .backend(.matchFull):
      "DUEL IS FULL"
    case .backend(.matchAlreadyStarted):
      "DUEL ALREADY STARTED"
    case .backend(.playersNotReady):
      "BOTH PLAYERS MUST BE READY"
    case .backend(.playersNotConnected):
      "BOTH PLAYERS MUST BE CONNECTED"
    case .backend(.matchNotRunning):
      "SHOT LOCKED UNTIL DUEL STARTS"
    case .backend(.connectionStale):
      "SHOT LOCKED WHILE RECONNECTING"
    case .backend(.playerNotAlive):
      "WAITING TO RESPAWN"
    case .backend(.invalidLocation), .backend(.invalidArena):
      "LOCATION IS NOT READY"
    case .backend(.matchAlreadyFinished):
      "DUEL COMPLETE"
    case .backend(.magazineFull):
      "MAGAZINE FULL"
    case .backend(.alreadyReloading):
      "RELOADING"
    case .backend(.hostOnly), .backend(.invalidSession), .invalidSnapshot, .unknown:
      "SOMETHING WENT WRONG"
    case .networkUnavailable:
      "CAN’T REACH THE DUEL"
    }
  }
}

struct UnavailableGameSessionClient: GameSessionClient {
  let availability = GameSessionAvailability.notConfigured

  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {
    throw GameSessionClientError.notConfigured
  }

  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {
    throw GameSessionClientError.notConfigured
  }

  func setReady(session: PlayerSession, isReady: Bool) async throws {
    throw GameSessionClientError.notConfigured
  }

  func startDuel(session: PlayerSession) async throws {
    throw GameSessionClientError.notConfigured
  }

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    throw GameSessionClientError.notConfigured
  }

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    throw GameSessionClientError.notConfigured
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(throwing: GameSessionClientError.notConfigured)
    }
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> {
    AsyncStream { continuation in
      continuation.finish()
    }
  }
}
