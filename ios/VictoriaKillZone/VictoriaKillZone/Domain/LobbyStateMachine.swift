import Foundation

struct LobbyStateMachine: Equatable, Sendable {
  private(set) var route: LobbyRoute

  init(route: LobbyRoute = .home) {
    self.route = route
  }

  mutating func send(_ action: LobbyAction) throws {
    switch action {
    case .showJoin:
      guard route == .home else { throw LobbyTransitionError.invalidTransition }
      route = .join

    case .cancelJoin:
      guard route == .join else { throw LobbyTransitionError.invalidTransition }
      route = .home

    case .create(let displayName, let code):
      guard route == .home else { throw LobbyTransitionError.invalidTransition }
      let playerName = try Self.validatedDisplayName(displayName)
      let normalizedCode = try Self.validatedJoinCode(code)
      let host = LobbyPlayer(
        id: "shell-local-host",
        displayName: playerName,
        role: .host,
        isReady: false
      )
      route = .waiting(
        WaitingRoom(
          matchID: Self.shellMatchID(for: normalizedCode),
          code: normalizedCode,
          arenaRadiusMeters: 30,
          localPlayerID: host.id,
          hostPlayerID: host.id,
          players: [host]
        )
      )

    case .join(let displayName, let code):
      guard route == .join else { throw LobbyTransitionError.invalidTransition }
      let playerName = try Self.validatedDisplayName(displayName)
      let normalizedCode = try Self.validatedJoinCode(code)
      let host = LobbyPlayer(
        id: "shell-remote-host",
        displayName: "Host",
        role: .host,
        isReady: false
      )
      let guest = LobbyPlayer(
        id: "shell-local-guest",
        displayName: playerName,
        role: .guest,
        isReady: false
      )
      route = .waiting(
        WaitingRoom(
          matchID: Self.shellMatchID(for: normalizedCode),
          code: normalizedCode,
          arenaRadiusMeters: 30,
          localPlayerID: guest.id,
          hostPlayerID: host.id,
          players: [host, guest]
        )
      )

    case .opponentJoined(let displayName):
      guard case .waiting(var room) = route else {
        throw LobbyTransitionError.invalidTransition
      }
      guard room.localRole == .host else { throw LobbyTransitionError.hostOnly }
      guard !room.isFull else { throw LobbyTransitionError.opponentSlotUnavailable }
      let playerName = try Self.validatedDisplayName(displayName)
      room.players.append(
        LobbyPlayer(
          id: "shell-remote-guest",
          displayName: playerName,
          role: .guest,
          isReady: false
        )
      )
      route = .waiting(room)

    case .readinessChanged(let playerID, let isReady):
      guard case .waiting(var room) = route else {
        throw LobbyTransitionError.invalidTransition
      }
      guard let index = room.players.firstIndex(where: { $0.id == playerID }) else {
        throw LobbyTransitionError.unknownPlayer
      }
      room.players[index].isReady = isReady
      route = .waiting(room)

    case .startRequested:
      guard case .waiting(let room) = route else {
        throw LobbyTransitionError.invalidTransition
      }
      guard room.localPlayerID == room.hostPlayerID else {
        throw LobbyTransitionError.hostOnly
      }
      try start(room)

    case .matchStarted:
      guard case .waiting(let room) = route else {
        throw LobbyTransitionError.invalidTransition
      }
      try start(room)

    case .leave:
      route = .home
    }
  }

  private mutating func start(_ room: WaitingRoom) throws {
    guard room.allPlayersReady else { throw LobbyTransitionError.playersNotReady }
    route = .active(
      ActiveDuel(
        matchID: room.matchID,
        code: room.code,
        localPlayerID: room.localPlayerID,
        players: room.players,
        durationMilliseconds: 180_000
      )
    )
  }

  private static func validatedDisplayName(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 20 else {
      throw LobbyTransitionError.invalidDisplayName
    }
    return normalized
  }

  private static func validatedJoinCode(_ value: String) throws -> String {
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    let isASCIIAlphaNumeric = normalized.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (65...90).contains(byte)
    }
    guard normalized.utf8.count == 6, isASCIIAlphaNumeric else {
      throw LobbyTransitionError.invalidJoinCode
    }
    return normalized
  }

  private static func shellMatchID(for code: String) -> String {
    "shell-\(code.lowercased())"
  }
}
