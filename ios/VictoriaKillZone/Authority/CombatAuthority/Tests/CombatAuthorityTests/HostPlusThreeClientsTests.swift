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
      Vector3(1, 0, 0),
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
              targetID: ids[Int(targetByShooter[index])],
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
    for adapter in adapters {
      XCTAssertTrue(adapter.latency.count > 0)
      if faultProfile.baseLatencyMs > 0 {
        XCTAssertLessThanOrEqual(
          adapter.latency.report.p95Ms ?? .max,
          Int64(faultProfile.baseLatencyMs * 2 + 50)
        )
      }
    }
  }
}
