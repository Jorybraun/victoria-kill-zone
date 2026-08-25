import Foundation
import XCTest

@testable import CombatTransport

final class TransportStatsSanitizationTests: XCTestCase {
  func testSnapshotSchemaAndKeySurfaceAreSanitized() throws {
    var stats = TransportStats()
    stats.recordSent(channel: .pose, slot: 1)
    stats.recordReceived(channel: .pose, slot: 1, accepted: true, arrivalMs: 10, sentAtMs: 5)
    let snapshot = stats.sanitizedSnapshot()
    XCTAssertEqual(snapshot.schema, "transport-stats.v0")
    XCTAssertEqual(snapshot.clockSource, "virtual-match-ms")
    XCTAssertEqual(snapshot.channels.map(\.channel), [.pose, .reliable])
    let data = try stats.sanitizedSnapshotData()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    XCTAssertEqual(
      Set(object.allKeys.compactMap { $0 as? String }),
      ["schema", "clockSource", "channels", "slots", "disconnectCount", "recoveryCount", "fireLockedMilliseconds"]
    )
    XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("UDID"))
  }

  func testPercentilesAndFireLockDurationUseMatchClock() {
    var stats = TransportStats()
    for time in [10, 20, 30, 40, 50] {
      stats.recordReceived(channel: .pose, slot: 1, accepted: true, arrivalMs: Int64(time), sentAtMs: Int64(time - 5))
    }
    stats.setFireLocked(true, at: 100)
    stats.setFireLocked(false, at: 140)
    let snapshot = stats.sanitizedSnapshot()
    XCTAssertEqual(snapshot.channels[0].sendToReceiveP50Ms, 5)
    XCTAssertEqual(snapshot.channels[0].sendToReceiveP95Ms, 5)
    XCTAssertEqual(snapshot.fireLockedMilliseconds, 40)
  }
}
