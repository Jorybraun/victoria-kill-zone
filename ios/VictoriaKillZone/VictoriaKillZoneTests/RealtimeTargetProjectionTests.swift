import XCTest
@testable import VictoriaKillZone

final class RealtimeTargetProjectionTests: XCTestCase {
  func testPortraitViewportUsesActualAspectAndUpperLeftCoordinates() throws {
    let bounds = try XCTUnwrap(RealtimeTargetProjection.bounds(samples: [point(90, 180), point(270, 500)], viewportWidth: 390, viewportHeight: 844))
    XCTAssertEqual(bounds.minX, 78 / 390.0, accuracy: 0.000001)
    XCTAssertEqual(bounds.minY, 168 / 844.0, accuracy: 0.000001)
    XCTAssertEqual(bounds.centerX, 180 / 390.0, accuracy: 0.000001)
    XCTAssertEqual(bounds.centerY, 340 / 844.0, accuracy: 0.000001)
    XCTAssertEqual(bounds.width * 390, 204, accuracy: 0.000001)
    XCTAssertEqual(bounds.height * 844, 344, accuracy: 0.000001)
  }

  func testBehindCameraAndOutsideClippingPlanesCannotMakeTarget() {
    for depth in [-1.0, 1.01, Double.nan, Double.infinity] {
      XCTAssertNil(bounds([point(100, 200, depth), point(200, 500, depth)]))
    }
    XCTAssertNil(bounds([point(100, 200), point(200, 500, -1)]))
  }

  func testAllOffscreenRefusesEvenWhenBoundsWouldCrossViewport() {
    XCTAssertNil(bounds([point(-100, 200), point(500, 500)]))
    XCTAssertNil(bounds([point(100, -50), point(200, -20)]))
  }

  func testPartiallyVisibleTargetClipsWithoutUnboundedFrame() throws {
    let value = try XCTUnwrap(bounds([point(100, 200), point(Double.greatestFiniteMagnitude, 500)]))
    XCTAssertEqual(value.minX, 88 / 390.0, accuracy: 0.000001)
    XCTAssertEqual(value.minX + value.width, 1, accuracy: 0.000001)
    XCTAssertGreaterThanOrEqual(value.minY, 0)
    XCTAssertLessThanOrEqual(value.minY + value.height, 1)
  }

  func testNonfinitePointsAndInvalidViewportsFailClosed() {
    XCTAssertNil(bounds([point(.nan, 200), point(200, 500)]))
    XCTAssertNil(bounds([point(100, .infinity), point(200, 500)]))
    for size in [0.0, -1, .nan, .infinity, 20_000] {
      XCTAssertNil(RealtimeTargetProjection.bounds(samples: [point(100, 200), point(200, 500)], viewportWidth: size, viewportHeight: 844))
    }
    XCTAssertNil(bounds(Array(repeating: point(100, 200), count: 33)))
  }

  private func point(_ x: Double, _ y: Double, _ depth: Double = 0.5) -> RealtimeTargetProjection.Sample {.init(x: x, y: y, depth: depth)}
  private func bounds(_ values: [RealtimeTargetProjection.Sample]) -> NormalizedTargetingRect? {
    RealtimeTargetProjection.bounds(samples: values, viewportWidth: 390, viewportHeight: 844)
  }
}
