import XCTest

@testable import CombatTransport

final class BoundedQueueBackpressureTests: XCTestCase {
  private func pose(_ sequence: UInt32) -> PoseFrame {
    PoseFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: sequence,
      timestampMs: Int64(sequence),
      position: SIMD3<Float>(0, 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
  }

  private func event(_ sequence: UInt32) -> ReliableEventFrame {
    ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: sequence, eventKind: .fire, payload: Data())
  }

  func testPoseQueueDropsOldestAndCountsFreshnessDrops() {
    var queue = PoseSendQueue()
    _ = queue.enqueue(pose(1))
    _ = queue.enqueue(pose(2))
    _ = queue.enqueue(pose(3))
    XCTAssertEqual(queue.enqueue(pose(4)), .droppedOldest)
    XCTAssertEqual(queue.posesDroppedForFreshness, 1)
    XCTAssertEqual(queue.dequeue()?.sequence, 2)
  }

  func testReliableQueueNeverDropsAndRejectsAtCapacity() {
    var queue = ReliableSendQueue(capacity: 2)
    XCTAssertEqual(queue.enqueue(event(1)), .enqueued)
    XCTAssertEqual(queue.enqueue(event(2)), .enqueued)
    XCTAssertEqual(queue.enqueue(event(3)), .rejectedQueueFull)
    XCTAssertEqual(queue.dequeue()?.sequence, 1)
  }

  func testCoreReliableQueueOverflowEngagesTopologyFireLock() {
    let topology = try! HostRelayTopology(playerCount: 2)
    var core = CombatTransportCore(slot: 0, topology: topology)
    for sequence in 1...128 {
      XCTAssertEqual(core.enqueueReliable(event(UInt32(sequence))), .enqueued)
    }
    XCTAssertEqual(core.enqueueReliable(event(129)), .rejectedQueueFull)
    XCTAssertTrue(core.fireLocked)
    XCTAssertEqual(core.lastEffects.last, .fireLockEngaged)
  }

  func testLowWaterReleaseIsExposedByTopology() throws {
    var topology = try HostRelayTopology(playerCount: 2, peerTimeoutMs: 100_000)
    _ = topology.markReliableGapUnrecoverable(slot: 1)
    XCTAssertTrue(topology.fireLocked)
    XCTAssertEqual(
      try topology.recover(slot: 1),
      [.peerRecovered(slot: 1), .fireLockReleased]
    )
    XCTAssertFalse(topology.fireLocked)
  }

  func testUnrecoverableGapLockStaysLatchedAcrossAdvances() throws {
    var topology = try HostRelayTopology(playerCount: 2, peerTimeoutMs: 100_000)
    XCTAssertEqual(
      topology.markReliableGapUnrecoverable(slot: 1),
      [.reliableGapUnrecoverable(slot: 1), .fireLockEngaged]
    )
    for nowMs in stride(from: Int64(1), through: 10_000, by: 1_000) {
      XCTAssertTrue(
        topology.advance(
          nowMs: nowMs,
          poseQueueCount: 0,
          reliableQueueCount: 0
        ).isEmpty
      )
      XCTAssertTrue(topology.fireLocked)
    }
    XCTAssertEqual(try topology.recover(slot: 1), [.peerRecovered(slot: 1), .fireLockReleased])
    XCTAssertFalse(topology.fireLocked)
  }

  func testReliableQueueLatchWaitsForLowWaterQueues() throws {
    var topology = try HostRelayTopology(playerCount: 2)
    _ = topology.rejectReliableQueueFull()
    XCTAssertTrue(topology.fireLocked)
    XCTAssertTrue(
      topology.advance(
        nowMs: 1,
        poseQueueCount: 2,
        reliableQueueCount: 2
      ).isEmpty
    )
    XCTAssertTrue(topology.fireLocked)
    XCTAssertEqual(
      topology.advance(nowMs: 2, poseQueueCount: 1, reliableQueueCount: 1),
      [.fireLockReleased]
    )
    XCTAssertFalse(topology.fireLocked)
  }
}
