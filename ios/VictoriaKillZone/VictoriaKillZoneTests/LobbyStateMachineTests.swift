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

    await store.duel.performDebugFire()
    XCTAssertEqual(store.duel.debugShotState, .failed)
    await store.duel.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["stable-shot-id", "stable-shot-id"])
    XCTAssertEqual(store.duel.debugShotState, .pending)
    await store.duel.performDebugFire()
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

    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))
    XCTAssertTrue(store.duel.canDebugFire, "A confirmed fallback shot must allow the next shot")
    guard case .active(let reconciledDuel) = store.route else {
      return XCTFail("Expected active duel")
    }
    XCTAssertEqual(reconciledDuel.localPlayer?.ammo, 7)
    XCTAssertEqual(reconciledDuel.opponent?.health, 66)
  }

  func testDebugFireOrdinaryFirstShotStaysPendingThenConfirmsFromAuthoritativeEvent() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotIDs: ["ordinary-first-shot-id"])
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "ordinary-first-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .pending)
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.duel.canDebugFire)
    XCTAssertEqual(client.debugShotIDs, ["ordinary-first-shot-id"])

    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent]
      )
    )
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))
    XCTAssertEqual(client.debugShotIDs, ["ordinary-first-shot-id"])
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

    await store.duel.performDebugFire()
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent]
      )
    )
    await settle()
    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))

    await store.duel.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["first-shot-id", "second-shot-id"])
    XCTAssertEqual(store.duel.debugShotState, .pending)
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

    await store.duel.performDebugFire()
    XCTAssertEqual(store.duel.debugShotState, .failed)

    await store.duel.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["rejected-shot-id", "next-shot-id"])
    XCTAssertEqual(store.duel.debugShotState, .pending)
  }

  func testDebugFireAgedOutEventReplaysAndConfirmsWithSameClientShotID() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["aged-out-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 100))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "aged-out-shot-id",
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
          clientShotId: "aged-out-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: agedOutEvents()
      )
    )
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))
    XCTAssertTrue(store.duel.canDebugFire)
    XCTAssertEqual(client.debugShotIDs, ["aged-out-shot-id", "aged-out-shot-id"])
  }

  func testDebugFireAgedOutReplayDoesNotStormAndNextPressUsesNewClientShotID() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["aged-out-shot-id", "next-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "aged-out-shot-id",
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
          clientShotId: "aged-out-shot-id",
          replayed: true,
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
          clientShotId: "next-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 6,
          targetHealth: 32,
          eventId: nil,
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    for _ in 0..<3 {
      client.send(snapshot(phase: .running, events: agedOutEvents()))
      await settle()
    }
    XCTAssertEqual(client.debugShotIDs, ["aged-out-shot-id", "aged-out-shot-id"])

    await store.duel.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["aged-out-shot-id", "aged-out-shot-id", "next-shot-id"])
    XCTAssertEqual(store.duel.debugShotState, .pending)
  }

  func testDebugFireAgedOutReplayWaitsUntilConfirmationBudgetExpires() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["budget-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "budget-shot-id",
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
          clientShotId: "budget-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(2)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .pending)
    XCTAssertEqual(client.debugShotIDs, ["budget-shot-id"])
  }

  func testDebugFireAgedOutReplayRejectionFailsAndClearsPendingShot() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["rejected-replay-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "rejected-replay-shot-id",
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
          accepted: false,
          outcome: .rejected,
          clientShotId: "rejected-replay-shot-id",
          replayed: true,
          damage: 0,
          shooterAmmo: 8,
          targetHealth: 100,
          eventId: nil,
          rejectReason: .connectionStale
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .failed)
    XCTAssertEqual(store.errorMessage, "SHOT LOCKED WHILE RECONNECTING")
    XCTAssertEqual(client.debugShotIDs, ["rejected-replay-shot-id", "rejected-replay-shot-id"])
  }

  func testDebugFireNonIdempotentReplayFailsAndManualRetryReusesPendingShotID() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["non-idempotent-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "non-idempotent-shot-id",
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
          clientShotId: "non-idempotent-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .failed)
    XCTAssertEqual(client.debugShotIDs, ["non-idempotent-shot-id", "non-idempotent-shot-id"])

    await store.duel.performDebugFire()

    XCTAssertEqual(
      client.debugShotIDs,
      ["non-idempotent-shot-id", "non-idempotent-shot-id", "non-idempotent-shot-id"]
    )
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent]
      )
    )
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))
  }

  func testDebugFireReplayTransportFailureReusesPendingShotIDOnManualRetry() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["transport-retry-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "transport-retry-shot-id",
          replayed: false,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
      .failure(GameSessionClientError.networkUnavailable),
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "transport-retry-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]

    await store.duel.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .failed)
    XCTAssertEqual(
      client.debugShotIDs,
      ["transport-retry-shot-id", "transport-retry-shot-id"]
    )

    await store.duel.performDebugFire()

    XCTAssertEqual(
      client.debugShotIDs,
      ["transport-retry-shot-id", "transport-retry-shot-id", "transport-retry-shot-id"]
    )
    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 66,
        events: [hitEvent]
      )
    )
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .confirmed(damage: 34))
  }

  func testDebugFireReplayResultAfterLeaveDoesNotBleedIntoNewState() async throws {
    let firedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let clock = TestClock(firedAt)
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      shotIDs: ["stale-replay-shot-id"],
      now: { clock.now }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "stale-replay-shot-id",
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
          clientShotId: "stale-replay-shot-id",
          replayed: true,
          damage: 34,
          shooterAmmo: 7,
          targetHealth: 66,
          eventId: "event-hit",
          rejectReason: nil
        )
      ),
    ]
    await store.duel.performDebugFire()
    let gate = client.gateNextDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await gate.waitUntilEntered()

    store.leave()
    gate.release()
    await settle()

    XCTAssertEqual(store.duel.debugShotState, .idle)
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.duel.canDebugFire)
    XCTAssertEqual(client.debugShotIDs, ["stale-replay-shot-id", "stale-replay-shot-id"])
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

    await store.duel.performMarkerlessFire()
    XCTAssertEqual(store.duel.markerlessShotState, .failed(reason: nil))
    XCTAssertEqual(client.fireRequests.count, 1)

    clock.now = firedAt.addingTimeInterval(5)
    await store.duel.performMarkerlessFire()

    XCTAssertEqual(client.fireRequests.count, 2)
    XCTAssertEqual(client.fireRequests[0], client.fireRequests[1])
    XCTAssertEqual(
      client.fireRequests.map(\.clientShotId), ["markerless-shot-id", "markerless-shot-id"])
    XCTAssertEqual(
      store.duel.markerlessShotState,
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
    XCTAssertFalse(store.duel.canDebugFire)

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

  func testSnapshotSubscriptionRetriesAfterDrop() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, guestHealth: 100))
    await settle()

    client.failSnapshotSubscription()
    await settle()
    XCTAssertEqual(store.syncStatus, .stale)
    XCTAssertTrue(store.isMatchInputLocked)

    try await Task.sleep(for: .seconds(1.1))
    await settle()
    XCTAssertEqual(client.snapshotSubscriptionCount, 2)

    client.send(snapshot(phase: .running, guestHealth: 66))
    await settle()
    XCTAssertEqual(store.syncStatus, .restored)
    XCTAssertFalse(store.isMatchInputLocked)
  }

  func testDebugFireKillConfirmsWhenResubscribedSnapshotAlreadyShowsRespawn() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client, shotIDs: ["kill-shot-id"])
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running, hostAmmo: 8, guestHealth: 32))
    await settle()

    client.debugResults = [
      .success(
        DebugFireResult(
          accepted: true,
          outcome: .hit,
          clientShotId: "kill-shot-id",
          replayed: false,
          damage: 32,
          shooterAmmo: 7,
          targetHealth: 0,
          eventId: "event-kill",
          rejectReason: nil
        )
      )
    ]

    await store.duel.performDebugFire()
    XCTAssertEqual(store.duel.debugShotState, .pending)

    client.failSnapshotSubscription()
    await settle()
    try await Task.sleep(for: .seconds(1.1))
    await settle()
    XCTAssertEqual(client.snapshotSubscriptionCount, 2)

    client.send(
      snapshot(
        phase: .running,
        hostAmmo: 7,
        guestHealth: 100,
        events: [
          EventSnapshot(
            id: "event-kill",
            type: .hit,
            message: "Host HIT Guest • TORSO −32",
            createdAt: 1_750_000_020_000,
            actorPlayerId: "host-1",
            targetPlayerId: "guest-1",
            zone: "torso",
            damage: 32
          )
        ]
      )
    )
    await settle()

    XCTAssertEqual(
      store.duel.debugShotState, .confirmed(damage: 32),
      "A snapshot containing the shot's own event must confirm the shot even when the transient post-shot state was never observed"
    )
    XCTAssertTrue(store.duel.canDebugFire)
  }

  func testLocalKillSnapshotShowsKillBanner() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.send(
      snapshot(
        phase: .running,
        events: [eliminatedEvent(actorPlayerID: "host-1", targetPlayerID: "guest-1")]
      )
    )
    await settle()

    XCTAssertEqual(store.duel.killBanner?.text, "YOU ELIMINATED Guest")
    XCTAssertTrue(store.duel.killBanner?.isLocalKill == true)
  }

  func testOpponentKillSnapshotShowsEliminatedByBanner() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.send(
      snapshot(
        phase: .running,
        events: [eliminatedEvent(actorPlayerID: "guest-1", targetPlayerID: "host-1")]
      )
    )
    await settle()

    XCTAssertEqual(store.duel.killBanner?.text, "ELIMINATED BY Guest")
    XCTAssertFalse(store.duel.killBanner?.isLocalKill == true)
  }

  func testDuplicateKillEventDoesNotRetriggerBanner() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    let event = eliminatedEvent(actorPlayerID: "host-1", targetPlayerID: "guest-1")
    client.send(snapshot(phase: .running, events: [event]))
    await settle()
    let firstBanner = try XCTUnwrap(store.duel.killBanner)

    client.send(snapshot(phase: .running, events: [event]))
    await settle()

    XCTAssertEqual(store.duel.killBanner, firstBanner)
  }

  func testOpponentShotAndHitPublishIncomingShotsButOwnEventsDoNot() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(client: client)
    store.displayName = "Host"
    await store.performCreateDuel()
    client.send(snapshot(phase: .running))
    await settle()

    client.send(
      snapshot(
        phase: .running,
        events: [
          EventSnapshot(
            id: "opponent-shot",
            type: .shot,
            message: "Guest fired",
            createdAt: 1_750_000_000_100,
            actorPlayerId: "guest-1",
            targetPlayerId: "host-1",
            zone: "head",
            damage: nil
          ),
          EventSnapshot(
            id: "own-shot",
            type: .shot,
            message: "Host fired",
            createdAt: 1_750_000_000_101,
            actorPlayerId: "host-1",
            targetPlayerId: "guest-1",
            zone: "torso",
            damage: nil
          ),
        ]
      )
    )
    await settle()
    XCTAssertEqual(
      store.duel.incomingShot,
      IncomingShot(
        eventID: "opponent-shot",
        hit: false,
        zone: "head",
        timestamp: 1_750_000_000_100,
        source: .convex
      )
    )

    client.send(
      snapshot(
        phase: .running,
        events: [
          EventSnapshot(
            id: "opponent-hit",
            type: .hit,
            message: "Guest hit Host",
            createdAt: 1_750_000_000_200,
            actorPlayerId: "guest-1",
            targetPlayerId: "host-1",
            zone: "torso",
            damage: 34
          )
        ]
      )
    )
    await settle()
    XCTAssertEqual(store.duel.incomingShot?.eventID, "opponent-hit")
    XCTAssertTrue(store.duel.incomingShot?.hit == true)
  }

  func testKillBannerUsesFirstSnapshotServerClock() async throws {
    let client = MockGameSessionClient()
    let store = makeStore(
      client: client,
      now: { Date(timeIntervalSince1970: 2_000_000_000) }
    )
    store.displayName = "Host"
    await store.performCreateDuel()
    let firstServerNow = 1_750_000_000_000.0
    client.send(snapshot(phase: .running, serverNow: firstServerNow))
    await settle()

    let event = eliminatedEvent(
      actorPlayerID: "host-1",
      targetPlayerID: "guest-1",
      createdAt: firstServerNow + 100
    )
    client.send(
      snapshot(
        phase: .running,
        events: [event],
        serverNow: firstServerNow + 1_000
      )
    )
    await settle()

    XCTAssertEqual(store.duel.killBanner?.text, "YOU ELIMINATED Guest")
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
    events: [EventSnapshot] = [],
    serverNow: Double = 1_750_000_000_000
  ) -> MatchSnapshot {
    MatchSnapshot(
      serverNow: serverNow,
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

  private func agedOutEvents() -> [EventSnapshot] {
    (0..<40).map { index in
      EventSnapshot(
        id: "newer-event-\(index)",
        type: .hit,
        message: "Newer event",
        createdAt: 1_750_000_020_000 + Double(index),
        actorPlayerId: "guest-1",
        targetPlayerId: "host-1",
        zone: "torso",
        damage: 1
      )
    }
  }

  private func eliminatedEvent(
    actorPlayerID: String?,
    targetPlayerID: String?,
    createdAt: Double = 1_750_000_010_000
  ) -> EventSnapshot {
    EventSnapshot(
      id: "event-eliminated",
      type: .eliminated,
      message: "Host eliminated Guest",
      createdAt: createdAt,
      actorPlayerId: actorPlayerID,
      targetPlayerId: targetPlayerID,
      zone: nil,
      damage: 100
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
  private var retrySnapshotContinuations:
    [AsyncThrowingStream<MatchSnapshot, Error>.Continuation] = []
  private var storedSnapshotSubscriptionCount = 0
  private let connectionStream: AsyncStream<GameSessionConnectionState>
  private let connectionContinuation: AsyncStream<GameSessionConnectionState>.Continuation
  private var storedCreateRequests: [CreateDuelRequest] = []
  private var storedReadyValues: [Bool] = []
  private var storedFireRequests: [FireShotRequest] = []
  private var storedFireResults: [Result<FireShotResult, Error>] = []
  private var storedDebugShotIDs: [String] = []
  private var storedDebugResults: [Result<DebugFireResult, Error>] = []
  private var storedDebugFireGate: DebugFireGate?

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

  var snapshotSubscriptionCount: Int {
    lock.withLock { storedSnapshotSubscriptionCount }
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

  func gateNextDebugFire() -> DebugFireGate {
    let gate = DebugFireGate()
    lock.withLock { storedDebugFireGate = gate }
    return gate
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
    let response: Result<DebugFireResult, Error>
    let gate: DebugFireGate?
    (response, gate) = try lock.withLock {
      storedDebugShotIDs.append(clientShotId)
      guard !storedDebugResults.isEmpty else {
        throw GameSessionClientError.unknown
      }
      let response = storedDebugResults.removeFirst()
      let gate = storedDebugFireGate
      storedDebugFireGate = nil
      return (response, gate)
    }
    if let gate {
      gate.enter()
      await gate.waitForRelease()
    }
    return try response.get()
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    lock.withLock {
      storedSnapshotSubscriptionCount += 1
      guard storedSnapshotSubscriptionCount > 1 else { return snapshotStream }
      let (stream, continuation) = AsyncThrowingStream<MatchSnapshot, Error>.makeStream()
      retrySnapshotContinuations.append(continuation)
      return stream
    }
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> {
    connectionStream
  }

  func send(_ snapshot: MatchSnapshot) {
    snapshotContinuation.yield(snapshot)
    lock.withLock {
      retrySnapshotContinuations.forEach { $0.yield(snapshot) }
    }
  }

  func failSnapshotSubscription() {
    snapshotContinuation.finish(throwing: GameSessionClientError.networkUnavailable)
  }

  func sendConnection(_ state: GameSessionConnectionState) {
    connectionContinuation.yield(state)
  }
}

private final class DebugFireGate: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  private var released = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitUntilEntered() async {
    await withCheckedContinuation { continuation in
      let alreadyEntered = lock.withLock {
        if !entered {
          enteredContinuation = continuation
        }
        return entered
      }
      if alreadyEntered {
        continuation.resume()
      }
    }
  }

  func enter() {
    let continuation = lock.withLock {
      entered = true
      let continuation = enteredContinuation
      enteredContinuation = nil
      return continuation
    }
    continuation?.resume()
  }

  func waitForRelease() async {
    await withCheckedContinuation { continuation in
      let alreadyReleased = lock.withLock {
        if !released {
          releaseContinuation = continuation
        }
        return released
      }
      if alreadyReleased {
        continuation.resume()
      }
    }
  }

  func release() {
    let continuation = lock.withLock {
      released = true
      let continuation = releaseContinuation
      releaseContinuation = nil
      return continuation
    }
    continuation?.resume()
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

// MARK: - KIL-36 two-client convergence harness

private enum HarnessRole: String {
  case host
  case guest

  var playerID: String {
    switch self {
    case .host: MatchAuthority.hostPlayerID
    case .guest: MatchAuthority.guestPlayerID
    }
  }

  var displayName: String {
    switch self {
    case .host: "Host"
    case .guest: "Guest"
    }
  }

  var opponent: HarnessRole {
    switch self {
    case .host: .guest
    case .guest: .host
    }
  }
}

private struct HarnessPlayer {
  let id: String
  let displayName: String
  let role: PlayerRole
  var ready = false
  var connected = true
  var health = MatchAuthority.startingHealth
  var ammo = MatchAuthority.magazineSize
  var kills = 0
  var deaths = 0
  var lifeState = PlayerLifeState.alive
  var respawnAt: Double?
  var lastShotAt: Double?
}

/// Deterministic in-process authoritative match shared by two independent
/// `LobbyStore` clients. Shot resolution, respawn scheduling, idempotency and
/// the recent-event window mirror `convex/domain/fire.ts`,
/// `convex/domain/respawn.ts` and `convex/functions/shots.ts`, so both clients
/// observe exactly one authoritative history under a controlled clock.
private final class MatchAuthority: @unchecked Sendable {
  static let matchID = "match-1"
  static let matchCode = "ABC123"
  static let hostPlayerID = "host-1"
  static let guestPlayerID = "guest-1"
  static let startingHealth = 100
  static let magazineSize = 8
  static let fireCooldownMs: Double = 350
  static let respawnDelayMs: Double = 5_000
  static let recentEventLimit = 40
  static let matchDurationMs = 180_000

  enum FireMode {
    case debug
    case markerless
  }

  private struct StoredShot {
    let outcome: FireShotOutcome
    let accepted: Bool
    let damage: Int
    let shooterAmmo: Int
    let targetHealth: Int?
    let targetLifeState: PlayerLifeState?
    let eventID: String?
    let fireRejectReason: FireRejectReason?
    let debugRejectReason: BackendErrorCode?
  }

  private struct ClientChannel {
    var continuations: [AsyncThrowingStream<MatchSnapshot, Error>.Continuation] = []
    var subscriptionCount = 0
    var deliveryEnabled = true
    var withheldSnapshots: [MatchSnapshot] = []
  }

  private let lock = NSLock()
  private let clock: TestClock
  private var phase = MatchPhase.lobby
  private var startsAt: Double?
  private var endsAt: Double?
  private var players: [HarnessPlayer]
  private var events: [EventSnapshot] = []
  private var shots: [String: StoredShot] = [:]
  private var nextEventNumber = 1
  private var channels: [String: ClientChannel] = [:]
  private var storedTimeline: [String] = []
  private let startedAtMs: Double

  init(clock: TestClock) {
    self.clock = clock
    startedAtMs = clock.now.timeIntervalSince1970 * 1_000
    players = [
      HarnessPlayer(id: Self.hostPlayerID, displayName: "Host", role: .host),
      HarnessPlayer(id: Self.guestPlayerID, displayName: "Guest", role: .guest),
    ]
  }

  var nowMs: Double {
    clock.now.timeIntervalSince1970 * 1_000
  }

  var timeline: [String] {
    lock.withLock { storedTimeline }
  }

  func record(_ line: String) {
    let offset = Int((nowMs - startedAtMs).rounded())
    lock.withLock { storedTimeline.append("t=+\(offset)ms \(line)") }
  }

  func player(_ role: HarnessRole) -> HarnessPlayer {
    lock.withLock { players.first(where: { $0.id == role.playerID })! }
  }

  func subscriptionCount(for role: HarnessRole) -> Int {
    lock.withLock { channels[role.playerID]?.subscriptionCount ?? 0 }
  }

  // MARK: Lifecycle

  func markReady(_ role: HarnessRole) {
    lock.withLock {
      guard let index = players.firstIndex(where: { $0.id == role.playerID }) else { return }
      players[index].ready = true
      _ = appendEventLocked(
        type: .ready,
        actorPlayerID: role.playerID,
        targetPlayerID: nil,
        zone: nil,
        damage: nil,
        message: "\(role.displayName) READY"
      )
    }
    record("server phase=lobby \(role.rawValue) marked ready")
  }

  func startMatch() {
    lock.withLock {
      phase = .running
      startsAt = nowMs
      endsAt = nowMs + Double(Self.matchDurationMs)
      _ = appendEventLocked(
        type: .started,
        actorPlayerID: nil,
        targetPlayerID: nil,
        zone: nil,
        damage: nil,
        message: "DUEL STARTED"
      )
    }
    record("server phase=running match started")
  }

  /// Advances the shared clock and runs every respawn whose scheduled time has
  /// passed, exactly like the server-side scheduled `players:respawn`.
  func advance(milliseconds: Double) {
    clock.now = clock.now.addingTimeInterval(milliseconds / 1_000)
    let respawned: [String] = lock.withLock {
      var names: [String] = []
      let now = nowMs
      for index in players.indices {
        guard phase == .running, players[index].lifeState == .respawning,
          let respawnAt = players[index].respawnAt, now >= respawnAt
        else {
          continue
        }
        players[index].health = Self.startingHealth
        players[index].ammo = Self.magazineSize
        players[index].lifeState = .alive
        players[index].respawnAt = nil
        players[index].lastShotAt = nil
        _ = appendEventLocked(
          type: .respawned,
          actorPlayerID: players[index].id,
          targetPlayerID: nil,
          zone: nil,
          damage: nil,
          message: "\(players[index].displayName) RESPAWNED"
        )
        names.append(players[index].displayName)
      }
      return names
    }
    for name in respawned {
      record("server respawn applied player=\(name) health=100 ammo=8 life=alive")
    }
  }

  // MARK: Shot resolution

  func debugFire(shooterID: String, clientShotID: String) -> DebugFireResult {
    let (stored, replayed) = resolve(
      shooterID: shooterID,
      clientShotID: clientShotID,
      zone: .torso,
      poseConfidence: 1,
      mode: .debug
    )
    let fallbackHealth = lock.withLock {
      players.first(where: { $0.id != shooterID })?.health ?? Self.startingHealth
    }
    return DebugFireResult(
      accepted: stored.accepted,
      outcome: stored.accepted ? .hit : .rejected,
      clientShotId: clientShotID,
      replayed: replayed,
      damage: stored.damage,
      shooterAmmo: stored.shooterAmmo,
      targetHealth: stored.targetHealth ?? fallbackHealth,
      eventId: stored.eventID,
      rejectReason: stored.debugRejectReason
    )
  }

  func fire(shooterID: String, request: FireShotRequest) -> FireShotResult {
    let validTarget =
      request.targetId != nil && request.zone != nil && request.poseConfidence != nil
    guard validTarget, let zone = request.zone, let confidence = request.poseConfidence else {
      return FireShotResult(
        accepted: false,
        outcome: .rejected,
        clientShotId: request.clientShotId,
        replayed: false,
        damage: 0,
        shooterAmmo: player(shooterID == Self.hostPlayerID ? .host : .guest).ammo,
        targetHealth: nil,
        targetLifeState: nil,
        eventId: nil,
        rejectReason: .invalidTarget
      )
    }
    let (stored, replayed) = resolve(
      shooterID: shooterID,
      clientShotID: request.clientShotId,
      zone: zone,
      poseConfidence: confidence,
      mode: .markerless,
      claimedTargetID: request.targetId
    )
    return FireShotResult(
      accepted: stored.accepted,
      outcome: stored.outcome,
      clientShotId: request.clientShotId,
      replayed: replayed,
      damage: stored.damage,
      shooterAmmo: stored.shooterAmmo,
      targetHealth: stored.targetHealth,
      targetLifeState: stored.targetLifeState,
      eventId: stored.eventID,
      rejectReason: stored.fireRejectReason
    )
  }

  private func resolve(
    shooterID: String,
    clientShotID: String,
    zone: HitZone,
    poseConfidence: Double,
    mode: FireMode,
    claimedTargetID: String? = nil
  ) -> (StoredShot, Bool) {
    let outcome: (StoredShot, Bool) = lock.withLock {
      let key = "\(shooterID)#\(clientShotID)"
      if let existing = shots[key] {
        return (existing, true)
      }

      let now = nowMs
      guard let shooterIndex = players.firstIndex(where: { $0.id == shooterID }) else {
        return (rejection(reason: .invalidTarget, shooterAmmo: 0), false)
      }
      let shooter = players[shooterIndex]
      let targetIndex = players.firstIndex(where: { $0.id != shooterID })

      func store(_ shot: StoredShot) -> (StoredShot, Bool) {
        shots[key] = shot
        return (shot, false)
      }

      guard phase == .running else {
        return store(rejection(reason: .matchNotRunning, shooterAmmo: shooter.ammo))
      }
      guard shooter.connected else {
        return store(rejection(reason: .connectionStale, shooterAmmo: shooter.ammo))
      }
      guard shooter.lifeState == .alive else {
        return store(rejection(reason: .shooterNotAlive, shooterAmmo: shooter.ammo))
      }
      guard shooter.ammo > 0 else {
        return store(rejection(reason: .outOfAmmo, shooterAmmo: shooter.ammo))
      }
      if let lastShotAt = shooter.lastShotAt, now - lastShotAt < Self.fireCooldownMs {
        return store(rejection(reason: .fireCooldown, shooterAmmo: shooter.ammo))
      }
      let minimumConfidence = zone == .head ? 0.60 : 0.45
      guard poseConfidence >= minimumConfidence else {
        return store(rejection(reason: .invalidTarget, shooterAmmo: shooter.ammo))
      }
      guard let targetIndex,
        claimedTargetID == nil || claimedTargetID == players[targetIndex].id
      else {
        return store(rejection(reason: .invalidTarget, shooterAmmo: shooter.ammo))
      }
      guard players[targetIndex].lifeState == .alive else {
        return store(rejection(reason: .targetNotAlive, shooterAmmo: shooter.ammo))
      }

      let target = players[targetIndex]
      let damage = min(Self.damage(for: zone), target.health)
      let remainingHealth = max(0, target.health - damage)
      let eliminated = remainingHealth == 0

      players[shooterIndex].ammo = max(0, shooter.ammo - 1)
      players[shooterIndex].lastShotAt = now
      players[shooterIndex].kills = shooter.kills + (eliminated ? 1 : 0)
      players[targetIndex].health = remainingHealth
      players[targetIndex].lifeState = eliminated ? .respawning : .alive
      if eliminated {
        players[targetIndex].deaths = target.deaths + 1
        players[targetIndex].respawnAt = now + Self.respawnDelayMs
      }

      // `shots:debugFire` always persists a G2 `hit` event, even for a kill.
      let eventType: MatchEventType = mode == .debug ? .hit : (eliminated ? .eliminated : .hit)
      let message: String
      if mode == .debug {
        message =
          "\(shooter.displayName) HIT \(target.displayName) • \(zone.rawValue.uppercased()) −\(damage)"
      } else {
        message =
          eliminated
          ? "\(shooter.displayName) ELIMINATED \(target.displayName)"
          : "\(shooter.displayName) HIT \(target.displayName)"
      }
      let eventID = appendEventLocked(
        type: eventType,
        actorPlayerID: shooter.id,
        targetPlayerID: target.id,
        zone: zone.rawValue,
        damage: damage,
        message: message
      )

      return store(
        StoredShot(
          outcome: eliminated ? .kill : .hit,
          accepted: true,
          damage: damage,
          shooterAmmo: players[shooterIndex].ammo,
          targetHealth: remainingHealth,
          targetLifeState: eliminated ? .respawning : .alive,
          eventID: eventID,
          fireRejectReason: nil,
          debugRejectReason: nil
        )
      )
    }
    return outcome
  }

  private func rejection(reason: FireRejectReason, shooterAmmo: Int) -> StoredShot {
    StoredShot(
      outcome: .rejected,
      accepted: false,
      damage: 0,
      shooterAmmo: shooterAmmo,
      targetHealth: nil,
      targetLifeState: nil,
      eventID: nil,
      fireRejectReason: reason,
      debugRejectReason: Self.debugErrorCode(for: reason)
    )
  }

  /// Mirrors `debugErrorCode` in `convex/functions/shots.ts`.
  private static func debugErrorCode(for reason: FireRejectReason) -> BackendErrorCode {
    switch reason {
    case .connectionStale: .connectionStale
    default: .matchNotRunning
    }
  }

  static func damage(for zone: HitZone) -> Int {
    switch zone {
    case .head: 75
    case .torso: 34
    case .limbs: 20
    }
  }

  private func appendEventLocked(
    type: MatchEventType,
    actorPlayerID: String?,
    targetPlayerID: String?,
    zone: String?,
    damage: Int?,
    message: String
  ) -> String {
    let id = "event-\(nextEventNumber)"
    nextEventNumber += 1
    events.append(
      EventSnapshot(
        id: id,
        type: type,
        message: message,
        createdAt: nowMs,
        actorPlayerId: actorPlayerID,
        targetPlayerId: targetPlayerID,
        zone: zone,
        damage: damage
      )
    )
    return id
  }

  // MARK: Snapshot fan-out

  func snapshot(for role: HarnessRole) -> MatchSnapshot {
    lock.withLock { snapshotLocked(for: role.playerID) }
  }

  private func snapshotLocked(for playerID: String) -> MatchSnapshot {
    let recentEvents =
      events
      .sorted { left, right in
        left.createdAt == right.createdAt
          ? left.id < right.id : left.createdAt > right.createdAt
      }
      .prefix(Self.recentEventLimit)
    return MatchSnapshot(
      serverNow: nowMs,
      match: MatchSummary(
        id: Self.matchID,
        code: Self.matchCode,
        phase: phase,
        durationMs: Self.matchDurationMs,
        startsAt: startsAt,
        endsAt: endsAt
      ),
      localPlayerId: playerID,
      players: players.map {
        PlayerSnapshot(
          id: $0.id,
          displayName: $0.displayName,
          role: $0.role,
          ready: $0.ready,
          connected: $0.connected,
          health: $0.health,
          ammo: $0.ammo,
          kills: $0.kills,
          deaths: $0.deaths,
          lifeState: $0.lifeState,
          respawnAt: $0.respawnAt
        )
      },
      events: Array(recentEvents)
    )
  }

  /// Publishes the current authoritative state to every connected client.
  func publish() {
    lock.withLock {
      for playerID in channels.keys.sorted() {
        let snapshot = snapshotLocked(for: playerID)
        guard channels[playerID]?.deliveryEnabled == true else {
          channels[playerID]?.withheldSnapshots.append(snapshot)
          continue
        }
        channels[playerID]?.continuations.forEach { $0.yield(snapshot) }
      }
    }
  }

  func deliver(_ snapshot: MatchSnapshot, to role: HarnessRole) {
    lock.withLock {
      channels[role.playerID]?.continuations.forEach { $0.yield(snapshot) }
    }
  }

  /// Simulates a client-side transport outage: publishes for that client are
  /// withheld instead of delivered, and can be replayed in any order later.
  func setDelivery(_ enabled: Bool, for role: HarnessRole) {
    lock.withLock { channels[role.playerID]?.deliveryEnabled = enabled }
  }

  func withheldSnapshots(for role: HarnessRole) -> [MatchSnapshot] {
    lock.withLock { channels[role.playerID]?.withheldSnapshots ?? [] }
  }

  func clearWithheldSnapshots(for role: HarnessRole) {
    lock.withLock { channels[role.playerID]?.withheldSnapshots = [] }
  }

  func failSubscription(for role: HarnessRole) {
    lock.withLock {
      let continuations = channels[role.playerID]?.continuations ?? []
      channels[role.playerID]?.continuations = []
      continuations.forEach { $0.finish(throwing: GameSessionClientError.networkUnavailable) }
    }
  }

  func snapshotStream(for playerID: String) -> AsyncThrowingStream<MatchSnapshot, Error> {
    let (stream, continuation) = AsyncThrowingStream<MatchSnapshot, Error>.makeStream()
    lock.withLock {
      var channel = channels[playerID] ?? ClientChannel()
      channel.continuations.append(continuation)
      channel.subscriptionCount += 1
      channels[playerID] = channel
    }
    return stream
  }
}

private final class PeerGameSessionClient: GameSessionClient, @unchecked Sendable {
  let availability = GameSessionAvailability.available
  let playerSession: PlayerSession

  private let authority: MatchAuthority
  private let connectionStream: AsyncStream<GameSessionConnectionState>
  private let connectionContinuation: AsyncStream<GameSessionConnectionState>.Continuation

  init(authority: MatchAuthority, role: HarnessRole) {
    self.authority = authority
    playerSession = PlayerSession(
      matchId: MatchAuthority.matchID,
      code: MatchAuthority.matchCode,
      playerId: role.playerID,
      sessionSecret: UUID().uuidString
    )
    (connectionStream, connectionContinuation) = AsyncStream.makeStream()
  }

  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession { playerSession }

  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession { playerSession }

  func setReady(session: PlayerSession, isReady: Bool) async throws {}

  func startDuel(session: PlayerSession) async throws {}

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    authority.fire(shooterID: playerSession.playerId, request: request)
  }

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    authority.debugFire(shooterID: playerSession.playerId, clientShotID: clientShotId)
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    authority.snapshotStream(for: playerSession.playerId)
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> { connectionStream }

  func sendConnection(_ state: GameSessionConnectionState) {
    connectionContinuation.yield(state)
  }
}

private final class ScriptedTargetingSession: TargetingSession, @unchecked Sendable {
  let availability = TargetingAvailability.available

  private let lock = NSLock()
  private var stored: TargetingSnapshot
  private var continuations: [AsyncStream<TargetingSnapshot>.Continuation] = []

  init(initial: TargetingSnapshot) {
    stored = initial
  }

  var currentSnapshot: TargetingSnapshot {
    lock.withLock { stored }
  }

  func snapshots() -> AsyncStream<TargetingSnapshot> {
    let (stream, continuation) = AsyncStream<TargetingSnapshot>.makeStream()
    let snapshot: TargetingSnapshot = lock.withLock {
      continuations.append(continuation)
      return stored
    }
    continuation.yield(snapshot)
    return stream
  }

  func start() async throws {}

  func stop() async {}

  func emit(_ snapshot: TargetingSnapshot) {
    let targets: [AsyncStream<TargetingSnapshot>.Continuation] = lock.withLock {
      stored = snapshot
      return continuations
    }
    targets.forEach { $0.yield(snapshot) }
  }
}

/// One authoritative match plus two independent `LobbyStore` clients, each with
/// its own session, snapshot subscription, transport and shot-ID sequence.
@MainActor
private final class TwoClientRig {
  let clock: TestClock
  let authority: MatchAuthority
  let hostClient: PeerGameSessionClient
  let guestClient: PeerGameSessionClient
  let hostTargeting: ScriptedTargetingSession
  let guestTargeting: ScriptedTargetingSession
  let hostStore: LobbyStore
  let guestStore: LobbyStore

  init() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_750_000_000))
    self.clock = clock
    authority = MatchAuthority(clock: clock)
    hostClient = PeerGameSessionClient(authority: authority, role: .host)
    guestClient = PeerGameSessionClient(authority: authority, role: .guest)
    hostTargeting = ScriptedTargetingSession(initial: .unavailable(at: clock.now))
    guestTargeting = ScriptedTargetingSession(initial: .unavailable(at: clock.now))
    let hostShotIDs = ShotIDSequence((1...64).map { "host-shot-\($0)" })
    let guestShotIDs = ShotIDSequence((1...64).map { "guest-shot-\($0)" })
    hostStore = LobbyStore(
      environment: AppEnvironment(
        gameSessionClient: hostClient,
        targetingSession: hostTargeting
      ),
      now: { clock.now },
      makeShotId: { hostShotIDs.next() }
    )
    guestStore = LobbyStore(
      environment: AppEnvironment(
        gameSessionClient: guestClient,
        targetingSession: guestTargeting
      ),
      now: { clock.now },
      makeShotId: { guestShotIDs.next() }
    )
  }

  func store(_ role: HarnessRole) -> LobbyStore {
    role == .host ? hostStore : guestStore
  }

  func targeting(_ role: HarnessRole) -> ScriptedTargetingSession {
    role == .host ? hostTargeting : guestTargeting
  }

  func client(_ role: HarnessRole) -> PeerGameSessionClient {
    role == .host ? hostClient : guestClient
  }

  /// Brings both clients from home screen to a running duel through the same
  /// authoritative snapshots the app would receive.
  func startRunningDuel() async {
    hostStore.displayName = "Host"
    await hostStore.performCreateDuel()
    guestStore.displayName = "Guest"
    guestStore.joinCode = MatchAuthority.matchCode
    await guestStore.performJoinDuel()
    await hostStore.startTargeting()
    await guestStore.startTargeting()
    authority.publish()
    await settle()

    authority.markReady(.host)
    authority.markReady(.guest)
    authority.publish()
    await settle()

    authority.startMatch()
    authority.publish()
    await settle()
  }

  func advance(milliseconds: Double) {
    authority.advance(milliseconds: milliseconds)
  }

  func aim(_ role: HarnessRole, zone: TargetingHitZone = .torso, confidence: Double = 0.82) async {
    let date = clock.now
    targeting(role)
      .emit(
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
          aimClaim: TargetingAimClaim(zone: zone, confidence: confidence, capturedAt: date),
          cameraRay: TargetingCameraRay(
            origin: TargetingVector3(x: 1, y: 2, z: 3),
            direction: TargetingVector3(x: 0, y: 0, z: -1),
            capturedAt: date
          ),
          poseStaleAfter: 0.5
        )
      )
    await settle()
  }

  /// Fires one authoritative shot from `attacker` and publishes the resulting
  /// snapshot to both clients. The host uses the trusted debug path, the guest
  /// uses the markerless claim path.
  func fire(_ attacker: HarnessRole, publish: Bool = true) async {
    advance(milliseconds: 400)  // clears the 350 ms server fire cooldown
    switch attacker {
    case .host:
      await hostStore.duel.performDebugFire()
    case .guest:
      await aim(.guest)
      await guestStore.duel.performMarkerlessFire()
    }
    if publish {
      authority.publish()
      await settle()
    }
  }

  var projection: String {
    let players = authority.player(.host)
    let opponent = authority.player(.guest)
    return
      "host{hp=\(players.health) ammo=\(players.ammo) k=\(players.kills) d=\(players.deaths) "
      + "life=\(players.lifeState.rawValue)} guest{hp=\(opponent.health) ammo=\(opponent.ammo) "
      + "k=\(opponent.kills) d=\(opponent.deaths) life=\(opponent.lifeState.rawValue)}"
  }

  func clientProjection(_ role: HarnessRole) -> String? {
    guard case .active(let duel) = store(role).route else { return nil }
    return duel.players
      .sorted { $0.id < $1.id }
      .map {
        "\($0.id){hp=\($0.health) ammo=\($0.ammo) k=\($0.kills) d=\($0.deaths) "
          + "life=\($0.lifeState.rawValue) respawnAt=\($0.respawnAt.map { String($0) } ?? "nil")}"
      }
      .joined(separator: " ")
      + " phase=\(duel.phase.rawValue)"
  }

  func authoritativeProjection() -> String {
    [authority.player(.host), authority.player(.guest)]
      .sorted { $0.id < $1.id }
      .map {
        "\($0.id){hp=\($0.health) ammo=\($0.ammo) k=\($0.kills) d=\($0.deaths) "
          + "life=\($0.lifeState.rawValue) respawnAt=\($0.respawnAt.map { String($0) } ?? "nil")}"
      }
      .joined(separator: " ")
      + " phase=running"
  }

  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  /// Waits for a store-observable condition instead of assuming a fixed number
  /// of scheduler hops, so results do not depend on simulator scheduling speed.
  @discardableResult
  func wait(until condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      await settle()
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }
}

@MainActor
final class KIL36TwoClientConvergenceTests: XCTestCase {
  /// Five deterministic kill/respawn cycles, alternating attacker, asserting
  /// that both clients hold identical authoritative shot, damage, death, score,
  /// respawn and pending-shot state at every step.
  func testFiveKillRespawnCyclesConvergeOnBothClients() async throws {
    let rig = TwoClientRig()
    await rig.startRunningDuel()
    assertConverged(rig, label: "match-start")
    var expectedKills: [HarnessRole: Int] = [.host: 0, .guest: 0]
    var expectedDeaths: [HarnessRole: Int] = [.host: 0, .guest: 0]

    for cycle in 1...5 {
      let attacker: HarnessRole = cycle.isMultiple(of: 2) ? .guest : .host
      let victim = attacker.opponent
      rig.authority.record("cycle=\(cycle) attacker=\(attacker.rawValue)")

      for (index, expectedHealth) in [66, 32, 0].enumerated() {
        await rig.fire(attacker)
        let expectedDamage = expectedHealth == 0 ? 32 : 34
        rig.authority.record(
          "cycle=\(cycle) shot=\(index + 1) attacker=\(attacker.rawValue) zone=torso "
            + "damage=\(expectedDamage) \(rig.projection)"
        )
        XCTAssertEqual(
          rig.authority.player(victim).health, expectedHealth,
          "cycle \(cycle) shot \(index + 1) authoritative victim health"
        )
        assertShotConfirmed(rig, attacker: attacker, damage: expectedDamage, cycle: cycle)
        assertConverged(rig, label: "cycle-\(cycle)-shot-\(index + 1)")
      }

      // Death: victim eliminated, attacker credited, respawn scheduled.
      expectedKills[attacker, default: 0] += 1
      expectedDeaths[victim, default: 0] += 1
      XCTAssertEqual(rig.authority.player(victim).lifeState, .respawning)
      XCTAssertEqual(rig.authority.player(victim).deaths, expectedDeaths[victim])
      XCTAssertEqual(rig.authority.player(attacker).kills, expectedKills[attacker])
      assertDeathVisibleToBothClients(rig, victim: victim, cycle: cycle)

      // Firing again while the victim is respawning must not corrupt either
      // client: the debug path is rejected by the server, and the markerless
      // path never leaves the client because the target is not alive.
      await rig.fire(attacker, publish: false)
      switch attacker {
      case .host:
        XCTAssertEqual(
          rig.hostStore.duel.debugShotState, .failed,
          "cycle \(cycle): debug fire at a respawning target must fail, not stay pending"
        )
        rig.authority.record(
          "cycle=\(cycle) shot-at-respawning-target attacker=host serverRejected "
            + "debugShotState=failed errorMessage=\(rig.hostStore.errorMessage ?? "nil")"
        )
      case .guest:
        XCTAssertEqual(
          rig.guestStore.duel.markerlessShotState,
          .confirmed(outcome: .kill, zone: .torso, damage: 32),
          "cycle \(cycle): the markerless client guard must block the shot locally, "
            + "leaving the previous confirmed kill state untouched"
        )
        XCTAssertEqual(rig.guestStore.errorMessage, "PUT THE CROSSHAIR ON YOUR OPPONENT")
        rig.authority.record(
          "cycle=\(cycle) shot-at-respawning-target attacker=guest blockedByClientGuard "
            + "errorMessage=PUT THE CROSSHAIR ON YOUR OPPONENT"
        )
      }
      rig.authority.publish()
      await rig.settle()
      assertConverged(rig, label: "cycle-\(cycle)-shot-at-respawning-target")

      // Respawn: server-owned delay, then both clients observe the reset.
      rig.advance(milliseconds: MatchAuthority.respawnDelayMs)
      rig.authority.publish()
      await rig.settle()
      rig.authority.record("cycle=\(cycle) respawn victim=\(victim.rawValue) \(rig.projection)")
      XCTAssertEqual(rig.authority.player(victim).health, 100)
      XCTAssertEqual(rig.authority.player(victim).ammo, 8)
      XCTAssertEqual(rig.authority.player(victim).lifeState, .alive)
      assertConverged(rig, label: "cycle-\(cycle)-respawn")
    }

    XCTAssertEqual(rig.authority.player(.host).kills, 3)
    XCTAssertEqual(rig.authority.player(.host).deaths, 2)
    XCTAssertEqual(rig.authority.player(.guest).kills, 2)
    XCTAssertEqual(rig.authority.player(.guest).deaths, 3)
    XCTAssertEqual(expectedKills[.host], 3)
    XCTAssertEqual(expectedDeaths[.guest], 3)
    XCTAssertEqual(rig.hostStore.syncStatus, .connected)
    XCTAssertEqual(rig.guestStore.syncStatus, .connected)
    printTimeline(rig, label: "five-kill-respawn-cycles")
  }

  /// A client that misses snapshots stays input-locked until a fresh
  /// authoritative snapshot lands, then converges on everything it missed.
  func testReconnectingClientStaysLockedThenConvergesOnMissedKill() async throws {
    let rig = TwoClientRig()
    await rig.startRunningDuel()

    rig.authority.setDelivery(false, for: .guest)
    rig.guestClient.sendConnection(.connecting)
    await rig.settle()
    XCTAssertEqual(rig.guestStore.syncStatus, .stale)
    XCTAssertTrue(rig.guestStore.isMatchInputLocked)
    XCTAssertFalse(rig.guestStore.duel.canFireMarkerless)
    rig.authority.record("guest transport=connecting inputLocked=true")

    for _ in 0..<3 {
      await rig.fire(.host)
    }
    XCTAssertEqual(rig.authority.player(.guest).lifeState, .respawning)
    XCTAssertEqual(rig.hostStore.duel.debugShotState, .confirmed(damage: 32))
    rig.authority.record("guest offline through host kill \(rig.projection)")

    // Transport recovery alone must not unlock the guest.
    rig.guestClient.sendConnection(.connected)
    await rig.settle()
    XCTAssertEqual(
      rig.guestStore.syncStatus, .stale,
      "transport recovery alone must not unlock a client"
    )
    XCTAssertTrue(rig.guestStore.isMatchInputLocked)

    rig.authority.setDelivery(true, for: .guest)
    rig.authority.publish()
    await rig.settle()
    XCTAssertEqual(rig.guestStore.syncStatus, .restored)
    XCTAssertFalse(rig.guestStore.isMatchInputLocked)
    assertConverged(rig, label: "guest-reconnected")
    rig.authority.record("guest resynced \(rig.projection)")

    rig.advance(milliseconds: MatchAuthority.respawnDelayMs)
    rig.authority.publish()
    await rig.settle()
    assertConverged(rig, label: "guest-respawn-after-reconnect")
    printTimeline(rig, label: "reconnect-convergence")
  }

  /// Snapshots replayed out of order after a reconnect: the newest snapshot
  /// converges both clients and an older replayed snapshot is ignored, so the
  /// clients stay converged without waiting for a later authoritative publish.
  func testReorderedSnapshotReplayKeepsBothClientsConverged() async throws {
    let rig = TwoClientRig()
    await rig.startRunningDuel()

    rig.authority.setDelivery(false, for: .guest)
    await rig.fire(.host)  // guest health 66, withheld from guest
    await rig.fire(.host)  // guest health 32, withheld from guest
    let withheld = rig.authority.withheldSnapshots(for: .guest)
    XCTAssertEqual(withheld.count, 2)
    rig.authority.setDelivery(true, for: .guest)

    // Newest first.
    rig.authority.deliver(withheld[1], to: .guest)
    await rig.settle()
    assertConverged(rig, label: "reorder-newest-first")
    let convergedRoute = rig.guestStore.route
    let convergedSyncStatus = rig.guestStore.syncStatus
    let convergedBanner = rig.guestStore.duel.killBanner

    // The older replayed snapshot must not move the guest backwards.
    rig.authority.deliver(withheld[0], to: .guest)
    await rig.settle()
    guard case .active(let duel) = rig.guestStore.route else {
      return XCTFail("Expected active duel on the guest client")
    }
    XCTAssertEqual(
      duel.localPlayer?.health, 32,
      "a snapshot older than the latest applied serverNow must be ignored"
    )
    XCTAssertEqual(rig.guestStore.route, convergedRoute)
    XCTAssertEqual(rig.guestStore.syncStatus, convergedSyncStatus)
    XCTAssertEqual(rig.guestStore.duel.killBanner, convergedBanner)
    assertConverged(rig, label: "reorder-stale-replay-ignored")
    rig.authority.record(
      "guest ignored stale snapshot serverNow=\(withheld[0].serverNow) "
        + "latestApplied=\(withheld[1].serverNow)"
    )

    // Re-delivering the newest snapshot is still accepted (equal timestamps are
    // not rejected), and a later publish keeps both clients converged.
    rig.authority.deliver(withheld[1], to: .guest)
    await rig.settle()
    assertConverged(rig, label: "reorder-equal-timestamp-replay")

    rig.authority.publish()
    await rig.settle()
    assertConverged(rig, label: "reorder-next-publish")
    printTimeline(rig, label: "reordered-snapshot-replay")
  }

  /// A pending debug shot is not confirmed by a stale snapshot that predates
  /// the shot, and is confirmed as soon as the shot's own event arrives.
  func testPendingShotSurvivesStaleSnapshotAndConfirmsOnItsOwnEvent() async throws {
    let rig = TwoClientRig()
    await rig.startRunningDuel()
    let preShotSnapshot = rig.authority.snapshot(for: .host)

    await rig.fire(.host, publish: false)
    XCTAssertEqual(rig.hostStore.duel.debugShotState, .pending)

    rig.authority.deliver(preShotSnapshot, to: .host)
    await rig.settle()
    XCTAssertEqual(
      rig.hostStore.duel.debugShotState, .pending,
      "a snapshot that predates the shot must not confirm it"
    )

    rig.authority.publish()
    await rig.settle()
    XCTAssertEqual(rig.hostStore.duel.debugShotState, .confirmed(damage: 34))
    XCTAssertTrue(rig.hostStore.duel.canDebugFire)
    assertConverged(rig, label: "pending-shot-confirmed")
    printTimeline(rig, label: "pending-shot-lifecycle")
  }

  /// A dropped snapshot subscription re-subscribes on its own and re-converges.
  func testDroppedSubscriptionResubscribesAndReconverges() async throws {
    let rig = TwoClientRig()
    await rig.startRunningDuel()

    rig.authority.failSubscription(for: .guest)
    await rig.wait(until: { rig.guestStore.syncStatus == .stale })
    XCTAssertEqual(rig.guestStore.syncStatus, .stale)
    XCTAssertTrue(rig.guestStore.isMatchInputLocked)

    await rig.wait(until: { rig.authority.subscriptionCount(for: .guest) == 2 })
    XCTAssertEqual(rig.authority.subscriptionCount(for: .guest), 2)

    await rig.fire(.host)
    await rig.wait(until: { rig.guestStore.syncStatus == .restored })
    XCTAssertEqual(rig.guestStore.syncStatus, .restored)
    XCTAssertFalse(rig.guestStore.isMatchInputLocked)
    assertConverged(rig, label: "resubscribed")
    printTimeline(rig, label: "dropped-subscription")
  }

  // MARK: Convergence helpers

  private func assertConverged(
    _ rig: TwoClientRig,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expected = rig.authoritativeProjection()
    let host = rig.clientProjection(.host)
    let guest = rig.clientProjection(.guest)
    XCTAssertEqual(host, expected, "\(label): host client diverged", file: file, line: line)
    XCTAssertEqual(guest, expected, "\(label): guest client diverged", file: file, line: line)
    rig.authority.record("converged(\(label)) both-clients=\(expected)")
  }

  private func assertShotConfirmed(
    _ rig: TwoClientRig,
    attacker: HarnessRole,
    damage: Int,
    cycle: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    switch attacker {
    case .host:
      XCTAssertEqual(
        rig.hostStore.duel.debugShotState, .confirmed(damage: damage),
        "cycle \(cycle): host pending shot must confirm from the authoritative snapshot",
        file: file,
        line: line
      )
    case .guest:
      let state = rig.guestStore.duel.markerlessShotState
      let victimHealth = rig.authority.player(.host).health
      XCTAssertEqual(
        state,
        .confirmed(outcome: victimHealth == 0 ? .kill : .hit, zone: .torso, damage: damage),
        "cycle \(cycle): guest markerless shot must confirm with authoritative damage",
        file: file,
        line: line
      )
    }
  }

  private func assertDeathVisibleToBothClients(
    _ rig: TwoClientRig,
    victim: HarnessRole,
    cycle: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for role in [HarnessRole.host, .guest] {
      guard case .active(let duel) = rig.store(role).route else {
        return XCTFail("cycle \(cycle): expected active duel on \(role.rawValue)", file: file, line: line)
      }
      let victimPlayer = duel.players.first { $0.id == victim.playerID }
      XCTAssertEqual(victimPlayer?.health, 0, "cycle \(cycle) \(role.rawValue) view", file: file, line: line)
      XCTAssertEqual(
        victimPlayer?.lifeState, .respawning,
        "cycle \(cycle) \(role.rawValue) view",
        file: file,
        line: line
      )
      XCTAssertNotNil(
        victimPlayer?.respawnAt,
        "cycle \(cycle) \(role.rawValue) view must carry the server respawn deadline",
        file: file,
        line: line
      )
    }
  }

  /// Emits the deterministic authority/client timeline both to stdout (SwiftPM
  /// runs) and as a result-bundle attachment (simulator runs).
  private func printTimeline(_ rig: TwoClientRig, label: String) {
    let body = rig.authority.timeline
      .map { "KIL36 | \(label) | \($0)" }
      .joined(separator: "\n")
    print(body)
    let attachment = XCTAttachment(string: body)
    attachment.name = "kil36-timeline-\(label)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
