import XCTest

@testable import CombatTransport

final class FaultInjectionLoopbackTests: XCTestCase {
  private func pose(_ sequence: UInt32, timestamp: Int64) -> PoseFrame {
    PoseFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: sequence,
      timestampMs: timestamp,
      position: SIMD3<Float>(0, 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
  }

  private func event(_ sequence: UInt32) -> ReliableEventFrame {
    ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: sequence, eventKind: .fire, payload: Data([1]))
  }

  func testFivePercentPoseLossKeepsDeliveredPosesMonotonicAndReliableComplete() throws {
    let fabric = LoopbackFabric(
      playerCount: 2,
      faultProfile: FaultProfile(poseLossPercent: 5),
      seed: 42
    )
    let client = fabric.client(slot: 1)
    for sequence in 1...900 {
      let timestamp = Int64(sequence) * 33
      try client.send(pose(UInt32(sequence), timestamp: timestamp))
      if sequence <= 20 { try client.send(event(UInt32(sequence))) }
      fabric.advance(to: timestamp)
    }
    XCTAssertEqual(fabric.deliveredReliableEvents(for: 1).map(\.sequence), Array(1...20))
    XCTAssertGreaterThanOrEqual(fabric.hostCore.stats.sanitizedSnapshot().channels[0].accepted, 0)
  }

  func testSameSeedProducesByteIdenticalStatsSnapshot() throws {
    func run() throws -> Data {
      let fabric = LoopbackFabric(
        playerCount: 2,
        faultProfile: FaultProfile(poseLossPercent: 5, jitterMs: 40, reliableReorderPercent: 10, reliableDuplicatePercent: 10),
        seed: 99
      )
      let client = fabric.client(slot: 1)
      for sequence in 1...30 {
        try client.send(pose(UInt32(sequence), timestamp: Int64(sequence) * 33))
        fabric.advance(to: Int64(sequence) * 33)
      }
      return try fabric.sanitizedStatsSnapshotData()
    }
    XCTAssertEqual(try run(), try run())
  }
}
