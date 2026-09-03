import XCTest

@testable import CombatTransport

/// KIL-43 A1: chunked bulk stream for AR collaboration data and world maps,
/// riding the existing reliable-event path as `bulkChunk` events.
final class BulkTransferTests: XCTestCase {
  private func blob(_ count: Int, seed: UInt8 = 7) -> Data {
    var state = seed
    return Data((0..<count).map { _ in
      state = state &* 31 &+ 17
      return state
    })
  }

  private func frames(for payload: Data, transferID: UInt32 = 42, kind: BulkContentKind = .arWorldMap, slot: UInt8 = 1, firstSequence: UInt32 = 1) throws -> [ReliableEventFrame] {
    try BulkChunker.frames(
      try BulkChunker.chunk(payload, transferID: transferID, contentKind: kind),
      epoch: 1, senderSlot: slot, firstSequence: firstSequence)
  }

  // MARK: - Codec

  func testChunkPayloadStaysInsideTheReliableFrameLimit() throws {
    XCTAssertEqual(BulkChunkCodec.headerLength, 21)
    XCTAssertEqual(BulkChunkCodec.maxChunkBytes, 491)
    let payload = blob(BulkChunkCodec.maxChunkBytes * 3 + 5)
    for frame in try frames(for: payload) {
      XCTAssertLessThanOrEqual(frame.payload.count, TransportFrameCodec.maxPayloadLength)
      // Every chunk must survive the real wire codec.
      let decoded = try TransportFrameCodec.decode(try TransportFrameCodec.encode(.reliable(frame)))
      XCTAssertEqual(decoded, .reliable(frame))
    }
  }

  func testChunkWireLayoutIsPinned() throws {
    let chunk = BulkChunk(
      transferID: 0x0403_0201, contentKind: .arCollaborationData, totalLength: 0x0000_0102,
      digest: 0xDDCC_BBAA, chunkIndex: 1, chunkCount: 2, bytes: Data([0xFE, 0xFF]))
    let encoded = try BulkChunkCodec.encode(chunk)
    XCTAssertEqual(
      Array(encoded),
      [
        0x01, 0x02, 0x03, 0x04,  // transferID
        0x01,  // contentKind
        0x02, 0x01, 0x00, 0x00,  // totalLength
        0xAA, 0xBB, 0xCC, 0xDD,  // digest
        0x01, 0x00, 0x00, 0x00,  // chunkIndex
        0x02, 0x00, 0x00, 0x00,  // chunkCount
        0xFE, 0xFF,
      ])
    XCTAssertEqual(try BulkChunkCodec.decode(encoded), chunk)
  }

  func testCodecRejectsMalformedChunks() throws {
    let good = try BulkChunkCodec.encode(
      BulkChunk(transferID: 1, contentKind: .arWorldMap, totalLength: 1, digest: 0, chunkIndex: 0, chunkCount: 1, bytes: Data([1])))
    XCTAssertThrowsError(try BulkChunkCodec.decode(good.prefix(BulkChunkCodec.headerLength - 1))) {
      XCTAssertEqual($0 as? BulkTransferError, .truncatedChunk)
    }
    var badKind = good
    badKind[4] = 99
    XCTAssertThrowsError(try BulkChunkCodec.decode(badKind)) { XCTAssertEqual($0 as? BulkTransferError, .unknownContentKind) }
    var zeroCount = good
    zeroCount[17] = 0
    XCTAssertThrowsError(try BulkChunkCodec.decode(zeroCount)) { XCTAssertEqual($0 as? BulkTransferError, .zeroChunkCount) }
    var indexOutOfRange = good
    indexOutOfRange[13] = 1
    XCTAssertThrowsError(try BulkChunkCodec.decode(indexOutOfRange)) { XCTAssertEqual($0 as? BulkTransferError, .chunkIndexOutOfRange) }
    var zeroID = good
    zeroID[0] = 0
    XCTAssertThrowsError(try BulkChunkCodec.decode(zeroID)) { XCTAssertEqual($0 as? BulkTransferError, .zeroTransferID) }
    XCTAssertThrowsError(try BulkChunkCodec.decode(good + blob(BulkChunkCodec.maxChunkBytes))) {
      XCTAssertEqual($0 as? BulkTransferError, .chunkBytesTooLarge)
    }
  }

  func testDigestIsFnv1a32() {
    // Reference vectors for FNV-1a 32.
    XCTAssertEqual(BulkChunkCodec.digest(of: Data()), 0x811C_9DC5)
    XCTAssertEqual(BulkChunkCodec.digest(of: Data("a".utf8)), 0xE40C_292C)
    XCTAssertEqual(BulkChunkCodec.digest(of: Data("foobar".utf8)), 0xBF9C_F968)
  }

  // MARK: - Chunker

  func testChunkerSplitsExactlyAndRejectsBadInput() throws {
    let exact = blob(BulkChunkCodec.maxChunkBytes * 2)
    let exactChunks = try BulkChunker.chunk(exact, transferID: 1, contentKind: .arWorldMap)
    XCTAssertEqual(exactChunks.count, 2)
    XCTAssertEqual(exactChunks.map(\.bytes.count), [491, 491])
    XCTAssertEqual(exactChunks.map(\.chunkIndex), [0, 1])
    XCTAssertTrue(exactChunks.allSatisfy { $0.chunkCount == 2 && $0.totalLength == 982 })

    let ragged = blob(BulkChunkCodec.maxChunkBytes * 2 + 1)
    XCTAssertEqual(try BulkChunker.chunk(ragged, transferID: 1, contentKind: .arWorldMap).map(\.bytes.count), [491, 491, 1])

    XCTAssertThrowsError(try BulkChunker.chunk(Data(), transferID: 1, contentKind: .arWorldMap)) {
      XCTAssertEqual($0 as? BulkTransferError, .emptyPayload)
    }
    XCTAssertThrowsError(try BulkChunker.chunk(blob(1), transferID: 0, contentKind: .arWorldMap)) {
      XCTAssertEqual($0 as? BulkTransferError, .zeroTransferID)
    }
    XCTAssertThrowsError(try BulkChunker.chunk(Data(count: BulkChunker.maxTransferLength + 1), transferID: 1, contentKind: .arWorldMap)) {
      XCTAssertEqual($0 as? BulkTransferError, .payloadTooLarge)
    }
    XCTAssertThrowsError(try BulkChunker.frames(exactChunks, epoch: 1, senderSlot: 1, firstSequence: 0)) {
      XCTAssertEqual($0 as? TransportCodecError, .zeroSequence)
    }
  }

  func testFramesAreConsecutiveBulkChunkEvents() throws {
    let framed = try frames(for: blob(1_000), firstSequence: 10)
    XCTAssertEqual(framed.map(\.sequence), [10, 11, 12])
    XCTAssertTrue(framed.allSatisfy { $0.eventKind == .bulkChunk && $0.senderSlot == 1 && $0.epoch == 1 })
  }

  // MARK: - Assembler

  func testInOrderRoundTripOfALargeBlob() throws {
    let payload = blob(200_000)  // ~408 chunks, world-map scale
    var assembler = BulkTransferAssembler()
    let framed = try frames(for: payload, transferID: 9, kind: .arCollaborationData)
    var completed: BulkTransfer?
    for (offset, frame) in framed.enumerated() {
      switch assembler.ingest(frame) {
      case .accepted(let id, let received, let count):
        XCTAssertEqual(id, 9)
        XCTAssertEqual(received, offset + 1)
        XCTAssertEqual(count, framed.count)
      case .completed(let transfer):
        XCTAssertEqual(offset, framed.count - 1)
        completed = transfer
      case let other:
        XCTFail("unexpected \(other) at chunk \(offset)")
      }
    }
    XCTAssertEqual(completed, BulkTransfer(transferID: 9, senderSlot: 1, contentKind: .arCollaborationData, payload: payload))
    XCTAssertEqual(assembler.pendingTransferIDs(for: 1), [])
  }

  func testOutOfOrderAndDuplicateChunksReassembleOnce() throws {
    let payload = blob(5_000)
    var assembler = BulkTransferAssembler()
    let framed = try frames(for: payload)
    var shuffled = framed
    shuffled.reverse()
    shuffled.swapAt(0, 3)
    shuffled.insert(framed[2], at: 1)  // duplicate

    var completions = 0
    var duplicates = 0
    for frame in shuffled {
      switch assembler.ingest(frame) {
      case .completed(let transfer):
        completions += 1
        XCTAssertEqual(transfer.payload, payload)
      case .duplicateChunk(42, 2): duplicates += 1
      case .accepted: break
      case let other: XCTFail("unexpected \(other)")
      }
    }
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(duplicates, 1)
  }

  func testMissingLastChunkStaysPendingAndResetDropsIt() throws {
    var assembler = BulkTransferAssembler()
    let framed = try frames(for: blob(2_000))
    for frame in framed.dropLast() {
      guard case .accepted = assembler.ingest(frame) else { return XCTFail("expected accepted") }
    }
    XCTAssertEqual(assembler.pendingTransferIDs(for: 1), [42])
    assembler.reset(senderSlot: 1)
    XCTAssertEqual(assembler.pendingTransferIDs(for: 1), [])
    // The late last chunk now starts a fresh partial transfer rather than completing anything.
    guard case .accepted(42, 1, _) = assembler.ingest(framed.last!) else { return XCTFail("expected a fresh partial") }
  }

  func testCorruptedBytesFailTheDigestAndTruncatedBytesFailTheLength() throws {
    let payload = blob(1_500)
    let chunks = try BulkChunker.chunk(payload, transferID: 5, contentKind: .arWorldMap)

    var flipped = chunks
    var bytes = flipped[1].bytes
    bytes[0] ^= 0xFF
    flipped[1] = BulkChunk(
      transferID: 5, contentKind: .arWorldMap, totalLength: flipped[1].totalLength, digest: flipped[1].digest,
      chunkIndex: 1, chunkCount: flipped[1].chunkCount, bytes: bytes)
    var assembler = BulkTransferAssembler()
    var last: BulkAssemblyOutcome = .notBulk
    for frame in try BulkChunker.frames(flipped, epoch: 1, senderSlot: 2, firstSequence: 1) { last = assembler.ingest(frame) }
    XCTAssertEqual(last, .rejected(transferID: 5, .digestMismatch))

    var short = chunks
    short[2] = BulkChunk(
      transferID: 5, contentKind: .arWorldMap, totalLength: short[2].totalLength, digest: short[2].digest,
      chunkIndex: 2, chunkCount: short[2].chunkCount, bytes: short[2].bytes.dropLast(3))
    assembler = BulkTransferAssembler()
    for frame in try BulkChunker.frames(short, epoch: 1, senderSlot: 2, firstSequence: 1) { last = assembler.ingest(frame) }
    XCTAssertEqual(last, .rejected(transferID: 5, .lengthMismatch))
    XCTAssertEqual(assembler.pendingTransferIDs(for: 2), [])
  }

  func testHeaderMismatchDropsTheTransfer() throws {
    var assembler = BulkTransferAssembler()
    let framed = try frames(for: blob(1_200))
    _ = assembler.ingest(framed[0])
    let lying = BulkChunk(
      transferID: 42, contentKind: .arWorldMap, totalLength: 999_999, digest: 0, chunkIndex: 1, chunkCount: 3, bytes: Data([0]))
    let outcome = assembler.ingest(
      ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: 2, eventKind: .bulkChunk, payload: try BulkChunkCodec.encode(lying)))
    XCTAssertEqual(outcome, .rejected(transferID: 42, .headerMismatch))
    XCTAssertEqual(assembler.pendingTransferIDs(for: 1), [])
  }

  func testAssemblerEnforcesSizeAndConcurrencyCaps() throws {
    var assembler = BulkTransferAssembler(maxConcurrentTransfersPerSender: 1, maxTransferLength: 1_000)
    let tooBig = BulkChunk(transferID: 1, contentKind: .arWorldMap, totalLength: 1_001, digest: 0, chunkIndex: 0, chunkCount: 3, bytes: Data([0]))
    XCTAssertEqual(
      assembler.ingest(ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: 1, eventKind: .bulkChunk, payload: try BulkChunkCodec.encode(tooBig))),
      .rejected(transferID: 1, .totalLengthTooLarge))

    let first = try frames(for: blob(900), transferID: 2)
    let second = try frames(for: blob(900), transferID: 3, firstSequence: 10)
    guard case .accepted = assembler.ingest(first[0]) else { return XCTFail("expected accepted") }
    XCTAssertEqual(assembler.ingest(second[0]), .rejected(transferID: 3, .tooManyConcurrentTransfers))
    // Senders are independent.
    var fromSlot2 = second[0]
    fromSlot2 = ReliableEventFrame(epoch: 1, senderSlot: 2, sequence: 1, eventKind: .bulkChunk, payload: fromSlot2.payload)
    guard case .accepted = assembler.ingest(fromSlot2) else { return XCTFail("expected accepted from another sender") }
  }

  func testNonBulkAndMalformedEventsAreReportedNotCrashed() {
    var assembler = BulkTransferAssembler()
    XCTAssertEqual(
      assembler.ingest(ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: 1, eventKind: .fire, payload: Data([1]))),
      .notBulk)
    XCTAssertEqual(
      assembler.ingest(ReliableEventFrame(epoch: 1, senderSlot: 1, sequence: 2, eventKind: .bulkChunk, payload: Data([1, 2, 3]))),
      .rejected(transferID: nil, .malformedChunk(.truncatedChunk)))
  }

  // MARK: - Through the fabric

  func testBulkTransferRidesTheReliablePathThroughReorderingAndDuplication() throws {
    let fabric = LoopbackFabric(
      playerCount: 2,
      faultProfile: FaultProfile(jitterMs: 20, reliableReorderPercent: 30, reliableDuplicatePercent: 10),
      seed: 0xBEEF
    )
    let client = fabric.client(slot: 1)
    let payload = blob(30_000)
    for frame in try frames(for: payload, transferID: 77, kind: .arCollaborationData) {
      try client.send(frame)
    }
    fabric.advance(to: 5_000)

    var assembler = BulkTransferAssembler()
    var completed: BulkTransfer?
    for delivered in fabric.host.deliveredReliableEvents(for: 1) {
      if case .completed(let transfer) = assembler.ingest(delivered) { completed = transfer }
    }
    XCTAssertEqual(completed?.payload, payload)
    XCTAssertEqual(completed?.contentKind, .arCollaborationData)
  }
}
