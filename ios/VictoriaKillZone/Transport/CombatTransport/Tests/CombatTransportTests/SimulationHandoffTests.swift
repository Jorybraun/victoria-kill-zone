import XCTest
import PewPewSimulation

@testable import CombatTransport

final class SimulationHandoffTests: XCTestCase {
  func testAdmittedPoseFeedsSimulationAndStalePoseIsRefused() throws {
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
    let latest = try XCTUnwrap(inbox.latestFrame(for: 1))
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

  func testLoopbackAdmittedPosesAreAcceptedBySimulationInOrder() throws {
    let fabric = LoopbackFabric(
      playerCount: 2,
      faultProfile: FaultProfile(poseLossPercent: 5),
      seed: 0xC0FFEE
    )
    let client = fabric.client(slot: 1)
    for sequence in 1...100 {
      let timestamp = Int64(sequence) * 33
      try client.send(
        PoseFrame(
          epoch: 1,
          senderSlot: 1,
          sequence: UInt32(sequence),
          timestampMs: timestamp,
          position: SIMD3<Float>(Float(sequence), 0, 0),
          orientation: SIMD4<Float>(0, 0, 0, 1),
          tracking: .normal
        )
      )
      fabric.advance(to: timestamp)
    }
    let admittedFrames = fabric.core(for: 0).poseInbox.admittedHistory
    var history = PoseHistoryRingBuffer(capacity: 128)
    for admitted in admittedFrames {
      let sample = PoseSample(
        timestampMs: admitted.timestampMs,
        position: Vector3(
          Double(admitted.position.x),
          Double(admitted.position.y),
          Double(admitted.position.z)
        ),
        tracking: .normal
      )
      XCTAssertTrue(history.record(sample))
    }
    XCTAssertFalse(admittedFrames.isEmpty)
    XCTAssertEqual(history.latest?.timestampMs, admittedFrames.last?.timestampMs)
    var core = fabric.core(for: 0)
    XCTAssertFalse(
      core.receivePose(admittedFrames.last!, receivedAtMs: 3_400).accepted
    )
  }
}
