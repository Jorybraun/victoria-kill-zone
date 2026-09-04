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
      guard case let .shot(event) = try? CombatFireMessageCodec.decode(body) else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      do {
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
      } catch {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
    case 7:
      guard case let .retracted(retraction) = try? CombatFireMessageCodec.decode(body) else {
        throw ArenaLinkBodyCodecError.malformedPayload
      }
      return .shotRetracted(shotId: retraction.shotId)
    default:
      throw ArenaLinkBodyCodecError.unknownKind
    }
  }

  private struct Hello: Codable {
    let playerId: String
    let role: ArenaRole
    let method: ArenaFrameMethod
  }
}
