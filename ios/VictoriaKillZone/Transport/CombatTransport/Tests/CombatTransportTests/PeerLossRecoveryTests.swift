import XCTest

@testable import CombatTransport

final class PeerLossRecoveryTests: XCTestCase {
  func testDisconnectAndRecoveryEffectsAreDeterministic() throws {
    var topology = try HostRelayTopology(playerCount: 2)
    XCTAssertEqual(
      try topology.disconnect(slot: 1),
      [.peerDisconnected(slot: 1), .fireLockEngaged]
    )
    XCTAssertTrue(topology.fireLocked)
    XCTAssertEqual(
      try topology.recover(slot: 1),
      [.peerRecovered(slot: 1), .fireLockReleased]
    )
    XCTAssertFalse(topology.fireLocked)
  }

  func testFabricTimeoutRecoveryBumpsEpochAndResumesTraffic() throws {
    let fabric = LoopbackFabric(playerCount: 4)
    for slot in [2, 3] {
      try fabric.client(slot: UInt8(slot)).send(
        PoseFrame(
          epoch: 1,
          senderSlot: UInt8(slot),
          sequence: 1,
          timestampMs: 1,
          position: SIMD3<Float>(0, 0, 0),
          orientation: SIMD4<Float>(0, 0, 0, 1),
          tracking: .normal
        )
      )
    }
    fabric.advance(to: 1)
    fabric.advance(to: 1_001)
    XCTAssertTrue(fabric.hostCore.fireLocked)
    XCTAssertEqual(
      fabric.hostCore.lastEffects,
      [.peerDisconnected(slot: 1), .fireLockEngaged]
    )
    XCTAssertEqual(fabric.hostCore.stats.sanitizedSnapshot().disconnectCount, 1)

    _ = try fabric.recover(slot: 1)
    XCTAssertEqual(fabric.epoch(for: 1), 2)
    XCTAssertFalse(fabric.hostCore.fireLocked)
    XCTAssertEqual(fabric.hostCore.stats.sanitizedSnapshot().recoveryCount, 1)
    let frame = PoseFrame(
      epoch: 2,
      senderSlot: 1,
      sequence: 1,
      timestampMs: 1_002,
      position: SIMD3<Float>(0, 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
    try fabric.client(slot: 1).send(frame)
    fabric.advance(to: 1_002)
    XCTAssertEqual(fabric.latestPose(for: 1)?.sequence, 1)
  }
}
