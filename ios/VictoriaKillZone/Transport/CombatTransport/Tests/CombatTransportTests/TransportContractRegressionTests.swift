import XCTest

@testable import CombatTransport

final class TransportContractRegressionTests: XCTestCase {
  func testLoopbackRejectsStalePosesAndDeliversReliableFireExactlyOnceInOrder() throws {
    let fabric = LoopbackFabric(
      playerCount: 2,
      faultProfile: FaultProfile(poseLossPercent: 5),
      seed: 0xC0FFEE
    )
    let host = fabric.host
    let client = fabric.client(slot: 1)

    try client.send(
      PoseFrame(
        epoch: 1,
        senderSlot: 1,
        sequence: 2,
        timestampMs: 2_000,
        position: SIMD3<Float>(1, 2, 3),
        orientation: SIMD4<Float>(0, 0, 0, 1),
        tracking: .normal
      )
    )
    try client.send(
      PoseFrame(
        epoch: 1,
        senderSlot: 1,
        sequence: 1,
        timestampMs: 1_000,
        position: SIMD3<Float>(9, 9, 9),
        orientation: SIMD4<Float>(0, 0, 0, 1),
        tracking: .normal
      )
    )

    for sequence in 1...3 {
      try client.send(
        ReliableEventFrame(
          epoch: 1,
          senderSlot: 1,
          sequence: UInt32(sequence),
          eventKind: .fire,
          payload: Data([UInt8(sequence)])
        )
      )
    }

    fabric.advance(to: 2_000)

    XCTAssertEqual(host.latestPose(for: 1)?.sequence, 2)
    XCTAssertEqual(
      host.deliveredReliableEvents(for: 1).map(\.sequence),
      [1, 2, 3]
    )
  }
}
