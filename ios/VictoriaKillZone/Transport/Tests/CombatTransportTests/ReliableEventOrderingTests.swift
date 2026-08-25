import Foundation
import XCTest

@testable import CombatTransport

final class ReliableEventOrderingTests: XCTestCase {
  private func event(_ sequence: UInt32, slot: UInt8 = 1, epoch: UInt16 = 1) -> ReliableEventFrame {
    ReliableEventFrame(
      epoch: epoch,
      senderSlot: slot,
      sequence: sequence,
      eventKind: .fire,
      payload: Data([UInt8(sequence & 0xff)])
    )
  }

  func testReorderRepairAndDuplicateSuppression() {
    var orderer = ReliableEventOrderer()
    XCTAssertEqual(orderer.ingest(event(2)).status, .buffered)
    XCTAssertEqual(orderer.ingest(event(2)).status, .duplicate)
    let result = orderer.ingest(event(1))
    XCTAssertEqual(result.status, .delivered)
    XCTAssertEqual(result.frames.map(\.sequence), [1, 2])
  }

  func testEachSenderHasIndependentOrdering() {
    var orderer = ReliableEventOrderer()
    XCTAssertEqual(orderer.ingest(event(1, slot: 1)).frames.map(\.senderSlot), [1])
    XCTAssertEqual(orderer.ingest(event(1, slot: 2)).frames.map(\.senderSlot), [2])
    XCTAssertEqual(orderer.ingest(event(2, slot: 1)).frames.map(\.sequence), [2])
  }

  func testPendingOverflowIsUnrecoverable() {
    var orderer = ReliableEventOrderer(maxPendingReliableEvents: 2)
    XCTAssertEqual(orderer.ingest(event(2)).status, .buffered)
    XCTAssertEqual(orderer.ingest(event(3)).status, .buffered)
    XCTAssertEqual(orderer.ingest(event(4)).status, .unrecoverableGap)
  }

  func testEpochResetsSequenceExpectation() {
    var orderer = ReliableEventOrderer()
    _ = orderer.ingest(event(9))
    XCTAssertEqual(orderer.ingest(event(1, epoch: 2)).status, .delivered)
    XCTAssertEqual(orderer.nextExpectedSequence(for: 1), 2)
  }
}
