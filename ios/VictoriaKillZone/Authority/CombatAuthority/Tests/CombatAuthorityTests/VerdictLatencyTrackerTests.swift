import XCTest
import CombatAuthority

final class VerdictLatencyTrackerTests: XCTestCase {
  func testNearestRankPercentilesAndBoundedRing() {
    var tracker = VerdictLatencyTracker()
    for value in 1...4_100 {
      tracker.record(latencyMs: Int64(value))
    }
    XCTAssertEqual(tracker.count, 4_096)
    XCTAssertEqual(tracker.percentile(0.50), 2_052)
    XCTAssertEqual(tracker.percentile(0.95), 3_896)
    XCTAssertEqual(tracker.percentile(0.99), 4_060)
    XCTAssertNil(tracker.percentile(0))
    XCTAssertEqual(tracker.report.maxMs, 4_100)
  }
}
