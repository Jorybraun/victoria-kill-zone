import Foundation
import Combine
import XCTest
@testable import VictoriaKillZone

@MainActor
final class DuelSessionTests: XCTestCase {
  func testLostFinalDebugRoundCanReplayExactIDWithEmptyMagazine() async throws {
    let client = FakeGameSessionClient()
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running, hostAmmo: 1))
    XCTAssertTrue(duel.canDebugFire)
    await duel.performDebugFire() // Simulate an unavailable response after dispatch.
    XCTAssertEqual(duel.debugShotState, .failed)
    duel.receive(snapshot(phase: .running, hostAmmo: 0, guestHealth: 66))
    XCTAssertTrue(duel.canDebugFire, "The retained request must remain retryable after the authority spends the final round")
    client.debugFireResult = DebugFireResult(accepted: true, outcome: .hit,
      clientShotId: "shot-1", replayed: true, damage: 34, shooterAmmo: 0,
      targetHealth: 66, eventId: nil, rejectReason: nil)
    await duel.performDebugFire()
    XCTAssertEqual(client.debugShotIDs, ["shot-1", "shot-1"])
    XCTAssertEqual(duel.debugShotState, .confirmed(damage: 34))
    XCTAssertFalse(duel.canDebugFire, "A resolved request must not permit a new empty-magazine shot")
  }

  func testAuthoritativelyRejectedDebugShotDoesNotBypassEmptyMagazineGate() async throws {
    let client = FakeGameSessionClient()
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running, hostAmmo: 1))
    client.debugFireResult = DebugFireResult(accepted: false, outcome: .rejected,
      clientShotId: "shot-1", replayed: false, damage: 0, shooterAmmo: 0,
      targetHealth: 100, eventId: nil, rejectReason: .matchNotRunning)
    await duel.performDebugFire()
    duel.receive(snapshot(phase: .running, hostAmmo: 0))
    XCTAssertEqual(duel.debugShotState, .failed)
    XCTAssertFalse(duel.canDebugFire)
  }

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

  func testMatchingShotIDSuppressesOnlyTheTracerAndPreservesConfirmedHit()
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
        damage: nil,
        clientShotId: "guest-shot"
      )
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "peer:guest-shot")
    XCTAssertTrue(duel.incomingShots.isEmpty)

    duel.receive(snapshot(phase: .running, events: [
      EventSnapshot(
        id: "opponent-hit",
        type: .hit,
        message: "Guest hit Host",
        createdAt: 1_750_000_000_200,
        actorPlayerId: "guest-1",
        targetPlayerId: "host-1",
        zone: "torso",
        damage: 34,
        clientShotId: "guest-shot"
      )
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "opponent-hit")
    XCTAssertTrue(duel.incomingShot?.hit == true)
    XCTAssertFalse(duel.incomingShot?.renderTracer == true)
    XCTAssertEqual(duel.incomingShots.count, 1)

    duel.receive(snapshot(phase: .running, events: [
      eliminatedEvent(actorPlayerID: "guest-1", targetPlayerID: "host-1")
    ]))
    XCTAssertEqual(duel.incomingShot?.eventID, "event-eliminated")
  }

  func testIncomingSnapshotPublishesEveryNewShotInChronologicalOrder() async throws {
    let duel = makeDuel()
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    let events = [
      incomingEvent(id: "third", shotID: "shot-c", at: 300),
      incomingEvent(id: "first", shotID: "shot-a", at: 100),
      incomingEvent(id: "second", shotID: "shot-b", at: 200, hit: true),
    ]
    duel.receive(snapshot(phase: .running, events: events))

    XCTAssertEqual(duel.incomingShots.map(\.eventID), ["first", "second", "third"])
    XCTAssertEqual(duel.incomingShots.map(\.hit), [false, true, false])
    XCTAssertEqual(duel.incomingShot?.eventID, "third")
    duel.receive(snapshot(phase: .running, events: events))
    XCTAssertTrue(duel.incomingShots.isEmpty, "Repeated snapshots must not replay already consumed bullets")
    XCTAssertEqual(duel.incomingShot?.eventID, "third")
  }

  func testUnrelatedAndLegacyMissesAreNotSuppressedByANearbyPeerShot() async throws {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    link.receive(.shotTracer(try incomingTracer(id: "peer-shot")))
    await settle()

    duel.receive(snapshot(phase: .running, events: [
      incomingEvent(id: "unrelated-miss", shotID: "another-shot", at: 100),
      incomingEvent(id: "legacy-miss", shotID: nil, at: 101),
    ]))
    XCTAssertEqual(duel.incomingShots.map(\.eventID), ["unrelated-miss", "legacy-miss"])
    XCTAssertTrue(duel.incomingShots.allSatisfy(\.renderTracer))
  }

  func testDuplicatePeerAndConvexDeliveriesDoNotRepublishAndHitStillPublishes() async throws {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    var delivered: [IncomingShot] = []
    let subscription = duel.$incomingShots.dropFirst().sink { delivered.append(contentsOf: $0) }
    defer { subscription.cancel() }

    let tracer = try incomingTracer(id: "same-shot")
    link.receive(.shotTracer(tracer))
    link.receive(.shotTracer(tracer))
    await settle()
    let hit = incomingEvent(id: "durable-hit", shotID: "same-shot", at: 100, hit: true)
    duel.receive(snapshot(phase: .running, events: [hit]))
    duel.receive(snapshot(phase: .running, events: [hit]))
    link.receive(.shotTracer(tracer))
    await settle()

    XCTAssertEqual(delivered.map(\.eventID), ["peer:same-shot", "durable-hit"])
    XCTAssertEqual(delivered.map(\.renderTracer), [true, false])
    XCTAssertEqual(delivered.map(\.hit), [false, true])
  }

  func testTwoPeerShotsInOneUIFrameBothReachTheBatchPublisher() async throws {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    var delivered: [String] = []
    let subscription = duel.$incomingShots.dropFirst().sink { delivered.append(contentsOf: $0.map(\.eventID)) }
    defer { subscription.cancel() }
    link.receive(.shotTracer(try incomingTracer(id: "first")))
    link.receive(.shotTracer(try incomingTracer(id: "second")))
    await settle()

    XCTAssertEqual(delivered, ["peer:first", "peer:second"])
  }

  func testConvexFirstDeliverySuppressesALatePeerDuplicateAndResetClearsDedup() async throws {
    let link = FakeDuelPeerLink()
    let duel = makeDuel(link: link)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    duel.receive(snapshot(phase: .running, events: [
      incomingEvent(id: "durable-miss", shotID: "same-shot", at: 100)
    ]))
    var delivered: [String] = []
    let subscription = duel.$incomingShots.dropFirst().sink { delivered.append(contentsOf: $0.map(\.eventID)) }
    defer { subscription.cancel() }
    let tracer = try incomingTracer(id: "same-shot")
    link.receive(.shotTracer(tracer))
    await settle()
    XCTAssertTrue(delivered.isEmpty)

    duel.reset()
    duel.attach(session: makeSession())
    duel.receive(snapshot(phase: .running))
    link.receive(.shotTracer(tracer))
    await settle()
    XCTAssertEqual(delivered, ["peer:same-shot"])
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
        damage: nil,
        clientShotId: "client-shot-\(index)"
      )
    }
    duel.receive(snapshot(phase: .running, events: events))

    XCTAssertEqual(duel.seenIncomingShotEventCount, DuelSession.incomingShotDedupCapacity)
    XCTAssertEqual(duel.renderedIncomingTracerCount, DuelSession.incomingShotDedupCapacity)
    XCTAssertEqual(duel.incomingShots.count, 300)
  }

  private func incomingEvent(id: String, shotID: String?, at offset: Double, hit: Bool = false) -> EventSnapshot {
    EventSnapshot(
      id: id,
      type: hit ? .hit : .shot,
      message: hit ? "Guest hit Host" : "Guest fired",
      createdAt: 1_750_000_000_000 + offset,
      actorPlayerId: "guest-1",
      targetPlayerId: hit ? "host-1" : nil,
      zone: hit ? "torso" : nil,
      damage: hit ? 34 : nil,
      clientShotId: shotID
    )
  }

  private func incomingTracer(id: String) throws -> ArenaShotTracer {
    ArenaShotTracer(
      shotId: id,
      shooterPlayerId: "guest-1",
      ray: try ArenaShotRay(
        origin: .zero,
        direction: ArenaVector3(x: 0, y: 0, z: -1),
        firedAtMs: 1
      )
    )
  }

  func testPeerLinkStoppedWhenPhaseLeavesRunningAndOnReset() async throws {
    let link = FakeDuelPeerLink()
    var makeLinkCount = 0
    let duel = DuelSession(
      gameSessionClient: FakeGameSessionClient(),
      now: { Date(timeIntervalSince1970: 1_750_000_000) },
      makeShotId: { "shot-1" },
      makePeerLink: { serviceName in
        XCTAssertEqual(serviceName, "vkz-match-1")
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

  func testNewHoldCanRecoverFromAPreviousCooldownRejection() async throws {
    let clock = DuelTestClock()
    let client = FakeGameSessionClient()
    client.fireResult = fireResult(accepted: false, reason: .fireCooldown)
    let duel = makeDuel(client: client, now: { clock.now() })
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    duel.updateTargeting(aimedSnapshot())
    await duel.performMarkerlessFire()
    XCTAssertEqual(duel.markerlessShotState, .failed(reason: .fireCooldown))

    clock.advance(0.2)
    client.fireResult = fireResult()
    duel.startRepeatingFire()
    await waitFor { duel.markerlessShotState == .confirmed(outcome: .hit, zone: .torso, damage: 34) }
    duel.stopRepeatingFire()
    XCTAssertEqual(client.fireRequests.count, 2)
  }

  func testUncertainLastRoundReplaysDespiteEmptyAmmoDeathOrMatchCompletion() async throws {
    for (phase, life) in [(MatchPhase.running, PlayerLifeState.alive), (.running, .dead), (.finished, .dead)] {
      let client = FakeGameSessionClient()
      let duel = makeDuel(client: client)
      defer { duel.reset() }
      duel.receive(snapshot(phase: .running, hostAmmo: 1))
      duel.updateTargeting(aimedSnapshot())
      // Simulate an accepted last round whose mutation response was lost.
      await duel.performMarkerlessFire()
      let originalRequest = try XCTUnwrap(client.fireRequests.first)
      let originalVisual = duel.outgoingShot
      duel.receive(snapshot(phase: phase, hostAmmo: 0, hostLifeState: life))
      client.fireResult = fireResult(replayed: true, ammo: 0)

      XCTAssertTrue(duel.canFireMarkerless, "Exact replay must not require another round or a living shooter")
      await duel.performMarkerlessFire()
      XCTAssertEqual(client.fireRequests, [originalRequest, originalRequest])
      XCTAssertEqual(duel.outgoingShot, originalVisual, "Replay must not show a second muzzle flash")
      XCTAssertEqual(duel.markerlessShotState, .confirmed(outcome: .hit, zone: .torso, damage: 34))
      if phase == .running && life == .alive {
        XCTAssertTrue(duel.canReload, "Settling the last shot must unlock reload")
      }
    }
  }

  func testNewHoldCanReplayAnUncertainMissWithoutChangingItsClaim() async throws {
    let client = FakeGameSessionClient()
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    duel.updateTargeting(cameraOnlySnapshot())
    await duel.performMarkerlessFire()
    let original = try XCTUnwrap(client.fireRequests.first)
    XCTAssertNil(original.zone)
    XCTAssertNil(original.targetId)

    client.fireResult = fireResult(outcome: .miss, replayed: true)
    duel.updateTargeting(aimedSnapshot())
    duel.startRepeatingFire()
    await waitFor { duel.markerlessShotState == .confirmed(outcome: .miss, zone: nil, damage: 0) }
    duel.stopRepeatingFire()
    XCTAssertEqual(client.fireRequests, [original, original])
  }

  func testReleasingHoldDoesNotCancelAnAlreadyDispatchedShot() async throws {
    let response = SuspendedDuelResponse<FireShotResult>()
    let client = FakeGameSessionClient()
    client.fireHandler = { _ in try await response.value() }
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    duel.updateTargeting(aimedSnapshot())
    duel.startRepeatingFire()
    await waitFor { await response.isWaiting }

    duel.stopRepeatingFire()
    XCTAssertFalse(duel.isTriggerHeld)
    await response.resolve(.success(fireResult()))
    await waitFor { duel.markerlessShotState == .confirmed(outcome: .hit, zone: .torso, damage: 34) }
    XCTAssertEqual(client.fireRequests.count, 1)
  }

  func testCancelledHeartbeatCannotUnlockAnInactiveScene() async throws {
    let response = SuspendedDuelResponse<Void>()
    let client = FakeGameSessionClient()
    client.heartbeatHandler = { try await response.value() }
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running))
    duel.updateTargeting(aimedSnapshot())
    await waitFor { await response.isWaiting }

    duel.setSceneActive(false)
    XCTAssertFalse(duel.presenceReady)
    await response.resolve(.success(()))
    await settle()
    XCTAssertFalse(duel.presenceReady)
    XCTAssertFalse(duel.canFireMarkerless)

    duel.setSceneActive(true)
    await waitFor { duel.presenceReady }
    XCTAssertEqual(client.heartbeatCount, 2)
  }

  func testReloadAcknowledgementBridgesTheSnapshotGap() async throws {
    let client = FakeGameSessionClient()
    let endsAt = 1_750_000_001_250.0
    client.reloadResult = ReloadResult(ammo: 3, reloadEndsAt: endsAt)
    let duel = makeDuel(client: client)
    defer { duel.reset() }
    duel.receive(snapshot(phase: .running, hostAmmo: 3))
    await duel.performReload()
    XCTAssertTrue(duel.isReloading)
    XCTAssertFalse(duel.canReload)

    duel.receive(snapshot(phase: .running, hostAmmo: 3))
    XCTAssertTrue(duel.isReloading, "An older pre-reload snapshot must not reopen fire")
    duel.receive(snapshot(phase: .running, hostAmmo: 3, hostReloadEndsAt: endsAt))
    XCTAssertTrue(duel.isReloading)
    duel.receive(snapshot(phase: .running, hostAmmo: 8, serverNow: endsAt))
    XCTAssertFalse(duel.isReloading)
  }

  func testLateReloadAcknowledgementCannotRestoreCompletedOrDeadReload() async throws {
    for completed in [true, false] {
      let response = SuspendedDuelResponse<ReloadResult>()
      let client = FakeGameSessionClient()
      client.reloadHandler = { try await response.value() }
      let duel = makeDuel(client: client)
      defer { duel.reset() }
      duel.receive(snapshot(phase: .running, hostAmmo: 3))
      let request = Task { await duel.performReload() }
      await waitFor { await response.isWaiting }
      let endsAt = 1_750_000_001_250.0
      duel.receive(snapshot(
        phase: .running,
        hostAmmo: completed ? 8 : 3,
        hostLifeState: completed ? .alive : .dead,
        serverNow: completed ? endsAt : endsAt - 1_000
      ))
      await response.resolve(.success(ReloadResult(ammo: 3, reloadEndsAt: endsAt)))
      await request.value
      XCTAssertFalse(duel.isReloading)
      XCTAssertNil(duel.reloadAcknowledgedUntil)
    }
  }

  private func fireResult(
    accepted: Bool = true,
    outcome: FireShotOutcome = .hit,
    replayed: Bool = false,
    ammo: Int = 7,
    reason: FireRejectReason? = nil
  ) -> FireShotResult {
    FireShotResult(
      accepted: accepted,
      outcome: accepted ? outcome : .rejected,
      clientShotId: "shot-1",
      replayed: replayed,
      damage: accepted && outcome != .miss ? 34 : 0,
      shooterAmmo: ammo,
      targetHealth: nil,
      targetLifeState: nil,
      eventId: nil,
      rejectReason: reason
    )
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
      makePeerLink: { _ in link }
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
    hostLifeState: PlayerLifeState = .alive,
    hostReloadEndsAt: Double? = nil,
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
          ammo: hostAmmo,
          lifeState: hostLifeState,
          reloadEndsAt: hostReloadEndsAt
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

  private func cameraOnlySnapshot() -> TargetingSnapshot {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    return TargetingSnapshot(
      state: .searching,
      bodyDetected: false,
      torsoDetected: false,
      confidence: 0,
      observedAt: date,
      poseObservedAt: nil,
      bodyBounds: nil,
      torsoBounds: nil,
      headRegion: nil,
      torsoRegion: nil,
      aimClaim: nil,
      cameraRay: aimedSnapshot().cameraRay,
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

  private func waitFor(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async -> Bool
  ) async {
    for _ in 0..<1_000 {
      if await condition() { return }
      await Task.yield()
    }
    XCTFail("Expected asynchronous state transition", file: file, line: line)
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
  var debugShotIDs: [String] = []
  var fireRequests: [FireShotRequest] = []
  var fireHandler: (@Sendable (FireShotRequest) async throws -> FireShotResult)?
  var heartbeatHandler: (@Sendable () async throws -> Void)?
  var heartbeatCount = 0
  var reloadResult: ReloadResult?
  var reloadHandler: (@Sendable () async throws -> ReloadResult)?

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

  func heartbeat(session: PlayerSession) async throws {
    heartbeatCount += 1
    if let heartbeatHandler { try await heartbeatHandler() }
  }

  func startReload(session: PlayerSession) async throws -> ReloadResult {
    if let reloadHandler { return try await reloadHandler() }
    guard let reloadResult else { throw GameSessionClientError.notConfigured }
    return reloadResult
  }

  func fire(session: PlayerSession, request: FireShotRequest) async throws -> FireShotResult {
    fireRequests.append(request)
    if let fireHandler { return try await fireHandler(request) }
    guard let fireResult else { throw GameSessionClientError.notConfigured }
    return fireResult
  }

  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {
    debugShotIDs.append(clientShotId)
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

private final class DuelTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_750_000_000)

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(_ interval: TimeInterval) {
    lock.lock()
    date.addTimeInterval(interval)
    lock.unlock()
  }
}

private actor SuspendedDuelResponse<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?
  var isWaiting: Bool { continuation != nil }

  func value() async throws -> Value {
    if let result { return try result.get() }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func resolve(_ result: Result<Value, Error>) {
    self.result = result
    continuation?.resume(with: result)
    continuation = nil
  }
}
