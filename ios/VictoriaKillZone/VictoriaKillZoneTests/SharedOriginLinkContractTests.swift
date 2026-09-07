import Foundation
import XCTest
@testable import VictoriaKillZone

final class SharedOriginLinkContractTests: XCTestCase {
  func testBoundedExperimentBodyRoundTripsThroughStreamAndReliableMapper() throws {
    let message = ArenaLinkMessage.experiment(Data(repeating: 0x41, count: 4096))
    var stream = try ArenaLinkCodec.encode(message)
    XCTAssertEqual(try ArenaLinkCodec.drainFrames(from: &stream), [message])
    XCTAssertTrue(stream.isEmpty)
    var sender = ArenaLinkFrameMapper(senderSlot: 0, epoch: 1)
    var receiver = ArenaLinkFrameMapper(senderSlot: 1, epoch: 1)
    XCTAssertEqual(try sender.outbound(message).compactMap { receiver.inbound($0) }, [message])
  }

  func testRejectsEmptyAndOversizedExperimentBodies() {
    for size in [0, 4097] {
      XCTAssertThrowsError(try ArenaLinkBodyCodec.encode(.experiment(Data(repeating: 0, count: size))))
      XCTAssertThrowsError(try ArenaLinkBodyCodec.decode(kind: 8, body: Data(repeating: 0, count: size)))
    }
  }

  func testRejectsOversizedAnnouncedExperimentBeforeBufferingPayload() {
    var length = UInt32(4098).littleEndian
    var stream = withUnsafeBytes(of: &length) { Data($0) }
    stream.append(8)
    XCTAssertThrowsError(try ArenaLinkCodec.drainFrames(from: &stream)) { error in
      XCTAssertEqual(error as? ArenaLinkCodecError, .payloadTooLarge)
    }
  }
}
