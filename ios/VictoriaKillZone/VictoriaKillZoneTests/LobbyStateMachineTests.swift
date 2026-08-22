import XCTest

@testable import VictoriaKillZone

final class LobbyStateMachineTests: XCTestCase {
  func testCreateMovesHomeToHostWaitingRoom() throws {
    var subject = LobbyStateMachine()

    try subject.send(.create(displayName: "  Victoria  ", code: "vkz001"))

    guard case .waiting(let room) = subject.route else {
      return XCTFail("Expected waiting room")
    }
    XCTAssertEqual(room.code, "VKZ001")
    XCTAssertEqual(room.matchID, "shell-vkz001")
    XCTAssertEqual(room.localRole, .host)
    XCTAssertEqual(room.players.map(\.displayName), ["Victoria"])
    XCTAssertFalse(room.allPlayersReady)
  }

  func testJoinMovesJoinFormToGuestWaitingRoom() throws {
    var subject = LobbyStateMachine()
    try subject.send(.showJoin)

    try subject.send(.join(displayName: "Guest", code: "abc123"))

    guard case .waiting(let room) = subject.route else {
      return XCTFail("Expected waiting room")
    }
    XCTAssertEqual(room.code, "ABC123")
    XCTAssertEqual(room.localRole, .guest)
    XCTAssertEqual(room.players.map(\.role), [.host, .guest])
  }

  func testHostCannotStartUntilLobbyIsFullAndReady() throws {
    var subject = LobbyStateMachine()
    try subject.send(.create(displayName: "Host", code: "ABC123"))

    XCTAssertThrowsError(try subject.send(.startRequested)) { error in
      XCTAssertEqual(error as? LobbyTransitionError, .playersNotReady)
    }

    try subject.send(.opponentJoined(displayName: "Guest"))
    guard case .waiting(let room) = subject.route else {
      return XCTFail("Expected waiting room")
    }
    for player in room.players {
      try subject.send(.readinessChanged(playerID: player.id, isReady: true))
    }

    try subject.send(.startRequested)

    guard case .active(let duel) = subject.route else {
      return XCTFail("Expected active duel")
    }
    XCTAssertEqual(duel.code, "ABC123")
    XCTAssertEqual(duel.durationSeconds, 180)
    XCTAssertEqual(duel.players.count, 2)
  }

  func testGuestCannotUseHostStartAction() throws {
    var subject = LobbyStateMachine()
    try subject.send(.showJoin)
    try subject.send(.join(displayName: "Guest", code: "ABC123"))

    guard case .waiting(let room) = subject.route else {
      return XCTFail("Expected waiting room")
    }
    for player in room.players {
      try subject.send(.readinessChanged(playerID: player.id, isReady: true))
    }

    XCTAssertThrowsError(try subject.send(.startRequested)) { error in
      XCTAssertEqual(error as? LobbyTransitionError, .hostOnly)
    }
    XCTAssertNoThrow(try subject.send(.matchStarted))
    guard case .active = subject.route else {
      return XCTFail("Expected authoritative match start to activate guest")
    }
  }

  func testInvalidJoinCodeLeavesJoinFormUnchanged() throws {
    var subject = LobbyStateMachine()
    try subject.send(.showJoin)

    XCTAssertThrowsError(try subject.send(.join(displayName: "Guest", code: "12"))) { error in
      XCTAssertEqual(error as? LobbyTransitionError, .invalidJoinCode)
    }
    XCTAssertEqual(subject.route, .join)
  }

  func testLeaveAlwaysRecoversToHome() throws {
    var subject = LobbyStateMachine()
    try subject.send(.create(displayName: "Host", code: "ABC123"))

    try subject.send(.leave)

    XCTAssertEqual(subject.route, .home)
  }
}

@MainActor
final class LobbyStoreTests: XCTestCase {
  func testFrozenConvexFunctionNames() {
    XCTAssertEqual(ConvexGameSessionContract.create, "matches:create")
    XCTAssertEqual(ConvexGameSessionContract.join, "matches:join")
    XCTAssertEqual(ConvexGameSessionContract.setReady, "matches:setReady")
    XCTAssertEqual(ConvexGameSessionContract.start, "matches:start")
    XCTAssertEqual(ConvexGameSessionContract.debugFire, "shots:debugFire")
    XCTAssertEqual(ConvexGameSessionContract.matchSnapshot, "queries:matchSnapshot")
  }

  func testPlayerSessionDiagnosticsRedactSecret() {
    let secret = UUID().uuidString
    let session = PlayerSession(
      matchId: "match-1",
      code: "ABC123",
      playerId: "player-1",
      sessionSecret: secret
    )

    XCTAssertFalse(session.description.contains(secret))
    XCTAssertFalse(session.debugDescription.contains(secret))
  }

  func testLiveCreateAndReadyRenderOnlyAuthoritativeSnapshots() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "  Host  "

    await store.performCreateDuel()
    XCTAssertEqual(client.createRequests, [CreateDuelRequest(displayName: "Host", arenaRadiusMeters: 30)])
    XCTAssertEqual(store.operation, .creating)

    client.send(snapshot(phase: .lobby, hostReady: false))
    await settle()

    guard case .waiting(let initialRoom) = store.route else {
      return XCTFail("Expected an authoritative waiting room")
    }
    XCTAssertFalse(initialRoom.localPlayer?.isReady ?? true)
    XCTAssertEqual(store.syncStatus, .connected)

    await store.performSetReady(isReady: true)
    XCTAssertEqual(client.readyValues, [true])
    guard case .waiting(let unchangedRoom) = store.route else {
      return XCTFail("Expected waiting room while subscription catches up")
    }
    XCTAssertFalse(unchangedRoom.localPlayer?.isReady ?? true, "Mutation must not update UI optimistically")

    client.send(snapshot(phase: .lobby, hostReady: true))
    await settle()
    guard case .waiting(let updatedRoom) = store.route else {
      return XCTFail("Expected updated waiting room")
    }
    XCTAssertTrue(updatedRoom.localPlayer?.isReady ?? false)
  }

  func testDebugFireReusesIDAndWaitsForAuthoritativeHealthAndAmmo() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotID: "stable-shot-id")
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .failure(GameSessionClientError.networkUnavailable),
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "stable-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.performDebugFire()
    XCTAssertEqual(store.debugShotState, .failed)
    await store.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["stable-shot-id", "stable-shot-id"])
    XCTAssertEqual(store.debugShotState, .pending)
    await store.performDebugFire()
    XCTAssertEqual(
      client.debugShotIDs,
      ["stable-shot-id", "stable-shot-id"],
      "A pending press must not launch another mutation"
    )
    guard case .active(let unchangedDuel) = store.route else {
      return XCTFail("Expected active duel")
    }
    XCTAssertEqual(unchangedDuel.localPlayer?.ammo, 8)
    XCTAssertEqual(unchangedDuel.opponent?.health, 100)

    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent]
      )
    )
    await settle()

    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
    guard case .active(let reconciledDuel) = store.route else {
      return XCTFail("Expected active duel")
    }
    XCTAssertEqual(reconciledDuel.localPlayer?.ammo, 7)
    XCTAssertEqual(reconciledDuel.opponent?.health, 66)
  }

  func testConfirmedDebugFireRearmsForAnotherAuthoritativeShot() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotID: "next-shot-id")
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "next-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-one",
          rejectReason: nil
        )
      )
    ]
    await store.performDebugFire()
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent(id: "event-one", health: 66)]
      )
    )
    await settle()

    XCTAssertTrue(store.canDebugFire)
    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "next-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 6,
          targetHealth: 32,
          eventId: "event-two",
          rejectReason: nil
        )
      )
    ]
    await store.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["next-shot-id", "next-shot-id"])
    XCTAssertEqual(store.debugShotState, .pending)
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 6,
        guestHealth: 32,
        events: [hitEvent(id: "event-two", health: 32)]
      )
    )
    await settle()
    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
  }

  func testHealthyQuietSubscriptionDoesNotExpireNetworkFreshness() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    XCTAssertTrue(store.isNetworkFresh(at: Date(timeIntervalSince1970: 1_750_003_600)))
    client.sendConnection(.connecting)
    await settle()
    XCTAssertFalse(store.isNetworkFresh(at: Date(timeIntervalSince1970: 1_750_003_600)))
  }

  func testReconnectStaysLockedUntilFreshSnapshotReplacesState() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, guestHealth: 100))
    await settle()

    client.sendConnection(.connecting)
    await settle()
    XCTAssertEqual(store.syncStatus, .stale)
    XCTAssertTrue(store.isMatchInputLocked)
    XCTAssertFalse(store.canDebugFire)

    client.sendConnection(.connected)
    await settle()
    XCTAssertEqual(store.syncStatus, .stale, "Transport alone must not unlock mutations")

    client.send(snapshot(phase: .running, guestHealth: 66))
    await settle()
    XCTAssertEqual(store.syncStatus, .restored)
    XCTAssertFalse(store.isMatchInputLocked)
    guard case .active(let recoveredDuel) = store.route else {
      return XCTFail("Expected recovered active duel")
    }
    XCTAssertEqual(recoveredDuel.opponent?.health, 66)
  }

  private func makeStore(client: MockGameSessionClient, shotID: String = "unused-shot-id") -> LobbyStore {
    LobbyStore(
      environment: AppEnvironment(
        gameSessionClient: client,
        targetingSession: UnavailableTargetingSession()
      ),
      now: { Date(timeIntervalSince1970: 1_750_000_000) },
      makeShotId: { shotID }
    )
  }

  private func snapshot(
    phase: MatchPhase,
    hostReady: Bool = true,
    hostAmmo: Int = 8,
    guestHealth: Int = 100,
    events: [EventSnapshot] = []
  ) -> MatchSnapshot {
    MatchSnapshot(
      serverNow: 1_750_000_000_000,
      match: MatchSummary(
        id: "match-1",
        code: "ABC123",
        phase: phase,
        durationMs: 180_000,
        startsAt: phase == .countdown ? 1_750_000_003_000 : nil,
        endsAt: phase == .running ? 1_750_000_180_000 : nil
      ),
      localPlayerId: "host-1",
      players: [
        PlayerSnapshot(
          id: "host-1",
          displayName: "Host",
          role: .host,
          ready: hostReady,
          connected: true,
          health: 100,
          ammo: hostAmmo
        ),
        PlayerSnapshot(
          id: "guest-1",
          displayName: "Guest",
          role: .guest,
          ready: true,
          connected: true,
          health: guestHealth,
          ammo: 8
        ),
      ],
      events: events
    )
  }

  private var hitEvent: EventSnapshot {
    hitEvent(id: "event-hit", health: 66)
  }

  private func hitEvent(id: String, health: Int) -> EventSnapshot {
    EventSnapshot(
      id: id,
      type: .hit,
      message: "Host hit Guest • \(health) health",
      createdAt: 1_750_000_010_000,
      actorPlayerId: "host-1",
      targetPlayerId: "guest-1",
      zone: "torso",
      damage: 34
    )
  }

  private func settle() async {
    for _ in 0..<10 { await Task.yield() }
  }
}

private final class MockGameSessionClient: GameSessionClient, @unchecked Sendable {
  let availability = GameSessionAvailability.available
  let playerSession: PlayerSession

  private let lock = NSLock()
  private let snapshotStream: AsyncThrowingStream<MatchSnapshot, Error>
  private let snapshotContinuation: AsyncThrowingStream<MatchSnapshot, Error>.Continuation
  private let connectionStream: AsyncStream<GameSessionConnectionState>
  private let connectionContinuation: AsyncStream<GameSessionConnectionState>.Continuation
  private var storedCreateRequests: [CreateDuelRequest] = []
  private var storedReadyValues: [Bool] = []
  private var storedDebugShotIDs: [String] = []
  private var storedDebugResults: [Result<DebugFireResult, Error>] = []

  init() {
    playerSession = PlayerSession(
      matchId: "match-1",
      code: "ABC123",
      playerId: "host-1",
      sessionSecret: UUID().uuidString
    )
    (snapshotStream, snapshotContinuation) = AsyncThrowingStream.makeStream()
    (connectionStream, connectionContinuation) = AsyncStream.makeStream()
  }

  var createRequests: [CreateDuelRequest] {
    lock.withLock { storedCreateRequests }
  }

  var readyValues: [Bool] {
    lock.withLock { storedReadyValues }
  }

  var debugShotIDs: [String] {
    lock.withLock { storedDebugShotIDs }
  }

  var debugResults: [Result<DebugFireResult, Error>] {
    get { lock.withLock { storedDebugResults } }
    set { lock.withLock { storedDebugResults = newValue } }
  }

  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {
    lock.withLock { storedCreateRequests.append(request) }
    return playerSession
  }

  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {
    playerSession
  }

  func setReady(session: PlayerSession, isReady: Bool) async throws {
    lock.withLock { storedReadyValues.append(isReady) }
  }

  func startDuel(session: PlayerSession) async throws {}

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    try lock.withLock {
      storedDebugShotIDs.append(clientShotId)
      guard !storedDebugResults.isEmpty else { throw GameSessionClientError.unknown }
      return try storedDebugResults.removeFirst().get()
    }
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    snapshotStream
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> {
    connectionStream
  }

  func send(_ snapshot: MatchSnapshot) {
    snapshotContinuation.yield(snapshot)
  }

  func sendConnection(_ state: GameSessionConnectionState) {
    connectionContinuation.yield(state)
  }
}
