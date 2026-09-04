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
    XCTAssertEqual(host.memberRecovered(1, atMs: 201), [
      .memberFireUnlocked(slot: 1)
    ])
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
}
