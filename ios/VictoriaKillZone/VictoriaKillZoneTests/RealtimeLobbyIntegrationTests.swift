import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class RealtimeLobbyIntegrationTests: XCTestCase {
  func testRealtimeCreateRequestsFourSlotsWithoutChangingClassicRequest() async {
    let client = ArenaLobbyClient()
    let store = makeStore(client)
    store.displayName = "Host"
    await store.performCreateDuel(combatMode: .durableObject)
    XCTAssertEqual(client.requests.first?.combatMode, .durableObject)
    XCTAssertEqual(client.requests.first?.maxPlayers, 4)
    store.leave()
  }

  func testThreeReadyMembersPrepareAuthorityWithoutCallingLegacyStart() async throws {
    let client = ArenaLobbyClient()
    let store = makeStore(client)
    await store.performCreateDuel(combatMode: .durableObject)
    client.emit(Self.snapshot(count: 3))
    try await until { if case .waiting = store.route { true } else { false } }
    guard case .waiting(let room) = store.route else { return XCTFail("Missing lobby") }
    XCTAssertEqual(room.maxPlayers, 4)
    XCTAssertFalse(room.isFull)
    XCTAssertTrue(room.canLocalPlayerStart)
    await store.performStartDuel()
    XCTAssertEqual(client.prepares, 1)
    XCTAssertEqual(client.legacyStarts, 0)
    store.leave()
  }

  func testFifthMemberSnapshotIsRejected() async throws {
    let client = ArenaLobbyClient()
    let store = makeStore(client)
    await store.performCreateDuel(combatMode: .durableObject)
    client.emit(Self.snapshot(count: 5))
    try await until {store.errorMessage != nil}
    XCTAssertEqual(store.route, .home)
    XCTAssertNil(store.realtimeArena)
    store.leave()
  }

  func testProjectionKeepsOneCombatControllerAndLeaveClearsIt() async throws {
    let client = ArenaLobbyClient()
    let store = makeStore(client)
    await store.performCreateDuel(combatMode: .durableObject)
    client.emit(Self.snapshot(count: 4, phase: .running))
    try await until {store.realtimeArena != nil}
    let arena = try XCTUnwrap(store.realtimeArena)
    XCTAssertNil(store.duel.session, "Legacy combat must not run alongside realtime combat")
    client.emit(Self.snapshot(count: 4, phase: .running, serverNow: 101))
    try await until { if case .active(let duel) = store.route { duel.serverNow == 101 } else { false } }
    XCTAssertTrue(store.realtimeArena === arena)
    store.leave()
    try await until {store.route == .home}
    XCTAssertNil(store.realtimeArena)
  }

  private func makeStore(_ client: ArenaLobbyClient) -> LobbyStore {
    LobbyStore(environment: .init(gameSessionClient: client, targetingSession: UnavailableTargetingSession()))
  }
  private func until(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !predicate(), Date() < deadline {try await Task.sleep(for: .milliseconds(5))}
    XCTAssertTrue(predicate())
  }
  private static func snapshot(count: Int, phase: MatchPhase = .lobby, serverNow: Double = 100) -> MatchSnapshot {
    .init(serverNow: serverNow,
      match: .init(id: "match", code: "ABC123", phase: phase, durationMs: 180_000, startsAt: nil, endsAt: nil,
        combatMode: .durableObject, combatPhase: phase == .running ? .calibrating : nil, maxPlayers: 4),
      localPlayerId: "p0", players: (0..<count).map {
        .init(id: "p\($0)", displayName: "Player \($0)", role: $0 == 0 ? .host : .guest,
          ready: true, connected: true, health: 100, ammo: 8)
      }, events: [])
  }
}

private final class ArenaLobbyClient: GameSessionClient, @unchecked Sendable {
  let availability = GameSessionAvailability.available
  private let lock = NSLock()
  private let pair = AsyncThrowingStream<MatchSnapshot, Error>.makeStream()
  private var storedRequests: [CreateDuelRequest] = []
  private var storedPrepares = 0
  private var storedLegacyStarts = 0
  var requests: [CreateDuelRequest] {lock.withLock {storedRequests}}
  var prepares: Int {lock.withLock {storedPrepares}}
  var legacyStarts: Int {lock.withLock {storedLegacyStarts}}
  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {
    lock.withLock {storedRequests.append(request)}
    return .init(matchId: "match", code: "ABC123", playerId: "p0", sessionSecret: UUID().uuidString)
  }
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func setReady(session: PlayerSession, isReady: Bool) async throws {}
  func startDuel(session: PlayerSession) async throws {lock.withLock {storedLegacyStarts += 1}}
  func prepareRealtimeCombat(session: PlayerSession) async throws {lock.withLock {storedPrepares += 1}}
  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {throw GameSessionClientError.notConfigured}
  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {pair.stream}
  func connectionStates() -> AsyncStream<GameSessionConnectionState> {AsyncStream {$0.yield(.connected); $0.finish()}}
  func emit(_ snapshot: MatchSnapshot) {pair.continuation.yield(snapshot)}
}
