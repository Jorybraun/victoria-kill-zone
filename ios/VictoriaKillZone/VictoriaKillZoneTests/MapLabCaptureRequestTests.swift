import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class MapLabCaptureRequestTests: XCTestCase {
  func testTimeoutThenRetryRejectsOldMapArchiveTimerAndCancellationCompletions() async throws {
    let owner = MapLabCaptureRequest(), a = UUID(), b = UUID()
    let first = Task {
      try await withCheckedThrowingContinuation { owner.begin(a, continuation: $0) }
    }
    try await until { owner.contains(a) }
    XCTAssertTrue(owner.finish(.failure(MapLabFailure.timedOut), request: a))
    do { _ = try await first.value; XCTFail("Capture A must time out") }
    catch { XCTAssertEqual(error as? MapLabFailure, .timedOut) }

    var retryResolved = false
    let retry = Task {
      let bytes = try await withCheckedThrowingContinuation { owner.begin(b, continuation: $0) }
      retryResolved = true
      return bytes
    }
    try await until { owner.contains(b) }
    // These are the same request checks and continuation completion boundary used
    // by getCurrentWorldMap, archive completion, timeout and cancellation in the driver.
    XCTAssertFalse(owner.contains(a), "A late map callback cannot launch an archive for B")
    XCTAssertFalse(owner.finish(.success(Data([1])), request: a), "A late archive cannot resolve B")
    XCTAssertFalse(owner.finish(.failure(MapLabFailure.timedOut), request: a), "A late timer cannot time out B")
    XCTAssertFalse(owner.finish(.failure(CancellationError()), request: a), "A late cancellation cannot cancel B")
    XCTAssertFalse(retryResolved)
    XCTAssertTrue(owner.contains(b))
    XCTAssertTrue(owner.finish(.success(Data([2])), request: b))
    let result = try await retry.value
    XCTAssertEqual(result, Data([2]))
    XCTAssertTrue(retryResolved); XCTAssertNil(owner.activeID)
    XCTAssertFalse(owner.finish(.success(Data([3])), request: b), "A completed request cannot resume twice")
  }

  func testOverlappingCaptureIsRejectedWithoutReplacingItsCurrentContinuation() async throws {
    let owner = MapLabCaptureRequest(), a = UUID(), b = UUID()
    let first = Task { try await withCheckedThrowingContinuation { owner.begin(a, continuation: $0) } }
    try await until { owner.contains(a) }
    do {
      _ = try await withCheckedThrowingContinuation { owner.begin(b, continuation: $0) }
      XCTFail("Only one map capture may be pending")
    } catch { XCTAssertEqual(error as? MapLabFailure, .notReady) }
    XCTAssertTrue(owner.contains(a))
    XCTAssertTrue(owner.finish(.success(Data([4])), request: a))
    let result = try await first.value
    XCTAssertEqual(result, Data([4]))
  }

  private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      guard ContinuousClock.now < deadline else { XCTFail("Capture request did not enter its controlled suspension"); throw MapLabFailure.timedOut }
      await Task.yield()
    }
  }
}
