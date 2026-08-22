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
    XCTAssertEqual(ConvexGameSessionContract.fire, "shots:fire")
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
    XCTAssertEqual(
      client.createRequests, [CreateDuelRequest(displayName: "Host", arenaRadiusMeters: 30)])
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
    XCTAssertFalse(
      unchangedRoom.localPlayer?.isReady ?? true, "Mutation must not update UI optimistically")

    client.send(snapshot(phase: .lobby, hostReady: true))
    await settle()
    guard case .waiting(let updatedRoom) = store.route else {
      return XCTFail("Expected updated waiting room")
    }
    XCTAssertTrue(updatedRoom.localPlayer?.isReady ?? false)
  }

  func testDebugFireReusesIDAndWaitsForAuthoritativeHealthAndAmmo() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotIDs: ["stable-shot-id"])
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
    XCTAssertTrue(store.canDebugFire, "A confirmed fallback shot must allow the next shot")
    guard case .active(let reconciledDuel) = store.route else {
      return XCTFail("Expected active duel")
    }
    XCTAssertEqual(reconciledDuel.localPlayer?.ammo, 7)
    XCTAssertEqual(reconciledDuel.opponent?.health, 66)
  }

  func testDebugFireAfterConfirmationUsesNewClientShotID() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotIDs: ["first-shot-id", "second-shot-id"])
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "first-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "second-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 6,
          targetHealth: 32,
          eventId: nil,
          rejectReason: nil
        )
      ),
    ]

    await store.performDebugFire()
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

    await store.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["first-shot-id", "second-shot-id"])
    XCTAssertEqual(store.debugShotState, .pending)
  }

  func testDebugFireAfterDefinitiveRejectionUsesNewClientShotID() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotIDs: ["rejected-shot-id", "next-shot-id"])
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: false,
          outcome: .rejected,
          clientShotId: "rejected-shot-id",
          replayed: false,
          damage: 0,
          shooterAmmo: 8,
          targetHealth: 100,
          eventId: nil,
          rejectReason: .connectionStale
        )
      ),
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "next-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: nil,
          rejectReason: nil
        )
      ),
    ]

    await store.performDebugFire()
    XCTAssertEqual(store.debugShotState, .failed)

    await store.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["rejected-shot-id", "next-shot-id"])
    XCTAssertEqual(store.debugShotState, .pending)
  }

  func testMarkerlessTransportFailureRetriesExactRequest() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let targetingSession = FixedTargetingSession(snapshot: aimedSnapshot(at: firedAt))
    let store = makeStore(
      client: client,
      targetingSession: targetingSession,
      shotIDs: ["markerless-shot-id", "unexpected-new-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.fireResults = [
      .failure(GameSessionClientError.networkUnavailable),
      .success(
        FireShotResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "markerless-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          targetLifeState: .alive,
          eventId: "markerless-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.performMarkerlessFire()
    XCTAssertEqual(store.markerlessShotState, .failed(reason: nil))
    XCTAssertEqual(client.fireRequests.count, 1)

    clock.now = firedAt.addingTimeInterval(5)
    await store.performMarkerlessFire()

    XCTAssertEqual(client.fireRequests.count, 2)
    XCTAssertEqual(client.fireRequests[0], client.fireRequests[1])
    XCTAssertEqual(
      client.fireRequests.map(\.clientShotId), ["markerless-shot-id", "markerless-shot-id"])
    XCTAssertEqual(
      store.markerlessShotState,
      .confirmed(outcome: .hit, zone: .torso, damage: 34)
    )
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

  private func makeStore(
    client: MockGameSessionClient,
    targetingSession: any TargetingSession = UnavailableTargetingSession(),
    shotIDs: [String] = ["unused-shot-id"],
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_750_000_000) }
  ) -> LobbyStore {
    let shotIDSequence = ShotIDSequence(shotIDs)
    return LobbyStore(
      environment: AppEnvironment(
        gameSessionClient: client,
        targetingSession: targetingSession
      ),
      now: now,
      makeShotId: { shotIDSequence.next() }
    )
  }

  private func aimedSnapshot(at date: Date) -> TargetingSnapshot {
    TargetingSnapshot(
      state: .torsoLock,
      bodyDetected: true,
      torsoDetected: true,
      confidence: 0.88,
      observedAt: date,
      poseObservedAt: date,
      bodyBounds: nil,
      torsoBounds: nil,
      headRegion: nil,
      torsoRegion: nil,
      aimClaim: TargetingAimClaim(zone: .torso, confidence: 0.82, capturedAt: date),
      cameraRay: TargetingCameraRay(
        origin: TargetingVector3(x: 1, y: 2, z: 3),
        direction: TargetingVector3(x: 0, y: 0, z: -1),
        capturedAt: date
      ),
      poseStaleAfter: 0.5
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
    EventSnapshot(
      id: "event-hit",
      type: .hit,
      message: "Host hit Guest",
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
  private var storedFireRequests: [FireShotRequest] = []
  private var storedFireResults: [Result<FireShotResult, Error>] = []
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

  var fireRequests: [FireShotRequest] {
    lock.withLock { storedFireRequests }
  }

  var fireResults: [Result<FireShotResult, Error>] {
    get { lock.withLock { storedFireResults } }
    set { lock.withLock { storedFireResults = newValue } }
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

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    try lock.withLock {
      storedFireRequests.append(request)
      guard !storedFireResults.isEmpty else { throw GameSessionClientError.unknown }
      return try storedFireResults.removeFirst().get()
    }
  }

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

private struct FixedTargetingSession: TargetingSession {
  let availability = TargetingAvailability.available
  let currentSnapshot: TargetingSnapshot

  init(snapshot: TargetingSnapshot) {
    currentSnapshot = snapshot
  }

  func snapshots() -> AsyncStream<TargetingSnapshot> {
    AsyncStream { continuation in
      continuation.yield(currentSnapshot)
      continuation.finish()
    }
  }

  func start() async throws {}

  func stop() async {}
}

private final class ShotIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  func next() -> String {
    lock.withLock {
      guard !values.isEmpty else { return "unexpected-shot-id" }
      return values.removeFirst()
    }
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedNow: Date

  init(_ now: Date) {
    storedNow = now
  }

  var now: Date {
    get { lock.withLock { storedNow } }
    set { lock.withLock { storedNow = newValue } }
  }
}
