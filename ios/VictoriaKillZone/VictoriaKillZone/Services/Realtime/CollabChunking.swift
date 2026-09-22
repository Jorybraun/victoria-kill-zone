import Foundation

/// Frames oversized ARKit collaboration archives over the opaque collab relay.
/// Header: magic "VKZC"(4) | transferID u32 | chunkIndex u16 | chunkCount u16 | totalLength u32 | crc32 u32  = 20 bytes, big-endian.
enum CollabChunkCodec {
  static let magic = Data("VKZC".utf8)
  static let headerLength = 20
  static let chunkBytes = 192 * 1024           // raw bytes per chunk; encoded message stays < 288 KB
  static let maximumTransferBytes = DuelFrameCollaboration.maximumBytes
  static let interChunkDelay: Duration = .milliseconds(1250)  // keeps encoded bytes under the worker's 256 KB/s budget

  struct Header: Equatable {
    var transferID: UInt32
    var chunkIndex: UInt16
    var chunkCount: UInt16
    var totalLength: UInt32
    var crc32: UInt32
  }

  /// Payloads that fit go through verbatim (older builds keep decoding them); larger ones become framed chunks.
  static func frames(_ data: Data, transferID: UInt32) -> [Data] {
    guard data.count > chunkBytes || data.starts(with: magic) else {return [data]}
    let chunkCount = (data.count + chunkBytes - 1) / chunkBytes
    guard data.count <= maximumTransferBytes, chunkCount <= Int(UInt16.max) else {return []}
    let checksum = crc32(data)
    return (0..<chunkCount).map {index in
      var frame = magic
      frame.appendBigEndian(transferID)
      frame.appendBigEndian(UInt16(index))
      frame.appendBigEndian(UInt16(chunkCount))
      frame.appendBigEndian(UInt32(data.count))
      frame.appendBigEndian(checksum)
      frame.append(data[(index * chunkBytes)..<min(data.count, (index + 1) * chunkBytes)])
      return frame
    }
  }

  /// Returns the parsed header and chunk payload, or nil when the frame does
  /// not carry the magic or its fields are inconsistent with a valid transfer.
  static func decode(_ frame: Data) -> (Header, Data)? {
    guard frame.count >= headerLength, frame.starts(with: magic) else {return nil}
    let transferID = frame.readBigEndian(UInt32.self, at: 4)
    let chunkIndex = frame.readBigEndian(UInt16.self, at: 8)
    let chunkCount = frame.readBigEndian(UInt16.self, at: 10)
    let totalLength = frame.readBigEndian(UInt32.self, at: 12)
    let checksum = frame.readBigEndian(UInt32.self, at: 16)
    guard chunkCount > 0, chunkIndex < chunkCount, totalLength <= maximumTransferBytes else {return nil}
    let lastChunk = Int(totalLength) - Int(chunkCount - 1) * chunkBytes
    guard lastChunk >= 1, lastChunk <= chunkBytes else {return nil}
    let expected = chunkIndex == chunkCount - 1 ? lastChunk : chunkBytes
    guard frame.count - headerLength == expected else {return nil}
    return (Header(transferID: transferID, chunkIndex: chunkIndex, chunkCount: chunkCount,
      totalLength: totalLength, crc32: checksum), frame.subdata(in: headerLength..<frame.count))
  }

  static func crc32(_ data: Data) -> UInt32 {
    data.reduce(~UInt32(0)) {crc, byte in (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]} ^ ~UInt32(0)
  }

  private static let table: [UInt32] = (0..<256).map {index in
    var crc = UInt32(index)
    for _ in 0..<8 {crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1}
    return crc
  }
}

/// Per-sender reassembly. One in-flight transfer per sender; a frame with a new transferID replaces the partial one.
struct CollabTransferAssembler {
  enum Outcome: Equatable {
    case passthrough(Data)
    case completed(Data)
    case pending
    case dropped
  }

  private struct Partial {
    var header: CollabChunkCodec.Header
    var chunks: [UInt16:Data] = [:]
  }

  private var partials: [String:Partial] = [:]

  mutating func ingest(_ frame: Data, from sender: String) -> Outcome {
    guard frame.starts(with: CollabChunkCodec.magic) else {return .passthrough(frame)}
    guard let (header, chunk) = CollabChunkCodec.decode(frame) else {
      partials[sender] = nil
      return .dropped
    }
    var partial = partials[sender]
    if partial?.header.transferID != header.transferID {partial = nil}
    if partial == nil {
      partial = Partial(header: header)
    }
    guard var pending = partial else {return .dropped}
    if pending.chunks[header.chunkIndex] == nil {pending.chunks[header.chunkIndex] = chunk}
    guard pending.chunks.count == Int(header.chunkCount) else {
      partials[sender] = pending
      return .pending
    }
    partials[sender] = nil
    var assembled = Data()
    assembled.reserveCapacity(Int(header.totalLength))
    for index in 0..<header.chunkCount {
      guard let next = pending.chunks[index] else {return .dropped}
      assembled.append(next)
    }
    guard assembled.count == Int(header.totalLength), CollabChunkCodec.crc32(assembled) == header.crc32 else {
      return .dropped
    }
    return .completed(assembled)
  }

  mutating func reset(sender: String) {
    partials[sender] = nil
  }
}

private extension Data {
  mutating func appendBigEndian(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) {append(contentsOf: $0)}
  }
  mutating func appendBigEndian(_ value: UInt16) {
    Swift.withUnsafeBytes(of: value.bigEndian) {append(contentsOf: $0)}
  }
  func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
    var raw: T = 0
    _ = Swift.withUnsafeMutableBytes(of: &raw) {copyBytes(to: $0, from: offset..<(offset + MemoryLayout<T>.size))}
    return T(bigEndian: raw)
  }
}
