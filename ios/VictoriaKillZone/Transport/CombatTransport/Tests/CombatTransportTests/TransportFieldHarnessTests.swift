import Foundation
import XCTest

@testable import CombatTransport

final class TransportFieldHarnessTests: XCTestCase {
  func testHarnessEmitsWellFormedSanitizedSnapshot() throws {
    let fabric = LoopbackFabric(playerCount: 2, seed: 7)
    let harness = TransportFieldHarness(link: fabric.client(slot: 1))
    harness.startHostAndClient()
    try harness.drivePoseCadence(seconds: 1)
    let data = try harness.sanitizedStatsSnapshot()
    let snapshot = try JSONDecoder().decode(TransportStatsSnapshot.self, from: data)
    XCTAssertEqual(snapshot.schema, "transport-stats.v0")
    XCTAssertEqual(snapshot.evidenceTier, .loopbackSimulated)
  }
}
