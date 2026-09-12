import XCTest
import CombatAuthority
import CombatTransport
import PewPewSimulation

final class HostPlusThreeClientsTests: XCTestCase {
  private let ids = [
    SimulationPlayerID("a"),
    SimulationPlayerID("b"),
    SimulationPlayerID("c"),
    SimulationPlayerID("d"),
  ]

  func testFourPlayerVerdictsRemainIdenticalWithTransportFaults() throws {
    try runMatch(faultProfile: FaultProfile())
    try runMatch(
      faultProfile: FaultProfile(
        poseLossPercent: 10,
        jitterMs: 15,
        reliableReorderPercent: 20,
        reliableDuplicatePercent: 10,
        baseLatencyMs: 20
      )
    )
  }

  func testMemberDropLocksFireAndRecoveryUnlocks() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    let fabric = LoopbackFabric(playerCount: 4)
    let adapters = try makeAdapters(roster: roster, fabric: fabric)
    let positions = [
      Vector3(0, 0, 0), Vector3(0, 0, 4),
      Vector3(4, 0, 0), Vector3(-4, 0, 0),
    ]
    for nowMs in stride(from: Int64(0), through: 1_500, by: 10) {
      if nowMs > 0, nowMs % 50 == 0 {
        for (index, adapter) in adapters.enumerated() {
          if index == 2, nowMs > 700, nowMs <= 1_100 { continue }
          try adapter.pose(PoseSample(timestampMs: nowMs, position: positions[index]))
        }
      }
      fabric.advance(to: nowMs)
      if nowMs == 700 {
        let effects = try fabric.disconnect(slot: 2)
        adapters[0].applyTransportEffects(effects, atMs: nowMs)
        XCTAssertEqual(adapters[0].host?.fireLockedSlots, [2])
      }
      if nowMs == 800 {
        try adapters[2].fire(
          ShotClaim(
            shotID: "shot-2",
            shooterID: ids[2],
            origin: positions[2],
            direction: Vector3(1, 0, 0),
            firedAtMs: nowMs
          ),
          atMs: nowMs
        )
      }
      if nowMs == 1_000 {
        for adapter in adapters {
          XCTAssertFalse(
            adapter.client.appliedVerdicts.contains {
              guard case let .verdict(record) = $0.event else { return false }
              return record.shot.shotID == "shot-2"
            }
          )
        }
        XCTAssertFalse(
          adapters[0].host?.verdictLog.contains {
            guard case let .verdict(record) = $0.event else { return false }
            return record.shot.shooterID == ids[2]
          } ?? false
        )
      }
      if nowMs == 1_100 {
        let effects = try fabric.recover(slot: 2)
        adapters[0].applyTransportEffects(effects, atMs: nowMs)
        adapters[2].resetEpoch(fabric.epoch(for: 2))
      }
      if nowMs == 1_200 {
        XCTAssertEqual(adapters[2].client.players[2]?.fireLocked, false)
        try adapters[2].fire(
          ShotClaim(
            shotID: "shot-2",
            shooterID: ids[2],
            targetID: ids[0],
            origin: positions[2],
            direction: Vector3(-1, 0, 0),
            firedAtMs: nowMs
          ),
          atMs: nowMs
        )
      }
      for adapter in adapters {
        try adapter.advance(nowMs: nowMs)
      }
      fabric.advance(to: nowMs)
    }
    fabric.advance(to: 2_000)
    for adapter in adapters {
      try adapter.advance(nowMs: 2_000)
    }
    fabric.advance(to: 2_000)

    for adapter in adapters {
      XCTAssertFalse(adapter.client.players[2]?.fireLocked ?? true)
      XCTAssertEqual(adapter.client.appliedVerdicts, adapters[0].client.appliedVerdicts)
      XCTAssertTrue(
        adapter.client.appliedVerdicts.contains {
          if case let .verdict(record) = $0.event {
            return record.shot.shotID == "shot-2"
          }
          return false
        }
      )
    }
  }

  func testHostDropFreezesClientsAsHostLost() throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    let fabric = LoopbackFabric(playerCount: 4)
    let adapters = try makeAdapters(roster: roster, fabric: fabric)
    let positions = [
      Vector3(0, 0, 0), Vector3(0, 0, 4),
      Vector3(4, 0, 0), Vector3(-4, 0, 0),
    ]
    for nowMs in stride(from: Int64(0), through: 600, by: 10) {
      if nowMs > 0, nowMs % 50 == 0 {
        for (index, adapter) in adapters.enumerated() {
          try adapter.pose(PoseSample(timestampMs: nowMs, position: positions[index]))
        }
      }
      fabric.advance(to: nowMs)
      for adapter in adapters {
        try adapter.advance(nowMs: nowMs)
      }
      fabric.advance(to: nowMs)
    }
    for nowMs in stride(from: Int64(610), through: 3_000, by: 10) {
      fabric.advance(to: nowMs)
      for adapter in adapters.dropFirst() {
        try adapter.advance(nowMs: nowMs)
      }
      fabric.advance(to: nowMs)
    }

    let claim = ShotClaim(
      shotID: "after-host-drop",
      shooterID: ids[1],
      origin: positions[1],
      direction: Vector3(0, 0, -1),
      firedAtMs: 3_000
    )
    for adapter in adapters.dropFirst() {
      let effects = adapter.drainClientEffects()
      XCTAssertEqual(effects.filter {
        if case .hostLost = $0 { return true }
        return false
      }.count, 1)
      XCTAssertEqual(adapter.client.phase, .hostLost)
      try adapter.fire(claim, atMs: 3_000)
      XCTAssertTrue(
        adapter.drainClientEffects().contains {
          $0 == .fireRefusedLocally(.hostLost)
        }
      )
    }
  }

  private func runMatch(faultProfile: FaultProfile) throws {
    let roster = try AuthorityRoster(playerIDs: ids)
    let fabric = LoopbackFabric(
      playerCount: 4,
      faultProfile: faultProfile,
      seed: 42
    )
    let links: [LoopbackEndpoint] = [
      fabric.host,
      fabric.client(slot: 1),
      fabric.client(slot: 2),
      fabric.client(slot: 3),
    ]
    let adapters = try links.enumerated().map { index, link in
      try AuthorityPeerAdapter(slot: UInt8(index), roster: roster, link: link)
    }
    let positions = [
      Vector3(0, 0, 0),
      Vector3(0, 0, 4),
      Vector3(4, 0, 0),
      Vector3(-4, 0, 0),
    ]
    let targetByShooter: [UInt8] = [1, 0, 0, 0]
    let directions = [
      Vector3(0, 0, 1),
      Vector3(0, 0, -1),
      Vector3(-1, 0, 0),
      Vector3(0, 1, 0),
    ]

    for nowMs in stride(from: Int64(0), through: 1_500, by: 10) {
      if nowMs % 50 == 0, nowMs > 0 {
        for (index, adapter) in adapters.enumerated() {
          try adapter.pose(
            PoseSample(
              timestampMs: nowMs,
              position: positions[index]
            )
          )
        }
      }
      if nowMs == 600 {
        for (index, adapter) in adapters.enumerated() {
          try adapter.fire(
            ShotClaim(
              shotID: "shot-\(index)",
              shooterID: ids[index],
              targetID: index == 3 ? nil : ids[Int(targetByShooter[index])],
              origin: positions[index],
              direction: directions[index],
              firedAtMs: nowMs
            ),
            atMs: nowMs
          )
        }
      }
      fabric.advance(to: nowMs)
      for adapter in adapters {
        try adapter.advance(nowMs: nowMs)
      }
      fabric.advance(to: nowMs)
    }
    fabric.advance(to: 2_000)
    for adapter in adapters {
      try adapter.advance(nowMs: 2_000)
    }
    fabric.advance(to: 2_000)

    let expected = adapters[0].client.appliedVerdicts
    XCTAssertFalse(expected.isEmpty)
    for adapter in adapters {
      XCTAssertEqual(adapter.client.appliedVerdicts, expected)
    }
    XCTAssertEqual(adapters[0].host?.verdictLog, expected)
    XCTAssertTrue(
      expected.contains {
        if case .verdict(let record) = $0.event {
          if case .hit = record.verdict { return true }
        }
        return false
      }
    )
    XCTAssertTrue(
      expected.contains {
        if case .verdict(let record) = $0.event {
          if case .miss = record.verdict { return true }
        }
        return false
      }
    )
    for adapter in adapters {
      XCTAssertTrue(adapter.client.pendingPredictions.isEmpty)
      XCTAssertTrue(adapter.latency.count > 0)
      if faultProfile.baseLatencyMs > 0 {
        XCTAssertLessThanOrEqual(
          adapter.latency.report.p95Ms ?? .max,
          Int64(faultProfile.baseLatencyMs * 2 + 50)
        )
      }
    }
  }

  private func makeAdapters(
    roster: AuthorityRoster,
    fabric: LoopbackFabric
  ) throws -> [AuthorityPeerAdapter] {
    let links: [LoopbackEndpoint] = [
      fabric.host,
      fabric.client(slot: 1),
      fabric.client(slot: 2),
      fabric.client(slot: 3),
    ]
    return try links.enumerated().map { index, link in
      try AuthorityPeerAdapter(slot: UInt8(index), roster: roster, link: link)
    }
  }
}
