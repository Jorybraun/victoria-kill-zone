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

    await store.performDebugFire()
    await settle()

    XCTAssertEqual(store.debugShotState, .pending)
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.canDebugFire)
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

    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
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

    await store.performDebugFire()
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

    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
    XCTAssertTrue(store.canDebugFire)
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

    await store.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    for _ in 0..<3 {
      client.send(snapshot(phase: .running, events: agedOutEvents()))
      await settle()
    }
    XCTAssertEqual(client.debugShotIDs, ["aged-out-shot-id", "aged-out-shot-id"])

    await store.performDebugFire()

    XCTAssertEqual(client.debugShotIDs, ["aged-out-shot-id", "aged-out-shot-id", "next-shot-id"])
    XCTAssertEqual(store.debugShotState, .pending)
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

    await store.performDebugFire()
    clock.now = firedAt.addingTimeInterval(2)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.debugShotState, .pending)
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

    await store.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.debugShotState, .failed)
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

    await store.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.debugShotState, .failed)
    XCTAssertEqual(client.debugShotIDs, ["non-idempotent-shot-id", "non-idempotent-shot-id"])

    await store.performDebugFire()

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

    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
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

    await store.performDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await settle()

    XCTAssertEqual(store.debugShotState, .failed)
    XCTAssertEqual(
      client.debugShotIDs,
      ["transport-retry-shot-id", "transport-retry-shot-id"]
    )

    await store.performDebugFire()

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

    XCTAssertEqual(store.debugShotState, .confirmed(damage: 34))
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
    await store.performDebugFire()
    let gate = client.gateNextDebugFire()
    clock.now = firedAt.addingTimeInterval(3)
    client.send(snapshot(phase: .running, events: agedOutEvents()))
    await gate.waitUntilEntered()

    store.leave()
    gate.release()
    await settle()

    XCTAssertEqual(store.debugShotState, .idle)
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.canDebugFire)
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

    await store.performDebugFire()
    XCTAssertEqual(store.debugShotState, .pending)

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
      store.debugShotState, .confirmed(damage: 32),
      "A snapshot containing the shot's own event must confirm the shot even when the transient post-shot state was never observed"
    )
    XCTAssertTrue(store.canDebugFire)
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

    XCTAssertEqual(store.killBanner?.text, "YOU ELIMINATED Guest")
    XCTAssertTrue(store.killBanner?.isLocalKill == true)
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

    XCTAssertEqual(store.killBanner?.text, "ELIMINATED BY Guest")
    XCTAssertFalse(store.killBanner?.isLocalKill == true)
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
    let firstBanner = try XCTUnwrap(store.killBanner)

    client.send(snapshot(phase: .running, events: [event]))
    await settle()

    XCTAssertEqual(store.killBanner, firstBanner)
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

    XCTAssertEqual(store.killBanner?.text, "YOU ELIMINATED Guest")
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
