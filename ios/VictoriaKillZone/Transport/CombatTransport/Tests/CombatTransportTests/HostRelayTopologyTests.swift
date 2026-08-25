import XCTest

@testable import CombatTransport

final class HostRelayTopologyTests: XCTestCase {
  func testClientRouteIsHostOnlyAtEverySupportedPeerCount() throws {
    for count in 2...4 {
      let topology = try HostRelayTopology(playerCount: count)
      for slot in 1..<UInt8(count) {
        XCTAssertEqual(topology.outboundRoute(for: slot), [0])
      }
      XCTAssertEqual(topology.relayTargets(from: 1), Array(UInt8(2)..<UInt8(count)))
    }
  }

  func testHostFanoutExcludesOriginAndSelf() throws {
    let topology = try HostRelayTopology(playerCount: 4)
    XCTAssertEqual(topology.relayTargets(from: 0), [1, 2, 3])
    XCTAssertEqual(topology.relayTargets(from: 2), [1, 3])
  }

  func testFifthJoinRejectedAndSlotsAreDeterministic() throws {
    var topology = try HostRelayTopology(playerCount: 2)
    XCTAssertEqual(try topology.assignNextSlot(), 2)
    XCTAssertEqual(try topology.assignNextSlot(), 3)
    XCTAssertThrowsError(try topology.assignNextSlot()) { error in
      XCTAssertEqual(error as? TopologyError, .playerCountFull)
    }
  }

  func testFourPlayerFabricRelaysToOtherClientsOnly() throws {
    let fabric = LoopbackFabric(playerCount: 4)
    let frame = PoseFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: 1,
      timestampMs: 1,
      position: SIMD3<Float>(1, 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
    try fabric.client(slot: 1).send(frame)
    fabric.advance(to: 1)
    XCTAssertEqual(fabric.latestPose(for: 1, at: 0)?.sequence, 1)
    XCTAssertNil(fabric.latestPose(for: 1, at: 1))
    XCTAssertEqual(fabric.latestPose(for: 1, at: 2)?.sequence, 1)
    XCTAssertEqual(fabric.latestPose(for: 1, at: 3)?.sequence, 1)
  }

  func testRelayUsesHostDeliveryOrderUnderReorderAndDuplicates() throws {
    let fabric = LoopbackFabric(
      playerCount: 4,
      faultProfile: FaultProfile(
        jitterMs: 40,
        reliableReorderPercent: 100,
        reliableDuplicatePercent: 100
      ),
      seed: 123
    )
    for sequence in 1...40 {
      try fabric.client(slot: 1).send(
        ReliableEventFrame(
          epoch: 1,
          senderSlot: 1,
          sequence: UInt32(sequence),
          eventKind: .fire,
          payload: Data()
        )
      )
    }
    fabric.advance(to: 5_000)
    let expected = Array(UInt32(1)...UInt32(40))
    for receiver in [2, 3] {
      XCTAssertEqual(
        fabric.deliveredReliableEvents(for: 1, at: UInt8(receiver)).map(\.sequence),
        expected
      )
    }
  }

  func testEndpointRejectsExternallyRelayedFrames() throws {
    let endpoint = LoopbackFabric(playerCount: 2).client(slot: 1)
    let frame = TransportFrame.reliable(
      ReliableEventFrame(
        epoch: 1,
        senderSlot: 1,
        sequence: 1,
        eventKind: .fire,
        payload: Data()
      ),
      relayed: true
    )
    XCTAssertThrowsError(try endpoint.send(frame)) { error in
      XCTAssertEqual(error as? LoopbackEndpointError, .relayedFrameNotAllowed)
    }
  }
}
