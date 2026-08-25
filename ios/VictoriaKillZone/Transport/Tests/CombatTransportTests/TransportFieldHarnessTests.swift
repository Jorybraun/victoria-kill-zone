import Foundation
import XCTest

@testable import CombatTransport

final class TransportFieldHarnessTests: XCTestCase {
  func testHarnessEmitsWellFormedSanitizedSnapshot() throws {
    let harness = TransportFieldHarness(seed: 7)
    harness.startHostAndClient()
    try harness.drivePoseCadence(seconds: 1)
    let data = try harness.sanitizedStatsSnapshot()
    let snapshot = try JSONDecoder().decode(TransportStatsSnapshot.self, from: data)
    XCTAssertEqual(snapshot.schema, "transport-stats.v0")
  }
}
