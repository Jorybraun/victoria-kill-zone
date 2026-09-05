import CryptoKit
import Foundation

public struct MatchScope: Equatable, Sendable {
  public static let protocolVersion = "vkz-combat-1"
  public static let txtMatchKey = "match"
  public static let txtProtocolKey = "proto"

  public let matchId: String

  public init(matchId: String) {
    self.matchId = matchId
  }

  public var scopeId: String {
    let input = Data("vkz-combat-match-scope:\(matchId)".utf8)
    return Data(SHA256.hash(data: input)).map { String(format: "%02x", $0) }.joined().prefix(32).description
  }

  public var serviceToken: String {
    "vkz-\(scopeId)"
  }

  public var txtEntries: [String: String] {
    [Self.txtMatchKey: scopeId, Self.txtProtocolKey: Self.protocolVersion]
  }

  public func accepts(txtEntries: [String: String]) -> Bool {
    txtEntries[Self.txtMatchKey] == scopeId &&
      txtEntries[Self.txtProtocolKey] == Self.protocolVersion
  }

  public func preSharedKey(joinSecret: String) -> Data {
    Data(SHA256.hash(data: Data("vkz-combat-psk:\(matchId):\(joinSecret)".utf8)))
  }
}

public struct MatchHello: Equatable, Sendable {
  public let scopeId: String
  public let playerId: String
  public let protocolVersion: String

  public init(scopeId: String, playerId: String, protocolVersion: String) {
    self.scopeId = scopeId
    self.playerId = playerId
    self.protocolVersion = protocolVersion
  }
}

public enum MatchHelloCodecError: Error, Equatable, Sendable {
  case truncated
  case unknownSubkind
  case invalidLength
  case invalidUTF8
  case trailingBytes
}

public enum MatchHelloCodec {
  public static let subkind: UInt8 = 1
  public static let maxFieldBytes = 64

  public static func encode(_ hello: MatchHello) throws -> Data {
    let fields = [hello.scopeId, hello.playerId, hello.protocolVersion].map { Array($0.utf8) }
    guard fields.allSatisfy({ !$0.isEmpty && $0.count <= maxFieldBytes }) else {
      throw MatchHelloCodecError.invalidLength
    }
    var data = Data([subkind])
    for field in fields {
      data.append(UInt8(field.count))
      data.append(contentsOf: field)
    }
    return data
  }

  public static func decode(_ data: Data) throws -> MatchHello {
    var reader = Reader(data)
    guard try reader.read(UInt8.self) == subkind else {
      throw MatchHelloCodecError.unknownSubkind
    }
    let values = try (0..<3).map { _ -> String in
      let length = Int(try reader.read(UInt8.self))
      guard length > 0, length <= maxFieldBytes else {
        throw MatchHelloCodecError.invalidLength
      }
      guard let value = String(data: try reader.readData(count: length), encoding: .utf8) else {
        throw MatchHelloCodecError.invalidUTF8
      }
      return value
    }
    guard reader.isAtEnd else { throw MatchHelloCodecError.trailingBytes }
    return MatchHello(scopeId: values[0], playerId: values[1], protocolVersion: values[2])
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
      guard bytes.count - offset >= width else { throw MatchHelloCodecError.truncated }
      let value = bytes[offset..<(offset + width)].withUnsafeBytes {
        T(littleEndian: $0.loadUnaligned(as: T.self))
      }
      offset += width
      return value
    }

    mutating func readData(count: Int) throws -> Data {
      guard count >= 0, bytes.count - offset >= count else {
        throw MatchHelloCodecError.truncated
      }
      defer { offset += count }
      return Data(bytes[offset..<(offset + count)])
    }
  }
}
