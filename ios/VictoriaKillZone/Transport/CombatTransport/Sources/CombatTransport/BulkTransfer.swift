import Foundation

/// What a bulk transfer carries. The transport does not interpret the bytes; the
/// kind only lets the receiver route the reassembled blob.
public enum BulkContentKind: UInt8, Codable, Sendable, CaseIterable {
  /// `ARSession.CollaborationData` archive.
  case arCollaborationData = 1
  /// `ARWorldMap` archive.
  case arWorldMap = 2
  /// Shared-arena handshake message (anchor sets, lock reports) that exceeds one
  /// reliable event.
  case arenaHandshake = 3
}

/// One slice of a bulk transfer. Every chunk repeats the transfer header so a
/// receiver can validate any chunk in isolation and detect a sender that changes
/// its mind mid-transfer.
public struct BulkChunk: Equatable, Sendable {
  public let transferID: UInt32
  public let contentKind: BulkContentKind
  public let totalLength: UInt32
  public let digest: UInt32
  public let chunkIndex: UInt32
  public let chunkCount: UInt32
  public let bytes: Data

  public init(
    transferID: UInt32,
    contentKind: BulkContentKind,
    totalLength: UInt32,
    digest: UInt32,
    chunkIndex: UInt32,
    chunkCount: UInt32,
    bytes: Data
  ) {
    self.transferID = transferID
    self.contentKind = contentKind
    self.totalLength = totalLength
    self.digest = digest
    self.chunkIndex = chunkIndex
    self.chunkCount = chunkCount
    self.bytes = bytes
  }
}

/// A fully reassembled and verified transfer.
public struct BulkTransfer: Equatable, Sendable {
  public let transferID: UInt32
  public let senderSlot: UInt8
  public let contentKind: BulkContentKind
  public let payload: Data
}

public enum BulkTransferError: Error, Equatable, Sendable {
  case emptyPayload
  case payloadTooLarge
  case unknownContentKind
  case truncatedChunk
  case chunkBytesTooLarge
  case zeroChunkCount
  case chunkIndexOutOfRange
  case zeroTransferID
}

/// Wire layout of a `bulkChunk` reliable-event payload (little-endian):
///
///     transferID u32 | contentKind u8 | totalLength u32 | digest u32
///     | chunkIndex u32 | chunkCount u32 | bytes[…]
///
/// The header is 21 bytes, so a chunk carries at most 491 bytes and the frame
/// stays inside `TransportFrameCodec.maxPayloadLength`. `digest` is FNV-1a 32 of
/// the whole payload and is checked once the last chunk lands.
public enum BulkChunkCodec {
  public static let headerLength = 21
  public static let maxChunkBytes = TransportFrameCodec.maxPayloadLength - headerLength

  public static func encode(_ chunk: BulkChunk) throws -> Data {
    guard chunk.bytes.count <= maxChunkBytes else { throw BulkTransferError.chunkBytesTooLarge }
    guard chunk.chunkCount > 0 else { throw BulkTransferError.zeroChunkCount }
    guard chunk.chunkIndex < chunk.chunkCount else { throw BulkTransferError.chunkIndexOutOfRange }
    guard chunk.transferID != 0 else { throw BulkTransferError.zeroTransferID }
    var data = Data(capacity: headerLength + chunk.bytes.count)
    append(chunk.transferID, to: &data)
    data.append(chunk.contentKind.rawValue)
    append(chunk.totalLength, to: &data)
    append(chunk.digest, to: &data)
    append(chunk.chunkIndex, to: &data)
    append(chunk.chunkCount, to: &data)
    data.append(chunk.bytes)
    return data
  }

  public static func decode(_ payload: Data) throws -> BulkChunk {
    guard payload.count >= headerLength else { throw BulkTransferError.truncatedChunk }
    let bytes = Array(payload)
    func u32(_ offset: Int) -> UInt32 {
      UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    let transferID = u32(0)
    guard transferID != 0 else { throw BulkTransferError.zeroTransferID }
    guard let contentKind = BulkContentKind(rawValue: bytes[4]) else {
      throw BulkTransferError.unknownContentKind
    }
    let totalLength = u32(5)
    let digest = u32(9)
    let chunkIndex = u32(13)
    let chunkCount = u32(17)
    guard chunkCount > 0 else { throw BulkTransferError.zeroChunkCount }
    guard chunkIndex < chunkCount else { throw BulkTransferError.chunkIndexOutOfRange }
    let body = Data(bytes[headerLength...])
    guard body.count <= maxChunkBytes else { throw BulkTransferError.chunkBytesTooLarge }
    return BulkChunk(
      transferID: transferID,
      contentKind: contentKind,
      totalLength: totalLength,
      digest: digest,
      chunkIndex: chunkIndex,
      chunkCount: chunkCount,
      bytes: body
    )
  }

  /// FNV-1a, 32-bit. Cheap, dependency-free, and good enough to catch a mixed or
  /// truncated reassembly; the QUIC stream already guarantees byte integrity.
  public static func digest(of data: Data) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in data {
      hash ^= UInt32(byte)
      hash = hash &* 0x0100_0193
    }
    return hash
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
}

/// Splits a blob into chunks and wraps them as consecutive reliable events.
public enum BulkChunker {
  /// 8 MiB: comfortably above a large outdoor `ARWorldMap`, far below anything
  /// that should ride a game's reliable stream.
  public static let maxTransferLength = 8 * 1024 * 1024

  public static func chunk(
    _ payload: Data,
    transferID: UInt32,
    contentKind: BulkContentKind
  ) throws -> [BulkChunk] {
    guard transferID != 0 else { throw BulkTransferError.zeroTransferID }
    guard !payload.isEmpty else { throw BulkTransferError.emptyPayload }
    guard payload.count <= maxTransferLength else { throw BulkTransferError.payloadTooLarge }
    let digest = BulkChunkCodec.digest(of: payload)
    let chunkCount = (payload.count + BulkChunkCodec.maxChunkBytes - 1) / BulkChunkCodec.maxChunkBytes
    return (0..<chunkCount).map { index in
      let start = index * BulkChunkCodec.maxChunkBytes
      let end = min(start + BulkChunkCodec.maxChunkBytes, payload.count)
      return BulkChunk(
        transferID: transferID,
        contentKind: contentKind,
        totalLength: UInt32(payload.count),
        digest: digest,
        chunkIndex: UInt32(index),
        chunkCount: UInt32(chunkCount),
        bytes: payload.subdata(in: (payload.startIndex + start)..<(payload.startIndex + end))
      )
    }
  }

  /// Wraps chunks as `bulkChunk` reliable events with consecutive sequences
  /// starting at `firstSequence`. The caller owns the sender's sequence counter
  /// and must advance it by `chunks.count`.
  public static func frames(
    _ chunks: [BulkChunk],
    epoch: UInt16,
    senderSlot: UInt8,
    firstSequence: UInt32
  ) throws -> [ReliableEventFrame] {
    guard firstSequence != 0 else { throw TransportCodecError.zeroSequence }
    return try chunks.enumerated().map { offset, chunk in
      ReliableEventFrame(
        epoch: epoch,
        senderSlot: senderSlot,
        sequence: firstSequence + UInt32(offset),
        eventKind: .bulkChunk,
        payload: try BulkChunkCodec.encode(chunk)
      )
    }
  }
}

public enum BulkAssemblyRejection: Equatable, Sendable {
  case malformedChunk(BulkTransferError)
  /// A chunk's header disagreed with the first chunk seen for its transfer.
  case headerMismatch
  case totalLengthTooLarge
  case tooManyConcurrentTransfers
  /// All chunks arrived but the bytes did not add up to the declared length.
  case lengthMismatch
  /// All chunks arrived but the FNV-1a digest did not match.
  case digestMismatch
}

public enum BulkAssemblyOutcome: Equatable, Sendable {
  /// The frame was not a `bulkChunk`; nothing happened.
  case notBulk
  case accepted(transferID: UInt32, receivedChunks: Int, chunkCount: Int)
  case duplicateChunk(transferID: UInt32, chunkIndex: UInt32)
  case completed(BulkTransfer)
  /// The transfer (if any) has been dropped; a later chunk with the same
  /// transferID starts over.
  case rejected(transferID: UInt32?, BulkAssemblyRejection)
}

/// Per-sender reassembly of `bulkChunk` events. Tolerates any arrival order and
/// duplicates (the reliable orderer normally delivers in order, but relays and
/// retries need not). Pure value type; feed it frames as they are delivered.
public struct BulkTransferAssembler: Equatable, Sendable {
  private struct Pending: Equatable, Sendable {
    let contentKind: BulkContentKind
    let totalLength: UInt32
    let digest: UInt32
    let chunkCount: UInt32
    var chunks: [UInt32: Data]
  }

  public let maxConcurrentTransfersPerSender: Int
  public let maxTransferLength: Int
  private var pending: [UInt8: [UInt32: Pending]] = [:]

  public init(
    maxConcurrentTransfersPerSender: Int = 2,
    maxTransferLength: Int = BulkChunker.maxTransferLength
  ) {
    self.maxConcurrentTransfersPerSender = max(1, maxConcurrentTransfersPerSender)
    self.maxTransferLength = max(1, maxTransferLength)
  }

  public func pendingTransferIDs(for senderSlot: UInt8) -> [UInt32] {
    (pending[senderSlot] ?? [:]).keys.sorted()
  }

  /// Drops every partial transfer from one sender (epoch reset, peer loss).
  public mutating func reset(senderSlot: UInt8) {
    pending[senderSlot] = nil
  }

  public mutating func ingest(_ frame: ReliableEventFrame) -> BulkAssemblyOutcome {
    guard frame.eventKind == .bulkChunk else { return .notBulk }
    let chunk: BulkChunk
    do {
      chunk = try BulkChunkCodec.decode(frame.payload)
    } catch let error as BulkTransferError {
      return .rejected(transferID: nil, .malformedChunk(error))
    } catch {
      return .rejected(transferID: nil, .malformedChunk(.truncatedChunk))
    }

    var senderTransfers = pending[frame.senderSlot] ?? [:]
    var transfer: Pending
    if let existing = senderTransfers[chunk.transferID] {
      guard existing.contentKind == chunk.contentKind,
        existing.totalLength == chunk.totalLength,
        existing.digest == chunk.digest,
        existing.chunkCount == chunk.chunkCount
      else {
        senderTransfers[chunk.transferID] = nil
        pending[frame.senderSlot] = senderTransfers
        return .rejected(transferID: chunk.transferID, .headerMismatch)
      }
      transfer = existing
    } else {
      guard Int(chunk.totalLength) <= maxTransferLength else {
        return .rejected(transferID: chunk.transferID, .totalLengthTooLarge)
      }
      guard senderTransfers.count < maxConcurrentTransfersPerSender else {
        return .rejected(transferID: chunk.transferID, .tooManyConcurrentTransfers)
      }
      transfer = Pending(
        contentKind: chunk.contentKind,
        totalLength: chunk.totalLength,
        digest: chunk.digest,
        chunkCount: chunk.chunkCount,
        chunks: [:]
      )
    }

    if transfer.chunks[chunk.chunkIndex] != nil {
      return .duplicateChunk(transferID: chunk.transferID, chunkIndex: chunk.chunkIndex)
    }
    transfer.chunks[chunk.chunkIndex] = chunk.bytes

    guard transfer.chunks.count == Int(transfer.chunkCount) else {
      senderTransfers[chunk.transferID] = transfer
      pending[frame.senderSlot] = senderTransfers
      return .accepted(
        transferID: chunk.transferID,
        receivedChunks: transfer.chunks.count,
        chunkCount: Int(transfer.chunkCount)
      )
    }

    senderTransfers[chunk.transferID] = nil
    pending[frame.senderSlot] = senderTransfers
    var payload = Data(capacity: Int(transfer.totalLength))
    for index in 0..<transfer.chunkCount {
      payload.append(transfer.chunks[index] ?? Data())
    }
    guard payload.count == Int(transfer.totalLength) else {
      return .rejected(transferID: chunk.transferID, .lengthMismatch)
    }
    guard BulkChunkCodec.digest(of: payload) == transfer.digest else {
      return .rejected(transferID: chunk.transferID, .digestMismatch)
    }
    return .completed(
      BulkTransfer(
        transferID: chunk.transferID,
        senderSlot: frame.senderSlot,
        contentKind: transfer.contentKind,
        payload: payload
      ))
  }
}
