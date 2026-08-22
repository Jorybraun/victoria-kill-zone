import Combine
import ConvexMobile
import Foundation

/// The single reconciliation point for every G2 backend wire name.
enum ConvexGameSessionContract {
  static let create = "matches:create"
  static let join = "matches:join"
  static let setReady = "matches:setReady"
  static let start = "matches:start"
  static let fire = "shots:fire"
  static let debugFire = "shots:debugFire"
  static let matchSnapshot = "queries:matchSnapshot"
}

/// Typed builders keep the Convex argument keys in one testable place.
enum ConvexGameSessionArguments {
  static func create(_ request: CreateDuelRequest) -> [String: ConvexEncodable?] {
    [
      "displayName": request.displayName,
      "arenaRadiusMeters": request.arenaRadiusMeters,
    ]
  }

  static func join(_ request: JoinDuelRequest) -> [String: ConvexEncodable?] {
    [
      "displayName": request.displayName,
      "code": request.code,
    ]
  }

  static func authenticated(_ session: PlayerSession) -> [String: ConvexEncodable?] {
    [
      "matchId": session.matchId,
      "playerId": session.playerId,
      "sessionSecret": session.sessionSecret,
    ]
  }

  static func setReady(
    session: PlayerSession,
    isReady: Bool
  ) -> [String: ConvexEncodable?] {
    authenticated(session).merging(["isReady": isReady]) { _, new in new }
  }

  static func debugFire(
    session: PlayerSession,
    clientShotId: String
  ) -> [String: ConvexEncodable?] {
    authenticated(session).merging(["clientShotId": clientShotId]) { _, new in new }
  }
}

final class ConvexGameSessionClient: GameSessionClient, @unchecked Sendable {
  let availability = GameSessionAvailability.available

  private let client: ConvexClient

  init(deploymentURL: String) {
    client = ConvexClient(deploymentUrl: deploymentURL)
  }

  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {
    do {
      return try await client.mutation(
        ConvexGameSessionContract.create,
        with: ConvexGameSessionArguments.create(request)
      )
    } catch {
      throw Self.mapped(error)
    }
  }

  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {
    do {
      return try await client.mutation(
        ConvexGameSessionContract.join,
        with: ConvexGameSessionArguments.join(request)
      )
    } catch {
      throw Self.mapped(error)
    }
  }

  func setReady(session: PlayerSession, isReady: Bool) async throws {
    do {
      try await client.mutation(
        ConvexGameSessionContract.setReady,
        with: ConvexGameSessionArguments.setReady(session: session, isReady: isReady)
      )
    } catch {
      throw Self.mapped(error)
    }
  }

  func startDuel(session: PlayerSession) async throws {
    do {
      try await client.mutation(
        ConvexGameSessionContract.start,
        with: ConvexGameSessionArguments.authenticated(session)
      )
    } catch {
      throw Self.mapped(error)
    }
  }

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    var arguments: [String: ConvexEncodable?] = [
      "matchId": session.matchId,
      "shooterId": session.playerId,
      "sessionSecret": session.sessionSecret,
      "clientShotId": request.clientShotId,
      "firedAtClient": request.firedAtClient,
    ]
    if let targetId = request.targetId { arguments["targetId"] = targetId }
    if let zone = request.zone { arguments["zone"] = zone.rawValue }
    if let poseConfidence = request.poseConfidence {
      arguments["poseConfidence"] = poseConfidence
    }
    if let origin = request.origin {
      arguments["origin"] = origin.map { $0 as ConvexEncodable? }
    }
    if let direction = request.direction {
      arguments["direction"] = direction.map { $0 as ConvexEncodable? }
    }

    do {
      let result: FireShotResultWire = try await client.mutation(
        ConvexGameSessionContract.fire,
        with: arguments
      )
      return try result.domainValue()
    } catch {
      throw Self.mapped(error)
    }
  }

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    do {
      let result: DebugFireResultWire = try await client.mutation(
        ConvexGameSessionContract.debugFire,
        with: ConvexGameSessionArguments.debugFire(
          session: session,
          clientShotId: clientShotId
        )
      )
      return try result.domainValue()
    } catch {
      throw Self.mapped(error)
    }
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    let publisher = client.subscribe(
      to: ConvexGameSessionContract.matchSnapshot,
      with: ConvexGameSessionArguments.authenticated(session),
      yielding: MatchSnapshotWire.self
    )
    .tryMap { try $0.domainValue() }

    return AsyncThrowingStream { continuation in
      let cancellation = CancellationBox()
      cancellation.value = publisher.sink(
        receiveCompletion: { completion in
          switch completion {
          case .finished:
            continuation.finish()
          case .failure(let error):
            continuation.finish(throwing: Self.mapped(error))
          }
        },
        receiveValue: { snapshot in
          continuation.yield(snapshot)
        }
      )
      continuation.onTermination = { _ in
        cancellation.cancel()
      }
    }
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> {
    let publisher = client.watchWebSocketState()

    return AsyncStream { continuation in
      let cancellation = CancellationBox()
      cancellation.value = publisher.sink { state in
        continuation.yield(state == .connected ? .connected : .connecting)
      }
      continuation.onTermination = { _ in
        cancellation.cancel()
      }
    }
  }

  private static func mapped(_ error: Error) -> GameSessionClientError {
    if let error = error as? GameSessionClientError {
      return error
    }

    if case ClientError.ConvexError(let data) = error,
      let code = backendCode(in: data)
    {
      return .backend(code)
    }

    if error is DecodingError {
      return .invalidSnapshot
    }

    if error is ClientError {
      return .networkUnavailable
    }

    return .unknown
  }

  static func backendCode(in value: String) -> BackendErrorCode? {
    guard let data = value.data(using: .utf8) else { return nil }
    if let code = try? JSONDecoder().decode(BackendErrorCode.self, from: data) {
      return code
    }
    if let object = try? JSONSerialization.jsonObject(with: data),
      let code = findCode(in: object)
    {
      return BackendErrorCode(rawValue: code)
    }
    return BackendErrorCode(rawValue: value)
  }

  private static func findCode(in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      if let code = dictionary["code"] as? String { return code }
      for child in dictionary.values {
        if let code = findCode(in: child) { return code }
      }
    } else if let values = value as? [Any] {
      for child in values {
        if let code = findCode(in: child) { return code }
      }
    }
    return nil
  }
}

struct MatchSnapshotWire: Decodable {
  @ConvexFloat var serverNow: Double
  let match: MatchSummaryWire
  let localPlayerId: String
  let players: [PlayerSnapshotWire]
  let events: [EventSnapshotWire]

  func domainValue() throws -> MatchSnapshot {
    MatchSnapshot(
      serverNow: serverNow,
      match: try match.domainValue(),
      localPlayerId: localPlayerId,
      players: try players.map { try $0.domainValue() },
      events: try events.map { try $0.domainValue() }
    )
  }
}

struct MatchSummaryWire: Decodable {
  let id: String
  let code: String
  let phase: MatchPhase
  @ConvexFloat var durationMs: Double
  @OptionalConvexFloat var startsAt: Double?
  @OptionalConvexFloat var endsAt: Double?
  let winnerPlayerId: String?

  func domainValue() throws -> MatchSummary {
    MatchSummary(
      id: id,
      code: code,
      phase: phase,
      durationMs: try exactInteger(durationMs),
      startsAt: startsAt,
      endsAt: endsAt,
      winnerPlayerId: winnerPlayerId
    )
  }
}

struct PlayerSnapshotWire: Decodable {
  let id: String
  let displayName: String
  let role: PlayerRole
  let ready: Bool
  let connected: Bool
  @ConvexFloat var health: Double
  @ConvexFloat var ammo: Double
  @OptionalConvexFloat var kills: Double?
  @OptionalConvexFloat var deaths: Double?
  let lifeState: PlayerLifeState?
  @OptionalConvexFloat var respawnAt: Double?

  func domainValue() throws -> PlayerSnapshot {
    PlayerSnapshot(
      id: id,
      displayName: displayName,
      role: role,
      ready: ready,
      connected: connected,
      health: try exactInteger(health),
      ammo: try exactInteger(ammo),
      kills: try kills.map(exactInteger) ?? 0,
      deaths: try deaths.map(exactInteger) ?? 0,
      lifeState: lifeState ?? (connected ? .alive : .disconnected),
      respawnAt: respawnAt
    )
  }
}

struct EventSnapshotWire: Decodable {
  let id: String
  let type: MatchEventType
  let message: String
  @ConvexFloat var createdAt: Double
  let actorPlayerId: String?
  let targetPlayerId: String?
  let zone: String?
  @OptionalConvexFloat var damage: Double?

  func domainValue() throws -> EventSnapshot {
    return EventSnapshot(
      id: id,
      type: type,
      message: message,
      createdAt: createdAt,
      actorPlayerId: actorPlayerId,
      targetPlayerId: targetPlayerId,
      zone: zone.flatMap { HitZone(rawValue: $0)?.rawValue },
      damage: try damage.map(exactInteger)
    )
  }
}

struct DebugFireResultWire: Decodable {
  let accepted: Bool
  let outcome: DebugFireOutcome
  let clientShotId: String
  let replayed: Bool
  @ConvexFloat var damage: Double
  @ConvexFloat var shooterAmmo: Double
  @ConvexFloat var targetHealth: Double
  let eventId: String?
  let rejectReason: BackendErrorCode?

  func domainValue() throws -> DebugFireResult {
    DebugFireResult(
      accepted: accepted,
      outcome: outcome,
      clientShotId: clientShotId,
      replayed: replayed,
      damage: try exactInteger(damage),
      shooterAmmo: try exactInteger(shooterAmmo),
      targetHealth: try exactInteger(targetHealth),
      eventId: eventId,
      rejectReason: rejectReason
    )
  }
}

private struct FireShotResultWire: Decodable {
  let accepted: Bool
  let outcome: FireShotOutcome
  let clientShotId: String
  let replayed: Bool
  @ConvexFloat var damage: Double
  @ConvexFloat var shooterAmmo: Double
  @OptionalConvexFloat var targetHealth: Double?
  let targetLifeState: PlayerLifeState?
  let eventId: String?
  let rejectReason: FireRejectReason?

  func domainValue() throws -> FireShotResult {
    FireShotResult(
      accepted: accepted,
      outcome: outcome,
      clientShotId: clientShotId,
      replayed: replayed,
      damage: try exactInteger(damage),
      shooterAmmo: try exactInteger(shooterAmmo),
      targetHealth: try targetHealth.map(exactInteger),
      targetLifeState: targetLifeState,
      eventId: eventId,
      rejectReason: rejectReason
    )
  }
}

private func exactInteger(_ value: Double) throws -> Int {
  guard value.isFinite, value.rounded() == value, value >= Double(Int.min),
    value <= Double(Int.max)
  else {
    throw GameSessionClientError.invalidSnapshot
  }
  return Int(value)
}

private final class CancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: AnyCancellable?

  var value: AnyCancellable? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  func cancel() {
    lock.withLock {
      storage?.cancel()
      storage = nil
    }
  }
}
