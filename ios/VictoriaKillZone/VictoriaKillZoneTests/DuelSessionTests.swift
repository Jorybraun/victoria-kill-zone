import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class DuelSessionTests: XCTestCase {
  func testLocalKillSnapshotShowsKillBanner() async throws {
    let duel = makeDuel()
    duel.receive(snapshot(phase: .running))
    duel.receive(snapshot(
      phase: .running,
      events: [eliminatedEvent(actorPlayerID: "host-1", targetPlayerID: "guest-1")]
    ))

    XCTAssertEqual(duel.killBanner?.text, "YOU ELIMINATED Guest")
    XCTAssertTrue(duel.killBanner?.isLocalKill == true)
  }

  func testOpponentKillSnapshotShowsEliminatedByBanner() async throws {
    let duel = makeDuel()
    duel.receive(snapshot(phase: .running))
    duel.receive(snapshot(
      phase: .running,
      events: [eliminatedEvent(actorPlayerID: "guest-1", targetPlayerID: "host-1")]
    ))

    XCTAssertEqual(duel.killBanner?.text, "ELIMINATED BY Guest")
    XCTAssertFalse(duel.killBanner?.isLocalKill == true)
  }

  func testDuplicateKillEventDoesNotRetriggerBanner() async throws {
    let duel = makeDuel()
    duel.receive(snapshot(phase: .running))
    let event = eliminatedEvent(actorPlayerID: "host-1", targetPlayerID: "guest-1")
    duel.receive(snapshot(phase: .running, events: [event]))
    let firstBanner = try XCTUnwrap(duel.killBanner)
    duel.receive(snapshot(phase: .running, events: [event]))

    XCTAssertEqual(duel.killBanner, firstBanner)
  }

  func testOpponentShotAndHitPublishIncomingShotsButOwnEventsDoNot() async throws {
    let duel = makeDuel()
    duel.receive(snapshot(phase: .running))
    duel.receive(snapshot(
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
    ))
    XCTAssertEqual(
      duel.incomingShot,
      IncomingShot(
        eventID: "opponent-shot",
        hit: false,
        zone: "head",
        timestamp: 1_750_000_000_100,
        source: .convex
      )
    )

    duel.receive(snapshot(
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
    ))
    XCTAssertEqual(duel.incomingShot?.eventID, "opponent-hit")
    XCTAssertTrue(duel.incomingShot?.hit == true)
  }

  func testKillBannerUsesFirstSnapshotServerClock() async throws {
    let duel = makeDuel(now: { Date(timeIntervalSince1970: 2_000_000_000) })
    let firstServerNow = 1_750_000_000_000.0
    duel.receive(snapshot(phase: .running, serverNow: firstServerNow))
    duel.receive(snapshot(
      phase: .running,
      events: [eliminatedEvent(
        actorPlayerID: "host-1",
        targetPlayerID: "guest-1",
        createdAt: firstServerNow + 100
      )],
      serverNow: firstServerNow + 1_000
    ))

    XCTAssertEqual(duel.killBanner?.text, "YOU ELIMINATED Guest")
  }

  func testPeerTracerAcceptedOnlyFromOpponent() async throws {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    duel.receive(snapshot(phase: .running))
    guard case .host? = link.startedRole else {
      return XCTFail("Expected the host peer link role")
    }

    let ray = try ArenaShotRay(
      origin: ArenaVector3(x: 0, y: 0, z: 0),
      direction: ArenaVector3(x: 0, y: 0, z: -1),
      firedAtMs: 1
    )
    for shooter in ["host-1", "stranger-9"] {
      link.receive(.shotTracer(ArenaShotTracer(
        shotId: shooter,
        shooterPlayerId: shooter,
        ray: ray
      )))
      await settle()
      XCTAssertNil(duel.incomingShot)
    }

    link.receive(.shotTracer(ArenaShotTracer(
      shotId: "guest-shot",
      shooterPlayerId: "guest-1",
      ray: ray
    )))
    await settle()
    XCTAssertEqual(
      duel.incomingShot,
      IncomingShot(
        eventID: "peer:guest-shot",
        hit: false,
        zone: nil,
        timestamp: 1_750_000_000_000,
        source: .peer
      )
    )
  }

  func testTracerNotSentWhenAmmoIsZero() async throws {
    let link = FakeDuelPeerLink()
    let client = FakeGameSessionClient()
    client.fireResult = FireShotResult(
      accepted: true,
      outcome: .hit,
      clientShotId: "shot-1",
      replayed: false,
      damage: 34,
      shooterAmmo: 7,
      targetHealth: 66,
      targetLifeState: .alive,
      eventId: "hit-1",
      rejectReason: nil
    )
    let duel = makeDuel(client: client, link: link)
    duel.updateTargeting(aimedSnapshot())
    duel.receive(snapshot(phase: .running, hostAmmo: 0))
    await duel.performMarkerlessFire()
    XCTAssertTrue(link.sent.isEmpty)
    XCTAssertEqual(duel.markerlessShotState, .idle)
    XCTAssertTrue(client.fireRequests.isEmpty)

    duel.receive(snapshot(phase: .running, hostAmmo: 8))
    await duel.performMarkerlessFire()
    XCTAssertEqual(link.sent.count, 1)
    guard case .shotTracer(let tracer) = link.sent[0] else {
      return XCTFail("Expected a shot tracer")
    }
    XCTAssertEqual(tracer.shooterPlayerId, "host-1")
  }

  func testConvexMissSuppressedWithinTwoSecondsOfPeerTracerButHitStillRendered()
    async throws
  {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    duel.receive(snapshot(phase: .running))
    let ray = try ArenaShotRay(
      origin: .zero,
      direction: ArenaVector3(x: 0, y: 0, z: -1),
      firedAtMs: 1
    )
    link.receive(.shotTracer(ArenaShotTracer(
      shotId: "guest-shot",
      shooterPlayerId: "guest-1",
      ray: ray
    )))
    await settle()

    duel.receive(snapshot(phase: .running, events: [
      EventSnapshot(
        id: "opponent-shot",
        type: .shot,
        message: "Guest fired",
        createdAt: 1_750_000_000_100,
        actorPlayerId: "guest-1",
        targetPlayerId: "host-1",
        zone: "torso",
        damage: nil
      )
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "peer:guest-shot")

    duel.receive(snapshot(phase: .running, events: [
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
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "opponent-hit")
    XCTAssertTrue(duel.incomingShot?.hit == true)

    duel.receive(snapshot(phase: .running, events: [
      eliminatedEvent(actorPlayerID: "guest-1", targetPlayerID: "host-1")
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "event-eliminated")
  }

  func testIncomingShotDedupSetIsCapped() async throws {
    let duel = makeDuel()
    duel.receive(snapshot(phase: .running))
    let events = (0..<300).map { index in
      EventSnapshot(
        id: "shot-\(index)",
        type: .shot,
        message: "Guest fired",
        createdAt: 1_750_000_000_100 + Double(index),
        actorPlayerId: "guest-1",
        targetPlayerId: "host-1",
        zone: "torso",
        damage: nil
      )
    }
    duel.receive(snapshot(phase: .running, events: events))

    XCTAssertEqual(duel.seenIncomingShotEventCount, DuelSession.incomingShotDedupCapacity)
  }

  func testPeerLinkStoppedWhenPhaseLeavesRunningAndOnReset() async throws {
    let link = FakeDuelPeerLink()
    var makeLinkCount = 0
    let duel = DuelSession(
      gameSessionClient: FakeGameSessionClient(),
      now: { Date(timeIntervalSince1970: 1_750_000_000) },
      makeShotId: { "shot-1" },
      makePeerLink: {
        makeLinkCount += 1
        return link
      }
    )
    duel.attach(session: makeSession())
    duel.receive(snapshot(phase: .running))
    XCTAssertEqual(link.stopCount, 0)
    duel.receive(snapshot(phase: .finished))
    XCTAssertEqual(link.stopCount, 1)
    duel.receive(snapshot(phase: .finished))
    XCTAssertEqual(makeLinkCount, 1)

    let resetLink = FakeDuelPeerLink()
    let resetDuel = makeDuel(link: resetLink)
    resetDuel.receive(snapshot(phase: .running))
    resetDuel.reset()
    XCTAssertEqual(resetLink.stopCount, 1)
  }

  private func makeDuel(
    client: FakeGameSessionClient = FakeGameSessionClient(),
    link: FakeDuelPeerLink = FakeDuelPeerLink(),
    now: @escaping @Sendable () -> Date = {
      Date(timeIntervalSince1970: 1_750_000_000)
    }
  ) -> DuelSession {
    let duel = DuelSession(
      gameSessionClient: client,
      now: now,
      makeShotId: { "shot-1" },
      makePeerLink: { link }
    )
    duel.attach(session: makeSession())
    return duel
  }

  private func makeSession() -> PlayerSession {
    PlayerSession(
      matchId: "match-1",
      code: "ABC123",
      playerId: "host-1",
      sessionSecret: "test-secret"
    )
  }

  private func snapshot(
    phase: MatchPhase,
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
        startsAt: nil,
        endsAt: nil
      ),
      localPlayerId: "host-1",
      players: [
        PlayerSnapshot(
          id: "host-1",
          displayName: "Host",
          role: .host,
          ready: true,
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

  private func aimedSnapshot() -> TargetingSnapshot {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    return TargetingSnapshot(
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
      aimClaim: TargetingAimClaim(
        zone: .torso,
        confidence: 0.82,
        capturedAt: date
      ),
      cameraRay: TargetingCameraRay(
        origin: TargetingVector3(x: 1, y: 2, z: 3),
        direction: TargetingVector3(x: 0, y: 0, z: -1),
        capturedAt: date
      ),
      poseStaleAfter: 0.5
    )
  }

  private func eliminatedEvent(
    actorPlayerID: String?,
    targetPlayerID: String?,
    createdAt: Double = 1_750_000_000_100
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

private final class FakeDuelPeerLink: DuelPeerLink {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)?
  var sent: [ArenaLinkMessage] = []
  var startedRole: ArenaRole?
  var stopCount = 0

  func start(role: ArenaRole) {
    startedRole = role
  }

  func stop() {
    stopCount += 1
  }

  func send(_ message: ArenaLinkMessage) {
    sent.append(message)
  }

  func receive(_ message: ArenaLinkMessage) {
    onMessage?(message, 0)
  }
}

private final class FakeGameSessionClient: GameSessionClient, @unchecked Sendable {
  let availability = GameSessionAvailability.available
  var fireResult: FireShotResult?
  var debugFireResult: DebugFireResult?
  var fireRequests: [FireShotRequest] = []

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
    fireRequests.append(request)
    guard let fireResult else { throw GameSessionClientError.notConfigured }
    return fireResult
  }

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    guard let debugFireResult else { throw GameSessionClientError.notConfigured }
    return debugFireResult
  }

  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {
    AsyncThrowingStream { _ in }
  }

  func connectionStates() -> AsyncStream<GameSessionConnectionState> {
    AsyncStream { _ in }
  }
}
