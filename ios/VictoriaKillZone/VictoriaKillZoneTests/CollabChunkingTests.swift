import Foundation
import XCTest
@testable import VictoriaKillZone

final class CollabChunkingTests: XCTestCase {
  func testSmallPayloadPassesThroughUnchanged() {
    for payload in [Data(), Data([1, 2, 3]), Self.randomData(count: CollabChunkCodec.chunkBytes)] {
      let frames = CollabChunkCodec.frames(payload, transferID: 9)
      XCTAssertEqual(frames, [payload])
      var assembler = CollabTransferAssembler()
      XCTAssertEqual(assembler.ingest(frames[0], from: "p1"), .passthrough(payload))
    }
  }

  func testLargePayloadChunksWithinWireLimits() throws {
    let payload = Self.randomData(count: 1_048_576)
    let frames = CollabChunkCodec.frames(payload, transferID: 1)
    XCTAssertEqual(frames.count, (payload.count + CollabChunkCodec.chunkBytes - 1) / CollabChunkCodec.chunkBytes)
    let encoder = JSONEncoder()
    for frame in frames {
      XCTAssertLessThanOrEqual(frame.count, CombatWire.maximumCollabDataBytes)
      XCTAssertLessThanOrEqual(try encoder.encode(CombatWire.ClientMessage.collab(frame)).count,
        CombatWire.maximumCollabMessageBytes)
    }
  }

  func testAssemblerCompletesInOrderAndOutOfOrder() throws {
    let payload = Self.randomData(count: CollabChunkCodec.chunkBytes * 2 + 777)
    let frames = CollabChunkCodec.frames(payload, transferID: 4)
    XCTAssertEqual(frames.count, 3)

    var inOrder = CollabTransferAssembler()
    XCTAssertEqual(inOrder.ingest(frames[0], from: "p1"), .pending)
    XCTAssertEqual(inOrder.ingest(frames[1], from: "p1"), .pending)
    XCTAssertEqual(inOrder.ingest(frames[2], from: "p1"), .completed(payload))

    var outOfOrder = CollabTransferAssembler()
    XCTAssertEqual(outOfOrder.ingest(frames[2], from: "p1"), .pending)
    XCTAssertEqual(outOfOrder.ingest(frames[0], from: "p1"), .pending)
    XCTAssertEqual(outOfOrder.ingest(frames[2], from: "p1"), .pending, "A duplicate chunk is ignored")
    XCTAssertEqual(outOfOrder.ingest(frames[1], from: "p1"), .completed(payload))
  }

  func testInterleavedSendersCompleteIndependently() {
    let first = Self.randomData(count: CollabChunkCodec.chunkBytes + 100)
    let second = Self.randomData(count: CollabChunkCodec.chunkBytes + 200)
    let framesA = CollabChunkCodec.frames(first, transferID: 1)
    let framesB = CollabChunkCodec.frames(second, transferID: 7)
    var assembler = CollabTransferAssembler()
    XCTAssertEqual(assembler.ingest(framesA[0], from: "host"), .pending)
    XCTAssertEqual(assembler.ingest(framesB[0], from: "guest"), .pending)
    XCTAssertEqual(assembler.ingest(framesA[1], from: "host"), .completed(first))
    XCTAssertEqual(assembler.ingest(framesB[1], from: "guest"), .completed(second))
  }

  func testNewTransferReplacesPartialFromSameSender() {
    let stale = Self.randomData(count: CollabChunkCodec.chunkBytes + 50)
    let fresh = Self.randomData(count: CollabChunkCodec.chunkBytes + 50)
    let staleFrames = CollabChunkCodec.frames(stale, transferID: 1)
    let freshFrames = CollabChunkCodec.frames(fresh, transferID: 2)
    var assembler = CollabTransferAssembler()
    XCTAssertEqual(assembler.ingest(staleFrames[0], from: "p1"), .pending)
    XCTAssertEqual(assembler.ingest(freshFrames[0], from: "p1"), .pending)
    XCTAssertEqual(assembler.ingest(freshFrames[1], from: "p1"), .completed(fresh))
  }

  func testCorruptedChunkAndOversizedLengthDrop() throws {
    let payload = Self.randomData(count: CollabChunkCodec.chunkBytes + 10)
    let frames = CollabChunkCodec.frames(payload, transferID: 3)
    var corrupted = frames[1]
    corrupted[corrupted.count - 1] ^= 0xFF
    var assembler = CollabTransferAssembler()
    XCTAssertEqual(assembler.ingest(frames[0], from: "p1"), .pending)
    XCTAssertEqual(assembler.ingest(corrupted, from: "p1"), .dropped)

    let oversized = CollabChunkCodec.frames(Data(repeating: 1, count: 100), transferID: 5)
    XCTAssertEqual(oversized.count, 1, "Small payloads never frame")
    var forged = Data(CollabChunkCodec.magic)
    forged.append(contentsOf: withUnsafeBytes(of: UInt32(6).bigEndian) {Array($0)})
    forged.append(contentsOf: withUnsafeBytes(of: UInt16(0).bigEndian) {Array($0)})
    forged.append(contentsOf: withUnsafeBytes(of: UInt16(1).bigEndian) {Array($0)})
    forged.append(contentsOf: withUnsafeBytes(of: UInt32(CollabChunkCodec.maximumTransferBytes + 1).bigEndian) {Array($0)})
    forged.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) {Array($0)})
    forged.append(Data(repeating: 0, count: 100))
    XCTAssertNil(CollabChunkCodec.decode(forged))
    XCTAssertEqual(assembler.ingest(forged, from: "p2"), .dropped)
  }

  func testMagicPrefixedRawPayloadRoundTrips() {
    var payload = Data(CollabChunkCodec.magic)
    payload.append(Self.randomData(count: 1000))
    let frames = CollabChunkCodec.frames(payload, transferID: 2)
    XCTAssertEqual(frames.count, 1)
    XCTAssertNotEqual(frames[0], payload, "A magic-prefixed payload must frame, not pass through")
    var assembler = CollabTransferAssembler()
    XCTAssertEqual(assembler.ingest(frames[0], from: "p1"), .completed(payload))
  }

  private static func randomData(count: Int) -> Data {
    Data((0..<count).map {_ in UInt8.random(in: 0...255)})
  }
}
