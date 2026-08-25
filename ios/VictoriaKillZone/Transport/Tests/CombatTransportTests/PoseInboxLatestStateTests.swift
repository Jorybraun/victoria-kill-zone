import XCTest

@testable import CombatTransport

final class PoseInboxLatestStateTests: XCTestCase {
  private func frame(
    slot: UInt8 = 1,
    epoch: UInt16 = 1,
    sequence: UInt32,
    timestamp: Int64
  ) -> PoseFrame {
    PoseFrame(
      epoch: epoch,
      senderSlot: slot,
      sequence: sequence,
      timestampMs: timestamp,
      position: SIMD3<Float>(Float(sequence), 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
  }

  func testOnlyStrictlyNewerSequenceAndTimestampAreAdmitted() {
    var inbox = PoseInbox()
    XCTAssertTrue(inbox.admit(frame(sequence: 1, timestamp: 1)).accepted)
    XCTAssertEqual(inbox.admit(frame(sequence: 1, timestamp: 2)).discardedReason, .duplicateSequence)
    XCTAssertEqual(inbox.admit(frame(sequence: 0, timestamp: 0)).discardedReason, .staleSequence)
    XCTAssertEqual(inbox.admit(frame(sequence: 2, timestamp: 1)).discardedReason, .staleTimestamp)
    XCTAssertTrue(inbox.admit(frame(sequence: 2, timestamp: 2)).accepted)
  }

  func testEpochMismatchAndResetAreIndependentPerSlot() {
    var inbox = PoseInbox()
    XCTAssertTrue(inbox.admit(frame(slot: 1, epoch: 2, sequence: 20, timestamp: 20)).accepted)
    XCTAssertEqual(
      inbox.admit(frame(slot: 1, epoch: 1, sequence: 21, timestamp: 21)).discardedReason,
      .epochMismatch
    )
    XCTAssertTrue(inbox.admit(frame(slot: 1, epoch: 3, sequence: 1, timestamp: 1)).accepted)
    XCTAssertTrue(inbox.admit(frame(slot: 2, epoch: 1, sequence: 1, timestamp: 1)).accepted)
    XCTAssertEqual(inbox.latestFrame(for: 1)?.sequence, 1)
    XCTAssertEqual(inbox.latestFrame(for: 2)?.sequence, 1)
  }

  func testOutOfOrderArrivalNeverOverwritesLatestState() {
    var inbox = PoseInbox()
    _ = inbox.admit(frame(sequence: 2, timestamp: 2))
    _ = inbox.admit(frame(sequence: 1, timestamp: 1))
    XCTAssertEqual(inbox.latestFrame(for: 1)?.sequence, 2)
  }
}
