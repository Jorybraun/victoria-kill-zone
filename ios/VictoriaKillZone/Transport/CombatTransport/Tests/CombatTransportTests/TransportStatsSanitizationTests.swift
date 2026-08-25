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
    XCTAssertEqual(snapshot.evidenceTier, .loopbackSimulated)
    XCTAssertEqual(snapshot.channels.map(\.channel), [.pose, .reliable])
    let data = try stats.sanitizedSnapshotData()
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    XCTAssertEqual(
      Set(object.allKeys.compactMap { $0 as? String }),
      ["schema", "clockSource", "evidenceTier", "channels", "slots", "disconnectCount", "recoveryCount", "fireLockedMilliseconds"]
    )
    XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("UDID"))
  }

  func testPercentilesAndFireLockDurationUseMatchClock() {
    var stats = TransportStats()
    for (time, delay) in [(10, 1), (22, 3), (38, 7), (59, 11), (87, 17)] {
      stats.recordReceived(
        channel: .pose,
        slot: 1,
        accepted: true,
        arrivalMs: Int64(time),
        sentAtMs: Int64(time - delay),
        sequence: UInt32((time / 10) + 1),
        epoch: 1
      )
    }
    stats.setFireLocked(true, at: 100)
    stats.setFireLocked(false, at: 140)
    let snapshot = stats.sanitizedSnapshot()
    XCTAssertEqual(snapshot.channels[0].sendToReceiveP50Ms, 7)
    XCTAssertEqual(snapshot.channels[0].sendToReceiveP95Ms, 11)
    XCTAssertEqual(snapshot.channels[0].jitterP50Ms, 16)
    XCTAssertEqual(snapshot.channels[0].jitterP95Ms, 21)
    XCTAssertEqual(snapshot.fireLockedMilliseconds, 40)
  }

  func testSequenceGapLossAndDeliveryCountersAreObserved() {
    var stats = TransportStats()
    for sequence in [1, 2, 4, 5] {
      stats.recordReceived(
        channel: .pose,
        slot: 1,
        accepted: sequence != 4,
        duplicate: sequence == 5,
        buffered: sequence == 4,
        sequence: UInt32(sequence),
        epoch: 1
      )
    }
    let snapshot = stats.sanitizedSnapshot()
    XCTAssertEqual(snapshot.channels[0].sequenceGapLossPercent, 25)
    XCTAssertEqual(snapshot.channels[0].duplicate, 1)
    XCTAssertEqual(snapshot.channels[0].buffered, 1)
    XCTAssertEqual(snapshot.channels[0].received, 4)
  }
}
