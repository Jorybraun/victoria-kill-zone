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

  func testLowWaterReleaseIsExposedByTopology() throws {
    var topology = try HostRelayTopology(playerCount: 2)
    _ = topology.markReliableGapUnrecoverable(slot: 1)
    XCTAssertTrue(topology.fireLocked)
    XCTAssertEqual(try topology.recover(slot: 1), [.peerRecovered(slot: 1)])
    XCTAssertEqual(
      topology.advance(
        nowMs: 1,
        reliableChannelsInOrder: true,
        poseQueueCount: 0,
        reliableQueueCount: 0,
        lowWaterMark: 0
      ),
      [.fireLockReleased]
    )
    XCTAssertFalse(topology.fireLocked)
  }
}
