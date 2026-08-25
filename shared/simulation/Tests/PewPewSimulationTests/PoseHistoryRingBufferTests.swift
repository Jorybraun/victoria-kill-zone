import XCTest

@testable import PewPewSimulation

final class PoseHistoryRingBufferTests: XCTestCase {
  func testRecordsInMonotonicOrderAndDropsRegressions() {
    var buffer = PoseHistoryRingBuffer(capacity: 4)

    XCTAssertTrue(buffer.record(PoseSample(timestampMs: 100, position: .zero)))
    XCTAssertTrue(buffer.record(PoseSample(timestampMs: 150, position: Vector3(1, 0, 0))))
    XCTAssertFalse(buffer.record(PoseSample(timestampMs: 150, position: Vector3(2, 0, 0))))
    XCTAssertFalse(buffer.record(PoseSample(timestampMs: 120, position: Vector3(3, 0, 0))))

    XCTAssertEqual(buffer.count, 2)
    XCTAssertEqual(buffer.latest?.timestampMs, 150)
    XCTAssertEqual(buffer.latest?.position, Vector3(1, 0, 0))
  }

  func testEvictsOldestOnceFull() {
    var buffer = PoseHistoryRingBuffer(capacity: 3)
    for index in 1...5 {
      buffer.record(PoseSample(timestampMs: Int64(index) * 50, position: .zero))
    }

    XCTAssertEqual(buffer.count, 3)
    XCTAssertNil(buffer.sample(atOrBefore: 100))
    XCTAssertEqual(buffer.sample(atOrBefore: 150)?.timestampMs, 150)
    XCTAssertEqual(buffer.latest?.timestampMs, 250)
  }

  func testSampleAtOrBeforeFindsNewestQualifyingSample() {
    var buffer = PoseHistoryRingBuffer(capacity: 8)
    buffer.record(PoseSample(timestampMs: 100, position: Vector3(1, 0, 0)))
    buffer.record(PoseSample(timestampMs: 200, position: Vector3(2, 0, 0)))
    buffer.record(PoseSample(timestampMs: 300, position: Vector3(3, 0, 0)))

    XCTAssertNil(buffer.sample(atOrBefore: 99))
    XCTAssertEqual(buffer.sample(atOrBefore: 100)?.position, Vector3(1, 0, 0))
    XCTAssertEqual(buffer.sample(atOrBefore: 250)?.position, Vector3(2, 0, 0))
    XCTAssertEqual(buffer.sample(atOrBefore: 300)?.position, Vector3(3, 0, 0))
    XCTAssertEqual(buffer.sample(atOrBefore: 10_000)?.position, Vector3(3, 0, 0))
  }

  func testEmptyBufferHasNoSamples() {
    let buffer = PoseHistoryRingBuffer(capacity: 4)

    XCTAssertEqual(buffer.count, 0)
    XCTAssertNil(buffer.latest)
    XCTAssertNil(buffer.sample(atOrBefore: 1_000))
  }

  func testResolvePoseReturnsExactSample() {
    var buffer = PoseHistoryRingBuffer(capacity: 4)
    let sample = PoseSample(timestampMs: 100, position: Vector3(1, 2, 3))
    buffer.record(sample)

    XCTAssertEqual(buffer.resolvePose(atMs: 100), .exact(sample))
  }

  func testResolvePoseInterpolatesBracketingSamples() {
    var buffer = PoseHistoryRingBuffer(capacity: 4)
    let earlier = PoseSample(timestampMs: 100, position: Vector3(0, 0, 0))
    let later = PoseSample(timestampMs: 200, position: Vector3(2, 4, 6))
    buffer.record(earlier)
    buffer.record(later)

    XCTAssertEqual(
      buffer.resolvePose(atMs: 150),
      .interpolated(position: Vector3(1, 2, 3), earlier: earlier, later: later)
    )
  }

  func testResolvePoseReturnsTrailingEdgeWithoutLaterSample() {
    var buffer = PoseHistoryRingBuffer(capacity: 4)
    let sample = PoseSample(timestampMs: 100, position: .zero)
    buffer.record(sample)

    XCTAssertEqual(buffer.resolvePose(atMs: 150), .trailingEdge(sample))
  }

  func testResolvePoseReturnsUnavailableWithoutEarlierSample() {
    var buffer = PoseHistoryRingBuffer(capacity: 4)
    buffer.record(PoseSample(timestampMs: 100, position: .zero))

    XCTAssertEqual(buffer.resolvePose(atMs: 50), .unavailable)
  }
}
