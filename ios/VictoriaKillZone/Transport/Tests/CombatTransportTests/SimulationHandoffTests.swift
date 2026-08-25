import XCTest
import PewPewSimulation

@testable import CombatTransport

final class SimulationHandoffTests: XCTestCase {
  func testAdmittedPoseFeedsSimulationAndStalePoseIsRefused() {
    var inbox = PoseInbox()
    let admitted = PoseFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: 2,
      timestampMs: 2_000,
      position: SIMD3<Float>(1, 2, 3),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
    XCTAssertTrue(inbox.admit(admitted).accepted)
    let latest = try! XCTUnwrap(inbox.latestFrame(for: 1))
    let simulationPose = PoseSample(
      timestampMs: latest.timestampMs,
      position: Vector3(Double(latest.position.x), Double(latest.position.y), Double(latest.position.z)),
      tracking: latest.tracking == .normal ? .normal : .lost
    )
    var history = PoseHistoryRingBuffer(capacity: 4)
    XCTAssertTrue(history.record(simulationPose))
    XCTAssertFalse(history.record(simulationPose))
    XCTAssertEqual(history.latest, simulationPose)
    XCTAssertEqual(inbox.admit(admitted).discardedReason, .duplicateSequence)
  }
}
