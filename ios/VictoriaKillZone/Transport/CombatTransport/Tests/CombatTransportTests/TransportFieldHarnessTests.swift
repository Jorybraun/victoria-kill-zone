import Foundation
import XCTest

@testable import CombatTransport

final class TransportFieldHarnessTests: XCTestCase {
  func testHarnessEmitsWellFormedSanitizedSnapshot() throws {
    let fabric = LoopbackFabric(
      playerCount: 3,
      faultProfile: FaultProfile(poseLossPercent: 20),
      seed: 7
    )
    let harness = TransportFieldHarness(link: fabric.client(slot: 2))
    harness.startHostAndClient()
    try harness.drivePoseCadence(seconds: 1)
    fabric.advance(to: 1_000)
    let data = try harness.sanitizedStatsSnapshot()
    let snapshot = try JSONDecoder().decode(TransportStatsSnapshot.self, from: data)
    XCTAssertEqual(snapshot.schema, "transport-stats.v0")
    XCTAssertEqual(snapshot.evidenceTier, .loopbackSimulated)
    let pose = try XCTUnwrap(snapshot.channels.first { $0.channel == .pose })
    XCTAssertGreaterThan(pose.received, 0)
    XCTAssertGreaterThan(pose.sequenceGapLossPercent, 0)
  }
}
