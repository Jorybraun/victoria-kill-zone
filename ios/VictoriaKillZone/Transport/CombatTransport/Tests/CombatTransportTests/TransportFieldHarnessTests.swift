import Foundation
import XCTest

@testable import CombatTransport

final class TransportFieldHarnessTests: XCTestCase {
  private final class ConcurrentPeerLink: PeerLink, @unchecked Sendable {
    let remoteSlot: UInt8 = 1
    let evidenceTier: TransportEvidenceTier = .loopbackSimulated
    let deliversOrderedReliableFrames = false
    private let lock = NSLock()
    private var handler: PeerLinkReceiveHandler?

    func start() {}
    func stop() {}
    func send(_ frame: TransportFrame) throws {}

    func setReceiveHandler(_ handler: PeerLinkReceiveHandler?) {
      lock.lock()
      self.handler = handler
      lock.unlock()
    }

    func emit(_ frame: TransportFrame, arrivalMs: Int64) {
      lock.lock()
      let handler = self.handler
      lock.unlock()
      handler?(frame, arrivalMs, arrivalMs)
    }
  }

  func testHarnessEmitsWellFormedSanitizedSnapshot() throws {
    let fabric = LoopbackFabric(
      playerCount: 3,
      faultProfile: FaultProfile(poseLossPercent: 20),
      seed: 7
    )
    let harness = TransportFieldHarness(link: fabric.client(slot: 2))
    harness.startHostAndClient()
    try harness.drivePoseCadence(seconds: 1)
    fabric.advance(to: 1_000)
    let data = try harness.sanitizedStatsSnapshot()
    let snapshot = try JSONDecoder().decode(TransportStatsSnapshot.self, from: data)
    XCTAssertEqual(snapshot.schema, "transport-stats.v0")
    XCTAssertEqual(snapshot.evidenceTier, .loopbackSimulated)
    let pose = try XCTUnwrap(snapshot.channels.first { $0.channel == .pose })
    XCTAssertGreaterThan(pose.received, 0)
    XCTAssertGreaterThan(pose.sequenceGapLossPercent, 0)
  }

  func testHarnessSerializesConcurrentReceivesAndSnapshots() {
    let link = ConcurrentPeerLink()
    let harness = TransportFieldHarness(link: link)
    DispatchQueue.concurrentPerform(iterations: 500) { index in
      if index.isMultiple(of: 2) {
        let sequence = UInt32(index / 2 + 1)
        link.emit(
          .pose(
            PoseFrame(
              epoch: 1,
              senderSlot: 1,
              sequence: sequence,
              timestampMs: Int64(sequence),
              position: SIMD3<Float>(0, 0, 0),
              orientation: SIMD4<Float>(0, 0, 0, 1),
              tracking: .normal
            )
          ),
          arrivalMs: Int64(sequence)
        )
      } else {
        _ = try? harness.sanitizedStatsSnapshot()
      }
    }
    XCTAssertNoThrow(try harness.sanitizedStatsSnapshot())
  }
}
