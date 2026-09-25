import CombatTransport
import Foundation

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
  /// One shot, broadcast once by the shooter; receivers dedup by `shotId`.
  case shotTracer(ArenaShotTracer)
  case shotRetracted(shotId: String)

  var kind: UInt8 {
    switch self {
    case .hello: 1
    case .poseSample: 2
    case .collaboration: 3
    case .worldMap: 4
    case .anchorSet: 5
    case .shotTracer: 6
    case .shotRetracted: 7
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

enum ArenaLinkBodyCodecError: Error, Equatable, Sendable {
  case unknownKind
  case malformedPayload
  case invalidShot
}

enum ArenaLinkBodyCodec {
  static func encode(_ message: ArenaLinkMessage) throws -> (kind: UInt8, body: Data) {
    let payload: Data
    switch message {
    case .hello(let playerId, let role, let method):
      payload = try JSONEncoder().encode(Hello(playerId: playerId, role: role, method: method))
    case .poseSample(let sample):
      do {
        payload = try ArenaPeerSampleCodec.encode(sample)
      } catch {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
    case .collaboration(let data), .worldMap(let data):
      payload = data
    case .anchorSet(let anchors):
      payload = try JSONEncoder().encode(anchors)
    case .shotTracer(let tracer):
      do {
        payload = try CombatFireMessageCodec.encode(.shot(try CombatShotEvent(
          shotId: tracer.shotId,
          shooterPlayerId: tracer.shooterPlayerId,
          origin: SIMD3<Float>(
            Float(tracer.ray.origin.x), Float(tracer.ray.origin.y), Float(tracer.ray.origin.z)
          ),
          direction: SIMD3<Float>(
            Float(tracer.ray.direction.x), Float(tracer.ray.direction.y), Float(tracer.ray.direction.z)
          ),
          firedAtMs: tracer.firedAtMs
        )))
      } catch {
        throw ArenaLinkBodyCodecError.invalidShot
      }
    case .shotRetracted(let shotId):
      do {
        payload = try CombatFireMessageCodec.encode(.retracted(CombatShotRetraction(shotId: shotId)))
      } catch {
        throw ArenaLinkBodyCodecError.invalidShot
      }
    }
    return (message.kind, payload)
  }

  static func decode(kind: UInt8, body: Data) throws -> ArenaLinkMessage {
    switch kind {
    case 1:
      guard let hello = try? JSONDecoder().decode(Hello.self, from: body) else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return .hello(playerId: hello.playerId, role: hello.role, method: hello.method)
    case 2:
      guard let sample = try? ArenaPeerSampleCodec.decode(body) else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return .poseSample(sample)
    case 3:
      return .collaboration(body)
    case 4:
      return .worldMap(body)
    case 5:
      guard let anchors = try? JSONDecoder().decode([ArenaNamedAnchor].self, from: body) else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return .anchorSet(anchors)
    case 6:
      let message = try decodeFire(body)
      guard case .shotTracer = message else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return message
    case 7:
      let message = try decodeFire(body)
      guard case .shotRetracted = message else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return message
    default:
      throw ArenaLinkBodyCodecError.unknownKind
    }
  }

  static func decodeFire(_ body: Data) throws -> ArenaLinkMessage {
    do {
      switch try CombatFireMessageCodec.decode(body) {
      case let .shot(event):
        return .shotTracer(ArenaShotTracer(
          shotId: event.shotId,
          shooterPlayerId: event.shooterPlayerId,
          ray: try ArenaShotRay(
            origin: ArenaVector3(
              x: Double(event.origin.x), y: Double(event.origin.y), z: Double(event.origin.z)
            ),
            direction: ArenaVector3(
              x: Double(event.direction.x), y: Double(event.direction.y), z: Double(event.direction.z)
            ),
            firedAtMs: event.firedAtMs
          )
        ))
      case let .retracted(retraction):
        return .shotRetracted(shotId: retraction.shotId)
      }
    } catch let error as ArenaLinkBodyCodecError {
      throw error
    } catch {
      throw ArenaLinkBodyCodecError.malformedPayload
    }
  }

  private struct Hello: Codable {
    let playerId: String
    let role: ArenaRole
    let method: ArenaFrameMethod
  }
}

enum ArenaLinkCodecError: Error, Equatable, Sendable {
  case truncated
  case unknownKind
  case payloadTooLarge
  case malformedPayload
}

enum ArenaLinkCodec {
  static let maxPayloadLength = 64 * 1024 * 1024
  static let lengthPrefixBytes = 4

  static func encode(_ message: ArenaLinkMessage) throws -> Data {
    let encoded = try ArenaLinkBodyCodec.encode(message)
    let payloadLength = encoded.body.count + 1
    guard payloadLength <= maxPayloadLength else {
      throw ArenaLinkCodecError.payloadTooLarge
    }

    var data = Data(capacity: lengthPrefixBytes + payloadLength)
    withUnsafeBytes(of: UInt32(payloadLength).littleEndian) {
      data.append(contentsOf: $0)
    }
    data.append(encoded.kind)
    data.append(encoded.body)
    return data
  }

  static func drainFrames(from buffer: inout Data) throws -> [ArenaLinkMessage] {
    var messages: [ArenaLinkMessage] = []
    while buffer.count >= lengthPrefixBytes {
      let length = Int(buffer.prefix(lengthPrefixBytes).withUnsafeBytes {
        $0.loadUnaligned(as: UInt32.self)
      }.littleEndian)
      guard length >= 1, length <= maxPayloadLength else {
        throw ArenaLinkCodecError.payloadTooLarge
      }
      guard buffer.count >= lengthPrefixBytes + length else { break }
      let body = buffer.subdata(in: lengthPrefixBytes..<lengthPrefixBytes + length)
      buffer.removeSubrange(0..<lengthPrefixBytes + length)
      messages.append(try decodeBody(body))
    }
    return messages
  }

  private static func decodeBody(_ body: Data) throws -> ArenaLinkMessage {
    guard let kind = body.first else {
      throw ArenaLinkCodecError.truncated
    }
    do {
      return try ArenaLinkBodyCodec.decode(kind: kind, body: Data(body.dropFirst()))
    } catch let error as ArenaLinkBodyCodecError {
      switch error {
      case .unknownKind:
        throw ArenaLinkCodecError.unknownKind
      case .malformedPayload, .invalidShot:
        throw ArenaLinkCodecError.malformedPayload
      }
    } catch {
      throw ArenaLinkCodecError.malformedPayload
    }
  }
}
