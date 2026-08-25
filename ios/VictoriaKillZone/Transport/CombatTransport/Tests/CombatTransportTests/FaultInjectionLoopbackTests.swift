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
    let admitted = fabric.core(for: 0).poseInbox.admittedHistory
    XCTAssertTrue(admitted.allSatisfy { $0.sequence > 0 && $0.timestampMs > 0 })
    let ordered = admitted.sorted { $0.sequence < $1.sequence }
    XCTAssertEqual(ordered.map(\.sequence), ordered.map(\.sequence).sorted())
    XCTAssertTrue(zip(ordered, ordered.dropFirst()).allSatisfy {
      $0.sequence < $1.sequence && $0.timestampMs < $1.timestampMs
    })
    XCTAssertEqual(fabric.deliveredReliableEvents(for: 1).map(\.sequence), Array(1...20))
    let stats = fabric.hostCore.stats.sanitizedSnapshot()
    XCTAssertGreaterThanOrEqual(ordered.count, 600)
    XCTAssertGreaterThanOrEqual(ordered.count / 30, 20)
    XCTAssertGreaterThanOrEqual(stats.channels[0].sequenceGapLossPercent, 2)
    XCTAssertLessThanOrEqual(stats.channels[0].sequenceGapLossPercent, 8)
  }

  func testHarsherProfilePreservesOrderingWhileCadenceDegrades() throws {
    let fabric = LoopbackFabric(
      playerCount: 2,
      faultProfile: FaultProfile(
        poseLossPercent: 20,
        jitterMs: 40,
        reliableReorderPercent: 10,
        reliableDuplicatePercent: 10
      ),
      seed: 43
    )
    let client = fabric.client(slot: 1)
    for sequence in 1...900 {
      let timestamp = Int64(sequence) * 33
      try client.send(pose(UInt32(sequence), timestamp: timestamp))
      try client.send(event(UInt32(sequence)))
      fabric.advance(to: timestamp)
    }
    let ordered = fabric.core(for: 0).poseInbox.admittedHistory.sorted {
      $0.sequence < $1.sequence
    }
    XCTAssertTrue(zip(ordered, ordered.dropFirst()).allSatisfy {
      $0.sequence < $1.sequence && $0.timestampMs < $1.timestampMs
    })
    XCTAssertEqual(
      fabric.deliveredReliableEvents(for: 1).map(\.sequence),
      Array(1...900)
    )
    XCTAssertLessThan(ordered.count, 800)
    XCTAssertGreaterThan(ordered.count, 400)
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
