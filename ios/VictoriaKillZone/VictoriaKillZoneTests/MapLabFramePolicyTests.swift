import XCTest
@testable import VictoriaKillZone

final class MapLabFramePolicyTests: XCTestCase {
  func testOnlyFreshRelocalizingThenNormalRecognizesSavedMap() {
    var policy = MapLabFramePolicy()
    let token = policy.begin(.recognition, at: 0)
    receive(&policy, token, at: 0.1, tracking: .normal, usable: true)
    XCTAssertEqual(policy.state, .recognizing, "Ordinary tracking alone is not saved-map recognition")
    receive(&policy, token, at: 0.2, tracking: .relocalizing)
    XCTAssertEqual(policy.state, .recognizing)
    receive(&policy, token, at: 0.3, tracking: .normal)
    XCTAssertEqual(policy.state, .recognized)
  }

  func testOldAttemptStaleAndDuplicateFramesCannotRecognize() {
    var policy = MapLabFramePolicy()
    let old = policy.begin(.recognition, at: 0)
    receive(&policy, old, at: 0.1, tracking: .relocalizing)
    let current = policy.begin(.recognition, at: 1)
    receive(&policy, old, at: 1.1, tracking: .relocalizing)
    receive(&policy, current, at: 1.2, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing)
    policy.receive(MapLabFrameSample(timestamp: 1.3, capturedAt: 1,
      tracking: .relocalizing, usableMap: true), generation: current, at: 1.4)
    receive(&policy, current, at: 1.5, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing)
    receive(&policy, current, at: 1.5, tracking: .relocalizing)
    receive(&policy, current, at: 1.6, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing, "A duplicate timestamp must not establish relocalization")
  }

  func testWrongLocationHasFixedThirtySecondDeadlineAndExplicitRetry() {
    var policy = MapLabFramePolicy()
    let token = policy.begin(.recognition, at: 10)
    for second in 11..<40 { receive(&policy, token, at: Double(second), tracking: .relocalizing) }
    policy.tick(at: 40)
    XCTAssertEqual(policy.state, .failed(.timedOut))
    receive(&policy, token, at: 40.1, tracking: .normal)
    XCTAssertEqual(policy.state, .failed(.timedOut), "A late successful frame cannot erase timeout")
    let retry = policy.begin(.recognition, at: 41)
    receive(&policy, retry, at: 41.1, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing, "Retry cannot inherit earlier relocalization evidence")
  }

  func testRecognitionRevokesWhenTrackingIsLostOrFramesStop() {
    for stoppedFrames in [false, true] {
      var policy = MapLabFramePolicy()
      let token = policy.begin(.recognition, at: 0)
      receive(&policy, token, at: 0.1, tracking: .relocalizing)
      receive(&policy, token, at: 0.2, tracking: .normal)
      XCTAssertEqual(policy.state, .recognized)
      if stoppedFrames { policy.tick(at: 0.451) }
      else { receive(&policy, token, at: 0.3, tracking: .limited(.moveSlowly)) }
      XCTAssertEqual(policy.state, .interrupted)
      receive(&policy, token, at: 0.46, tracking: .normal)
      XCTAssertEqual(policy.state, .interrupted)
    }
  }

  func testStalledCaptureTimestampCannotBecomeFreshAtDeliveryTime() {
    var policy = MapLabFramePolicy()
    let token = policy.begin(.recognition, at: 100)
    policy.receive(MapLabFrameSample(timestamp: 100.1, capturedAt: 100.1,
      tracking: .relocalizing, usableMap: true), generation: token, at: 101)
    policy.receive(MapLabFrameSample(timestamp: 100.2, capturedAt: 100.2,
      tracking: .normal, usableMap: true), generation: token, at: 101.1)
    XCTAssertEqual(policy.state, .recognizing, "A queued relocalization pair must retain its sensor age")
    receive(&policy, token, at: 101.2, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing)
    policy.receive(MapLabFrameSample(timestamp: 102, capturedAt: 102,
      tracking: .relocalizing, usableMap: true), generation: token, at: 101.3)
    receive(&policy, token, at: 101.4, tracking: .normal)
    XCTAssertEqual(policy.state, .recognizing, "Future-dated frames cannot establish evidence either")
  }

  func testCaptureRequiresBothUsableMapAndNormalTrackingThenRevokesStaleReadiness() {
    var policy = MapLabFramePolicy()
    let token = policy.begin(.capture, at: 0)
    receive(&policy, token, at: 0.1, tracking: .limited(.findDetail), usable: true)
    XCTAssertEqual(policy.state, .scanning(feedback: .findDetail, canSave: false))
    receive(&policy, token, at: 0.2, tracking: .normal)
    XCTAssertEqual(policy.state, .scanning(feedback: .mapping, canSave: false))
    receive(&policy, token, at: 0.3, tracking: .normal, usable: true)
    XCTAssertEqual(policy.state, .scanning(feedback: .ready, canSave: true))
    policy.tick(at: 0.551)
    XCTAssertEqual(policy.state, .scanning(feedback: .starting, canSave: false))
    policy.tick(at: 30.552)
    XCTAssertEqual(policy.state, .failed(.timedOut))
  }

  func testInitialCaptureTimeoutAndInterruptionRequireFreshAttempt() {
    var policy = MapLabFramePolicy()
    let token = policy.begin(.capture, at: 0)
    receive(&policy, token, at: 29.9, tracking: .limited(.findDetail))
    policy.tick(at: 30)
    XCTAssertEqual(policy.state, .failed(.timedOut))
    let retry = policy.begin(.capture, at: 31)
    receive(&policy, retry, at: 31.1, tracking: .normal, usable: true)
    policy.interrupt()
    receive(&policy, retry, at: 31.2, tracking: .normal, usable: true)
    XCTAssertEqual(policy.state, .interrupted)
    policy.stop()
    XCTAssertEqual(policy.state, .idle)
  }

  private func receive(_ policy: inout MapLabFramePolicy, _ token: UInt64,
    at time: Double, tracking: MapLabFrameTracking, usable: Bool = false) {
    policy.receive(MapLabFrameSample(timestamp: time, capturedAt: time,
      tracking: tracking, usableMap: usable), generation: token, at: time)
  }
}
