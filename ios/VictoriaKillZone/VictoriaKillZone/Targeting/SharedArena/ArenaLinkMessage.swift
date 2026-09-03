import Foundation

// MARK: - Harness peer-channel message framing (KIL-20)
//
// The KIL-35 `CombatTransport` package is not yet linked into the app and its
// reliable channel caps payloads at 512 bytes, which cannot carry an
// `ARWorldMap` (hundreds of KB) or `ARCollaborationData`. The two-phone proof
// therefore uses its own bulk channel with this framing. Folding it into the
// combat transport (chunked bulk stream) is a KIL-35 follow-up, not a change
// this slice may make.
//
// Wire format, little-endian: `UInt32 length` (of everything after it),
// `UInt8 kind`, payload.

enum ArenaLinkMessage: Equatable, Sendable {
  /// First message on a connection; identifies the sender and the method it
  /// is running so mismatched runs fail immediately instead of silently.
  case hello(playerId: String, role: ArenaRole, method: ArenaFrameMethod)
  case poseSample(ArenaPeerSample)
  /// Opaque `ARSession.CollaborationData` archive.
  case collaboration(Data)
  /// Opaque `ARWorldMap` archive (host → guest, once).
  case worldMap(Data)
  /// Named arena anchors the host placed, so both phones render the same IDs
  /// even before (or without) anchor propagation through the frame method.
  case anchorSet([ArenaNamedAnchor])

  var kind: UInt8 {
    switch self {
    case .hello: 1
    case .poseSample: 2
    case .collaboration: 3
    case .worldMap: 4
    case .anchorSet: 5
    }
  }
}

struct ArenaNamedAnchor: Equatable, Codable, Sendable {
  let name: String
  let columnMajor: [Double]

  init(name: String, transform: ArenaRigidTransform) {
    self.name = name
    columnMajor = transform.columnMajor
  }

  func transform() throws -> ArenaRigidTransform {
    try ArenaRigidTransform(columnMajor: columnMajor)
  }
}

enum ArenaLinkCodecError: Error, Equatable, Sendable {
  case truncated
  case unknownKind
  case payloadTooLarge
  case malformedPayload
}

enum ArenaLinkCodec {
  /// Generous ceiling for a serialized world map; anything larger is a bug or
  /// an attack, not a valid arena.
  static let maxPayloadLength = 64 * 1024 * 1024
  static let lengthPrefixBytes = 4

  static func encode(_ message: ArenaLinkMessage) throws -> Data {
    let payload: Data
    switch message {
    case .hello(let playerId, let role, let method):
      payload = try JSONEncoder().encode(Hello(playerId: playerId, role: role, method: method))
    case .poseSample(let sample):
      do {
        payload = try ArenaPeerSampleCodec.encode(sample)
      } catch {
        throw ArenaLinkCodecError.malformedPayload
      }
    case .collaboration(let data), .worldMap(let data):
      payload = data
    case .anchorSet(let anchors):
      payload = try JSONEncoder().encode(anchors)
    }
    guard payload.count + 1 <= maxPayloadLength else { throw ArenaLinkCodecError.payloadTooLarge }

    var data = Data(capacity: lengthPrefixBytes + 1 + payload.count)
    withUnsafeBytes(of: UInt32(payload.count + 1).littleEndian) { data.append(contentsOf: $0) }
    data.append(message.kind)
    data.append(payload)
    return data
  }

  /// Parses as many complete frames as `buffer` holds, removing them from the
  /// buffer. Leaves a trailing partial frame in place for the next read.
  static func drainFrames(from buffer: inout Data) throws -> [ArenaLinkMessage] {
    var messages: [ArenaLinkMessage] = []
    while buffer.count >= lengthPrefixBytes {
      let length = Int(buffer.prefix(lengthPrefixBytes).withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self)
      }.littleEndian)
      guard length >= 1, length <= maxPayloadLength else { throw ArenaLinkCodecError.payloadTooLarge }
      guard buffer.count >= lengthPrefixBytes + length else { break }
      let body = buffer.subdata(in: lengthPrefixBytes..<lengthPrefixBytes + length)
      buffer.removeSubrange(0..<lengthPrefixBytes + length)
      messages.append(try decodeBody(body))
    }
    return messages
  }

  private static func decodeBody(_ body: Data) throws -> ArenaLinkMessage {
    guard let kind = body.first else { throw ArenaLinkCodecError.truncated }
    let payload = body.dropFirst()
    switch kind {
    case 1:
      guard let hello = try? JSONDecoder().decode(Hello.self, from: payload) else {
        throw ArenaLinkCodecError.malformedPayload
      }
      return .hello(playerId: hello.playerId, role: hello.role, method: hello.method)
    case 2:
      guard let sample = try? ArenaPeerSampleCodec.decode(Data(payload)) else {
        throw ArenaLinkCodecError.malformedPayload
      }
      return .poseSample(sample)
    case 3:
      return .collaboration(Data(payload))
    case 4:
      return .worldMap(Data(payload))
    case 5:
      guard let anchors = try? JSONDecoder().decode([ArenaNamedAnchor].self, from: payload) else {
        throw ArenaLinkCodecError.malformedPayload
      }
      return .anchorSet(anchors)
    default:
      throw ArenaLinkCodecError.unknownKind
    }
  }

  private struct Hello: Codable {
    let playerId: String
    let role: ArenaRole
    let method: ArenaFrameMethod
  }
}
