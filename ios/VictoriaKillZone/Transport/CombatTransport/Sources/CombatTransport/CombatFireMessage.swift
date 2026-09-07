import Foundation

/// Shot as fired on the shooter's phone. `firedAtMs` is MONOTONIC milliseconds
/// on the SENDER's clock (`ProcessInfo.processInfo.systemUptime * 1000`, the
/// same base as `ARFrame.timestamp`). It is not wall-clock time and is not
/// comparable across phones. Receivers order by arrival and reliable sequence,
/// using this value only for same-sender deltas.
public struct CombatShotEvent: Equatable, Sendable {
  public let shotId: String
  public let shooterPlayerId: String
  public let origin: SIMD3<Float>
  public let direction: SIMD3<Float>
  public let firedAtMs: Int64

  public init(
    shotId: String,
    shooterPlayerId: String,
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    firedAtMs: Int64
  ) throws {
    guard Self.validString(shotId), Self.validString(shooterPlayerId),
          origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
          direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
          direction != .zero
    else { throw CombatFireMessageCodecError.invalidValue }
    self.shotId = shotId
    self.shooterPlayerId = shooterPlayerId
    self.origin = origin
    self.direction = direction
    self.firedAtMs = firedAtMs
  }

  private static func validString(_ value: String) -> Bool {
    let count = value.utf8.count
    return (1...64).contains(count)
  }
}

public struct CombatShotRetraction: Equatable, Sendable {
  public let shotId: String

  public init(shotId: String) {
    self.shotId = shotId
  }
}

public enum CombatFireMessage: Equatable, Sendable {
  case shot(CombatShotEvent)
  case retracted(CombatShotRetraction)
}

public enum CombatFireMessageCodecError: Error, Equatable, Sendable {
  case truncated
  case unknownSubkind
  case invalidLength
  case invalidUTF8
  case invalidValue
  case nonFiniteComponent
  case zeroDirection
  case trailingBytes
}

public enum CombatFireMessageCodec {
  public static let maxEncodedShotLength = 163

  public static func encode(_ message: CombatFireMessage) throws -> Data {
    var data = Data()
    switch message {
    case let .shot(event):
      guard validString(event.shotId), validString(event.shooterPlayerId) else {
        throw CombatFireMessageCodecError.invalidLength
      }
      guard finite(event.origin), finite(event.direction) else {
        throw CombatFireMessageCodecError.nonFiniteComponent
      }
      guard event.direction != .zero else {
        throw CombatFireMessageCodecError.zeroDirection
      }
      data.append(1)
      try appendString(event.shotId, to: &data)
      try appendString(event.shooterPlayerId, to: &data)
      for component in [event.origin.x, event.origin.y, event.origin.z,
                        event.direction.x, event.direction.y, event.direction.z] {
        append(component.bitPattern, to: &data)
      }
      append(event.firedAtMs, to: &data)
    case let .retracted(retraction):
      guard validString(retraction.shotId) else {
        throw CombatFireMessageCodecError.invalidLength
      }
      data.append(2)
      try appendString(retraction.shotId, to: &data)
    }
    return data
  }

  public static func decode(_ data: Data) throws -> CombatFireMessage {
    var reader = Reader(data)
    switch try reader.read(UInt8.self) {
    case 1:
      let shotId = try reader.readString()
      let playerId = try reader.readString()
      let origin = SIMD3<Float>(
        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
      )
      let direction = SIMD3<Float>(
        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
      )
      guard finite(origin), finite(direction) else {
        throw CombatFireMessageCodecError.nonFiniteComponent
      }
      guard direction != .zero else { throw CombatFireMessageCodecError.zeroDirection }
      let firedAtMs = try reader.read(Int64.self)
      guard reader.isAtEnd else { throw CombatFireMessageCodecError.trailingBytes }
      do {
        return .shot(try CombatShotEvent(
          shotId: shotId,
          shooterPlayerId: playerId,
          origin: origin,
          direction: direction,
          firedAtMs: firedAtMs
        ))
      } catch {
        throw CombatFireMessageCodecError.invalidValue
      }
    case 2:
      let shotId = try reader.readString()
      guard reader.isAtEnd else { throw CombatFireMessageCodecError.trailingBytes }
      return .retracted(CombatShotRetraction(shotId: shotId))
    default:
      throw CombatFireMessageCodecError.unknownSubkind
    }
  }

  private static func finite(_ vector: SIMD3<Float>) -> Bool {
    vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
  }

  private static func validString(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count)
  }

  private static func appendString(_ value: String, to data: inout Data) throws {
    let bytes = Array(value.utf8)
    guard bytes.count > 0, bytes.count <= 64 else {
      throw CombatFireMessageCodecError.invalidLength
    }
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) {
      bytes = Array(data)
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
      let width = MemoryLayout<T>.size
      guard bytes.count - offset >= width else { throw CombatFireMessageCodecError.truncated }
      let value = bytes[offset..<(offset + width)].withUnsafeBytes {
        T(littleEndian: $0.loadUnaligned(as: T.self))
      }
      offset += width
      return value
    }

    mutating func readString() throws -> String {
      let length = Int(try read(UInt8.self))
      guard (1...64).contains(length) else {
        throw CombatFireMessageCodecError.invalidLength
      }
      guard let value = String(data: try readData(count: length), encoding: .utf8) else {
        throw CombatFireMessageCodecError.invalidUTF8
      }
      return value
    }

    mutating func readFloat() throws -> Float {
      Float(bitPattern: try read(UInt32.self))
    }

    mutating func readData(count: Int) throws -> Data {
      guard bytes.count - offset >= count else { throw CombatFireMessageCodecError.truncated }
      defer { offset += count }
      return Data(bytes[offset..<(offset + count)])
    }
  }
}
