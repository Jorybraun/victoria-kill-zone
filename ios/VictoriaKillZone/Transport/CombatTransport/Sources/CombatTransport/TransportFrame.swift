import Foundation

public enum PoseTracking: UInt8, Codable, Sendable {
  case normal = 0
  case lost = 1
}

public enum ReliableEventKind: UInt8, Codable, Sendable {
  case fire = 1
  case control = 2
}

public struct PoseFrame: Equatable, Sendable {
  public let epoch: UInt16
  public let senderSlot: UInt8
  public let sequence: UInt32
  public let timestampMs: Int64
  public let position: SIMD3<Float>
  public let orientation: SIMD4<Float>
  public let tracking: PoseTracking

  public init(
    epoch: UInt16,
    senderSlot: UInt8,
    sequence: UInt32,
    timestampMs: Int64,
    position: SIMD3<Float>,
    orientation: SIMD4<Float>,
    tracking: PoseTracking
  ) {
    self.epoch = epoch
    self.senderSlot = senderSlot
    self.sequence = sequence
    self.timestampMs = timestampMs
    self.position = position
    self.orientation = orientation
    self.tracking = tracking
  }
}

public struct ReliableEventFrame: Equatable, Sendable {
  public let epoch: UInt16
  public let senderSlot: UInt8
  public let sequence: UInt32
  public let eventKind: ReliableEventKind
  public let payload: Data

  public init(
    epoch: UInt16,
    senderSlot: UInt8,
    sequence: UInt32,
    eventKind: ReliableEventKind,
    payload: Data
  ) {
    self.epoch = epoch
    self.senderSlot = senderSlot
    self.sequence = sequence
    self.eventKind = eventKind
    self.payload = payload
  }
}

public enum TransportFrame: Equatable, Sendable {
  case pose(PoseFrame, relayed: Bool = false)
  case reliable(ReliableEventFrame, relayed: Bool = false)

  public var epoch: UInt16 {
    switch self {
    case let .pose(frame, _): frame.epoch
    case let .reliable(frame, _): frame.epoch
    }
  }

  public var senderSlot: UInt8 {
    switch self {
    case let .pose(frame, _): frame.senderSlot
    case let .reliable(frame, _): frame.senderSlot
    }
  }

  public var relayed: Bool {
    switch self {
    case let .pose(_, relayed), let .reliable(_, relayed): relayed
    }
  }
}

public enum TransportCodecError: Error, Equatable, Sendable {
  case magicMismatch
  case unsupportedVersion
  case unknownFrameKind
  case invalidEventKind
  case truncated
  case trailingBytes
  case slotOutOfRange
  case reservedFlagSet
  case payloadTooLarge
  case payloadLengthMismatch
  case zeroSequence
  case nonPositiveTimestamp
  case invalidTracking
  case nonFiniteComponent
}

public enum TransportFrameCodec {
  public static let magic: UInt16 = 0x564B
  public static let version: UInt8 = 1
  public static let maxPayloadLength = 512
  private static let headerLength = 8

  public static func encode(_ frame: TransportFrame) throws -> Data {
    var data = Data()
    switch frame {
    case let .pose(value, relayed):
      try validateHeader(senderSlot: value.senderSlot)
      guard value.sequence != 0 else { throw TransportCodecError.zeroSequence }
      guard value.timestampMs > 0 else { throw TransportCodecError.nonPositiveTimestamp }
      guard value.position.x.isFinite, value.position.y.isFinite,
            value.position.z.isFinite, value.orientation.x.isFinite,
            value.orientation.y.isFinite, value.orientation.z.isFinite,
            value.orientation.w.isFinite
      else { throw TransportCodecError.nonFiniteComponent }
      data.append(contentsOf: littleEndianBytes(magic))
      data.append(version)
      data.append(1)
      data.append(contentsOf: littleEndianBytes(value.epoch))
      data.append(value.senderSlot)
      data.append(relayed ? 1 : 0)
      data.append(contentsOf: littleEndianBytes(value.sequence))
      data.append(contentsOf: littleEndianBytes(value.timestampMs))
      for component in [value.position.x, value.position.y, value.position.z] {
        data.append(contentsOf: littleEndianBytes(component.bitPattern))
      }
      for component in [
        value.orientation.x,
        value.orientation.y,
        value.orientation.z,
        value.orientation.w,
      ] {
        data.append(contentsOf: littleEndianBytes(component.bitPattern))
      }
      data.append(value.tracking.rawValue)
    case let .reliable(value, relayed):
      try validateHeader(senderSlot: value.senderSlot)
      guard value.sequence != 0 else { throw TransportCodecError.zeroSequence }
      guard value.payload.count <= maxPayloadLength else {
        throw TransportCodecError.payloadTooLarge
      }
      data.append(contentsOf: littleEndianBytes(magic))
      data.append(version)
      data.append(2)
      data.append(contentsOf: littleEndianBytes(value.epoch))
      data.append(value.senderSlot)
      data.append(relayed ? 1 : 0)
      data.append(contentsOf: littleEndianBytes(value.sequence))
      data.append(value.eventKind.rawValue)
      data.append(contentsOf: littleEndianBytes(UInt16(value.payload.count)))
      data.append(value.payload)
    }
    return data
  }

  public static func decode(_ data: Data) throws -> TransportFrame {
    guard data.count >= headerLength else { throw TransportCodecError.truncated }
    var reader = ByteReader(data)
    guard try reader.read(UInt16.self) == magic else {
      throw TransportCodecError.magicMismatch
    }
    guard try reader.read(UInt8.self) == version else {
      throw TransportCodecError.unsupportedVersion
    }
    let kind = try reader.read(UInt8.self)
    let epoch = try reader.read(UInt16.self)
    let senderSlot = try reader.read(UInt8.self)
    guard senderSlot <= 3 else { throw TransportCodecError.slotOutOfRange }
    let flags = try reader.read(UInt8.self)
    guard flags & 0xFE == 0 else { throw TransportCodecError.reservedFlagSet }
    let relayed = flags & 1 == 1

    switch kind {
    case 1:
      let sequence = try reader.read(UInt32.self)
      guard sequence != 0 else { throw TransportCodecError.zeroSequence }
      let timestampMs = try reader.read(Int64.self)
      guard timestampMs > 0 else { throw TransportCodecError.nonPositiveTimestamp }
      let position = SIMD3<Float>(
        try readFloat(&reader),
        try readFloat(&reader),
        try readFloat(&reader)
      )
      let orientation = SIMD4<Float>(
        try readFloat(&reader),
        try readFloat(&reader),
        try readFloat(&reader),
        try readFloat(&reader)
      )
      let trackingRaw = try reader.read(UInt8.self)
      guard let tracking = PoseTracking(rawValue: trackingRaw) else {
        throw TransportCodecError.invalidTracking
      }
      guard reader.isAtEnd else { throw TransportCodecError.trailingBytes }
      return .pose(
        PoseFrame(
          epoch: epoch,
          senderSlot: senderSlot,
          sequence: sequence,
          timestampMs: timestampMs,
          position: position,
          orientation: orientation,
          tracking: tracking
        ),
        relayed: relayed
      )
    case 2:
      let sequence = try reader.read(UInt32.self)
      guard sequence != 0 else { throw TransportCodecError.zeroSequence }
      let eventKindRaw = try reader.read(UInt8.self)
      guard let eventKind = ReliableEventKind(rawValue: eventKindRaw) else {
        throw TransportCodecError.invalidEventKind
      }
      let payloadLength = Int(try reader.read(UInt16.self))
      guard payloadLength <= maxPayloadLength else {
        throw TransportCodecError.payloadTooLarge
      }
      guard reader.remaining == payloadLength else {
        throw reader.remaining < payloadLength
          ? TransportCodecError.truncated
          : TransportCodecError.payloadLengthMismatch
      }
      let payload = try reader.readData(count: payloadLength)
      return .reliable(
        ReliableEventFrame(
          epoch: epoch,
          senderSlot: senderSlot,
          sequence: sequence,
          eventKind: eventKind,
          payload: payload
        ),
        relayed: relayed
      )
    default:
      throw TransportCodecError.unknownFrameKind
    }
  }

  private static func validateHeader(senderSlot: UInt8) throws {
    guard senderSlot <= 3 else { throw TransportCodecError.slotOutOfRange }
  }

  private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
  }

  private static func readFloat(_ reader: inout ByteReader) throws -> Float {
    let bits = try reader.read(UInt32.self)
    let value = Float(bitPattern: bits)
    guard value.isFinite else { throw TransportCodecError.nonFiniteComponent }
    return value
  }
}

private struct ByteReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(_ data: Data) {
    bytes = Array(data)
  }

  var remaining: Int { bytes.count - offset }
  var isAtEnd: Bool { offset == bytes.count }

  mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
    let width = MemoryLayout<T>.size
    guard remaining >= width else { throw TransportCodecError.truncated }
    let result = bytes[offset..<(offset + width)].withUnsafeBytes {
      T(littleEndian: $0.loadUnaligned(as: T.self))
    }
    offset += width
    return result
  }

  mutating func readData(count: Int) throws -> Data {
    guard remaining >= count else { throw TransportCodecError.truncated }
    defer { offset += count }
    return Data(bytes[offset..<(offset + count)])
  }
}
