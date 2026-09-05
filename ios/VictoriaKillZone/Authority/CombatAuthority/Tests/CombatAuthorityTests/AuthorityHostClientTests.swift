import XCTest
import CombatAuthority
import PewPewSimulation

final class AuthorityHostTests: XCTestCase {
  private let ids = [
    SimulationPlayerID("a"),
    SimulationPlayerID("b"),
    SimulationPlayerID("c"),
  ]

  func testSchedulingRejectionsAndMemberRecovery() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var host = try AuthorityHost(
      roster: roster,
      configuration: AuthorityHostConfiguration(snapshotIntervalTicks: 2),
      startedAtMs: 0
    )
    let pose = PoseInput(
      slot: 1,
      sequence: 1,
      sample: PoseSample(timestampMs: 50, position: Vector3(0, 0, 4))
    )
    XCTAssertTrue(host.ingest(.pose(pose), from: 1, atMs: 50).isEmpty)
    XCTAssertEqual(host.ingest(.pose(pose), from: 1, atMs: 51), [
      .rejectedInput(slot: 1, reason: .staleSequence)
    ])
    XCTAssertEqual(
      host.ingest(.pose(PoseInput(slot: 2, sequence: 1, sample: pose.sample)), from: 1, atMs: 52),
      [.rejectedInput(slot: 1, reason: .slotMismatch)]
    )
    XCTAssertEqual(
      host.ingest(.snapshot(StateSnapshot(sequence: 1, tick: 1, clockMs: 50, players: [])), from: 1, atMs: 52),
      [.rejectedInput(slot: 1, reason: .hostDoesNotAcceptVerdicts)]
    )
    XCTAssertTrue(host.advance(nowMs: 125).contains {
      if case .broadcast(.snapshot) = $0 { return true }
      return false
    })
    XCTAssertEqual(host.simulation.tick, 2)

    XCTAssertEqual(host.memberDropped(1, atMs: 200), [
      .memberFireLocked(slot: 1),
      .broadcast(.snapshot(host.snapshot()))
    ])
    let claim = ShotClaim(
      shotID: "locked",
      shooterID: ids[1],
      origin: Vector3(0, 0, 4),
      direction: Vector3(0, 0, -1),
      firedAtMs: 200
    )
    XCTAssertEqual(
      host.ingest(
        .fire(FireInput(slot: 1, sequence: 2, claim: claim)),
        from: 1,
        atMs: 200
      ),
      [.rejectedInput(slot: 1, reason: .memberFireLocked)]
    )
    XCTAssertEqual(host.fireLockedSlots, [1])
    let recoveryEffects = host.memberRecovered(1, atMs: 201)
    XCTAssertTrue(recoveryEffects.contains(.memberFireUnlocked(slot: 1)))
    XCTAssertTrue(recoveryEffects.contains {
      if case .broadcast(.snapshot) = $0 { return true }
      return false
    })
  }

  func testTimeoutLocksInactiveMembers() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var host = try AuthorityHost(
      roster: roster,
      configuration: AuthorityHostConfiguration(memberTimeoutMs: 100),
      startedAtMs: 0
    )
    let effects = host.advance(nowMs: 101)
    XCTAssertTrue(effects.contains(.memberFireLocked(slot: 1)))
    XCTAssertTrue(effects.contains(.memberFireLocked(slot: 2)))
    XCTAssertEqual(host.fireLockedSlots, [1, 2])
  }

  func testSameTickArrivalOrderProducesIdenticalVerdicts() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var first = try AuthorityHost(roster: roster, startedAtMs: 0)
    var second = try AuthorityHost(roster: roster, startedAtMs: 0)
    let poses = ids.enumerated().map { index, _ in
      AuthorityMessage.pose(
        PoseInput(
          slot: UInt8(index),
          sequence: 1,
          sample: PoseSample(
            timestampMs: 50,
            position: Vector3(Double(index) * 4, 0, 0)
          )
        )
      )
    }
    let claims = [
      AuthorityMessage.fire(
        FireInput(
          slot: 0,
          sequence: 1,
          claim: ShotClaim(
            shotID: "a-shot",
            shooterID: ids[0],
            targetID: ids[1],
            origin: Vector3(0, 0, 0),
            direction: Vector3(1, 0, 0),
            firedAtMs: 50
          )
        )
      ),
      AuthorityMessage.fire(
        FireInput(
          slot: 1,
          sequence: 1,
          claim: ShotClaim(
            shotID: "b-shot",
            shooterID: ids[1],
            targetID: ids[0],
            origin: Vector3(4, 0, 0),
            direction: Vector3(-1, 0, 0),
            firedAtMs: 50
          )
        )
      ),
    ]
    for (slot, message) in poses.enumerated() {
      _ = first.ingest(message, from: UInt8(slot), atMs: 50)
    }
    for (slot, message) in poses.reversed().enumerated() {
      let actualSlot = UInt8(poses.count - 1 - slot)
      _ = second.ingest(message, from: actualSlot, atMs: 50)
    }
    _ = first.ingest(claims[0], from: 0, atMs: 50)
    _ = first.ingest(claims[1], from: 1, atMs: 50)
    _ = second.ingest(claims[1], from: 1, atMs: 50)
    _ = second.ingest(claims[0], from: 0, atMs: 50)
    _ = first.advance(nowMs: 50)
    _ = second.advance(nowMs: 50)
    XCTAssertEqual(first.verdictLog, second.verdictLog)
  }

  func testReloadIngestionProducesReloadStartedVerdict() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var host = try AuthorityHost(roster: roster, startedAtMs: 0)
    let claim = ShotClaim(
      shotID: "before-reload",
      shooterID: ids[0],
      origin: Vector3.zero,
      direction: Vector3(0, 0, 1),
      firedAtMs: 50
    )
    _ = host.ingest(
      .pose(
        PoseInput(
          slot: 0,
          sequence: 1,
          sample: PoseSample(timestampMs: 50, position: .zero)
        )
      ),
      from: 0,
      atMs: 50
    )
    _ = host.ingest(
      .fire(FireInput(slot: 0, sequence: 1, claim: claim)),
      from: 0,
      atMs: 50
    )
    XCTAssertTrue(
      host.ingest(
        .reload(ReloadInput(slot: 0, sequence: 1, requestedAtMs: 50)),
        from: 0,
        atMs: 50
      ).isEmpty
    )
    let effects = host.advance(nowMs: 50)
    XCTAssertTrue(effects.contains {
      guard case let .broadcast(.verdict(frame)) = $0 else { return false }
      if case .reloadStarted = frame.event { return true }
      return false
    })
  }
}

final class AuthorityClientTests: XCTestCase {
  private let ids = [
    SimulationPlayerID("a"),
    SimulationPlayerID("b"),
    SimulationPlayerID("c"),
  ]

  private func snapshot(sequence: UInt32 = 0) -> StateSnapshot {
    StateSnapshot(
      sequence: sequence,
      tick: 0,
      clockMs: 0,
      players: ids.enumerated().map {
        PlayerSnapshot(
          slot: UInt8($0.offset),
          health: 100,
          lifeState: .alive,
          kills: 0,
          deaths: 0,
          ammo: 8,
          reloadEndsAtMs: nil,
          respawnAtMs: nil,
          spawnProtectedUntilMs: nil,
          fireLocked: false
        )
      }
    )
  }

  func testPredictionGapAndHostLoss() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var client = AuthorityClient(
      slot: 0,
      roster: roster,
      configuration: AuthorityClientConfiguration(hostTimeoutMs: 100)
    )
    XCTAssertEqual(client.phase, .awaitingHost)
    XCTAssertEqual(client.receive(.snapshot(snapshot()), atMs: 0), [
      .snapshotApplied(snapshot())
    ])
    let claim = ShotClaim(
      shotID: "shot",
      shooterID: ids[0],
      targetID: ids[1],
      origin: Vector3.zero,
      direction: Vector3(0, 0, 1),
      firedAtMs: 10
    )
    XCTAssertEqual(client.fire(claim, atMs: 10).count, 1)
    let record = ShotVerdictRecord(
      shot: claim,
      verdict: .miss,
      targetID: ids[1],
      evaluatedAtTick: 1,
      rewindMilliseconds: 0
    )
    let effects = client.receive(
      .verdict(VerdictFrame(sequence: 2, tick: 1, event: .verdict(record))),
      atMs: 25
    )
    XCTAssertTrue(effects.contains(.verdictGap(expected: 1, received: 2)))
    XCTAssertTrue(
      effects.contains(
        .predictionResolved(shotID: "shot", verdict: record, latencyMs: 15)
      )
    )
    XCTAssertEqual(client.advance(nowMs: 126), [.hostLost(atMs: 126)])
    XCTAssertEqual(client.advance(nowMs: 300), [])
    XCTAssertEqual(client.fire(claim, atMs: 300), [.fireRefusedLocally(.hostLost)])
  }

  func testPredictionRefusedAndLateVerdictsAreIgnoredAfterHostLoss() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    var client = AuthorityClient(
      slot: 0,
      roster: roster,
      configuration: AuthorityClientConfiguration(hostTimeoutMs: 10)
    )
    let claim = ShotClaim(
      shotID: "refused",
      shooterID: ids[0],
      targetID: ids[1],
      origin: .zero,
      direction: Vector3(0, 0, 1),
      firedAtMs: 0
    )
    XCTAssertEqual(client.fire(claim, atMs: 0), [.fireRefusedLocally(.awaitingHost)])
    _ = client.receive(.snapshot(snapshot()), atMs: 0)
    XCTAssertEqual(client.fire(claim, atMs: 5).count, 1)
    let refused = SimulationEvent.fireRefused(
      shotID: claim.shotID,
      shooter: ids[0],
      reason: .cooldownActive,
      atTick: 1
    )
    let refusalEffects = client.receive(
      .verdict(VerdictFrame(sequence: 1, tick: 1, event: refused)),
      atMs: 8
    )
    XCTAssertTrue(
      refusalEffects.contains {
        if case .predictionRefused("refused", .cooldownActive, 3) = $0 {
          return true
        }
        return false
      }
    )
    XCTAssertEqual(client.advance(nowMs: 19), [.hostLost(atMs: 19)])
    let appliedCount = client.appliedVerdicts.count
    let lateEffects = client.receive(
      .verdict(VerdictFrame(sequence: 2, tick: 2, event: refused)),
      atMs: 20
    )
    XCTAssertTrue(lateEffects.isEmpty)
    XCTAssertEqual(client.phase, .hostLost)
    XCTAssertEqual(client.appliedVerdicts.count, appliedCount)
  }
}
