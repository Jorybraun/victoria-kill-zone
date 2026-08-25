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
}
