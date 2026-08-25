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
}
