import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class MapLabCaptureRequestTests: XCTestCase {
  func testCompletedArchiveSurvivesScanQualityDipAfterFreshReadyCaptureStarted() async throws {
    for tracking in [MapLabFrameTracking.normal, .limited(.moveSlowly)] {
      var policy = MapLabFramePolicy()
      let token = policy.begin(.capture, at: 0)
      policy.receive(MapLabFrameSample(timestamp: 0.1, capturedAt: 0.1, tracking: .normal, usableMap: true),
        generation: token, at: 0.1)
      XCTAssertEqual(policy.state, .scanning(feedback: .ready, canSave: true))
      let owner = MapLabCaptureRequest(), request = UUID()
      let capture = Task { try await withCheckedThrowingContinuation { owner.begin(request, continuation: $0) } }
      try await until { owner.contains(request) }

      // The archive is still encoding when another delivered camera frame makes
      // a new capture unavailable. Finish through the driver's actual boundary.
      policy.receive(MapLabFrameSample(timestamp: 0.2, capturedAt: 0.2, tracking: tracking, usableMap: false),
        generation: token, at: 0.2)
      let expectedFeedback: MapLabFeedback = tracking == .normal ? .mapping : .moveSlowly
      XCTAssertEqual(policy.state, .scanning(feedback: expectedFeedback, canSave: false))
      XCTAssertTrue(owner.finishArchive(.success(Data([1, 2, 3])), request: request, state: policy.state))
      let bytes = try await capture.value
      XCTAssertEqual(bytes, Data([1, 2, 3]))
      XCTAssertNil(owner.activeID)
      XCTAssertEqual(policy.state, .scanning(feedback: expectedFeedback, canSave: false),
        "Saving already captured bytes must not renew camera readiness")
    }
  }

  func testArchiveCompletionCannotSucceedAfterScanAttemptStopsInterruptsOrTimesOut() async throws {
    let cases: [(MapLabSessionState, MapLabFailure)] = [
      (.idle, .notReady), (.interrupted, .interrupted), (.failed(.timedOut), .timedOut),
      (.recognizing, .notReady), (.recognized, .notReady),
    ]
    for (state, expected) in cases {
      let owner = MapLabCaptureRequest(), request = UUID()
      let capture = Task { try await withCheckedThrowingContinuation { owner.begin(request, continuation: $0) } }
      try await until { owner.contains(request) }
      XCTAssertTrue(owner.finishArchive(.success(Data([1])), request: request, state: state))
      do { _ = try await capture.value; XCTFail("Archive completion cannot succeed in \(state)") }
      catch { XCTAssertEqual(error as? MapLabFailure, expected) }
      XCTAssertNil(owner.activeID)
    }
  }

  func testArchiveFailureRemainsAnErrorWhenCurrentScanReadinessDrops() async throws {
    let owner = MapLabCaptureRequest(), request = UUID()
    let capture = Task { try await withCheckedThrowingContinuation { owner.begin(request, continuation: $0) } }
    try await until { owner.contains(request) }
    XCTAssertTrue(owner.finishArchive(.failure(MapLabFailure.mapTooLarge), request: request,
      state: .scanning(feedback: .mapping, canSave: false)))
    do { _ = try await capture.value; XCTFail("A scan-quality dip must not hide the archive failure") }
    catch { XCTAssertEqual(error as? MapLabFailure, .mapTooLarge) }
  }

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
    XCTAssertFalse(owner.finishArchive(.success(Data([1])), request: a,
      state: .scanning(feedback: .ready, canSave: true)), "A late archive cannot resolve B")
    XCTAssertFalse(owner.finish(.failure(MapLabFailure.timedOut), request: a), "A late timer cannot time out B")
    XCTAssertFalse(owner.finish(.failure(CancellationError()), request: a), "A late cancellation cannot cancel B")
    XCTAssertFalse(retryResolved)
    XCTAssertTrue(owner.contains(b))
    XCTAssertTrue(owner.finishArchive(.success(Data([2])), request: b,
      state: .scanning(feedback: .mapping, canSave: false)))
    let result = try await retry.value
    XCTAssertEqual(result, Data([2]))
    XCTAssertTrue(retryResolved); XCTAssertNil(owner.activeID)
    XCTAssertFalse(owner.finishArchive(.success(Data([3])), request: b,
      state: .scanning(feedback: .ready, canSave: true)), "A completed request cannot resume twice")
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

#if os(iOS) && canImport(ARKit)
import ARKit
import SwiftUI
import UIKit

@MainActor final class MapLabTestCameraSource: MapLabCameraSource {
  @Published var session: ARSession?
  var onReassert: (() -> Void)?
  func reassertDelegate() { onReassert?() }
}

@MainActor
final class MapLabCameraPreviewTests: XCTestCase {
  func testPreviewFollowsSessionCreatedAfterFirstRenderReplacedByRetryAndClearedByStop() async throws {
    // Compile-time proof the shipped driver is a valid preview source.
    let _: any MapLabCameraSource = MapLabARDriver()
    let source = MapLabTestCameraSource()
    let host = UIHostingController(rootView: MapLabCameraPreview(driver: source))
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    let sceneView = try XCTUnwrap(findARSCNView(in: host.view))
    let own = sceneView.session
    let s1 = ARSession(), s2 = ARSession()
    var reassertedWhileAttachedToS1 = false
    source.onReassert = { reassertedWhileAttachedToS1 = reassertedWhileAttachedToS1 || sceneView.session === s1 }

    source.session = s1
    try await until { sceneView.session === s1 }
    XCTAssertTrue(reassertedWhileAttachedToS1, "Driver delegate must be reasserted after ARSCNView takes the session")

    source.session = nil
    try await until { sceneView.session !== s1 }
    XCTAssertTrue(sceneView.session !== own, "Stop must not fall back to a stale session")

    source.session = s2
    try await until { sceneView.session === s2 }
    XCTAssertTrue(findARSCNView(in: host.view) === sceneView, "Session changes update the existing view, they do not recreate it")
    withExtendedLifetime(window) {}
  }

  private func findARSCNView(in view: UIView) -> ARSCNView? {
    if let scene = view as? ARSCNView { return scene }
    for child in view.subviews { if let found = findARSCNView(in: child) { return found } }
    return nil
  }
  private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      guard ContinuousClock.now < deadline else { XCTFail("Preview did not follow the session change"); throw MapLabFailure.timedOut }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
#endif
