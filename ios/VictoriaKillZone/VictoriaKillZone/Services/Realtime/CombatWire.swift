import Foundation

/// combat.v1 uses metres, x/y/z/w quaternions and the authority's millisecond clock.
enum CombatWire {
  static let maximumServerBytes = 131_072
  static let maximumClientBytes = 16_384

  struct Pose: Codable, Equatable, Sendable {
    var sequence: Int
    var capturedAtMs: Double
    var position: [Double]
    var orientation: [Double]
    var tracking: String
  }
  struct PlayerPose: Codable, Equatable, Sendable {var playerId: String; var pose: Pose}
  struct Collider: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var zone: HitZone
    var center: [Double]?
    var a: [Double]?
    var b: [Double]?
    var radius: Double
  }
  struct Observation: Codable, Equatable, Sendable {
    var targetPlayerId: String
    var capturedAtMs: Double
    var associationConfidence: Double
    var uncertaintyMeters: Double
    var colliders: [Collider]
  }
  struct Rules: Codable, Equatable, Sendable {
    struct Weapon: Codable, Equatable, Sendable {
      struct Damage: Codable, Equatable, Sendable {var head: Int; var torso: Int; var limbs: Int}
      var id: String; var kind: String; var damage: Damage
      var cooldownMs: Double; var magazine: Int; var reloadMs: Double
      var speed: Double; var projectileRadius: Double; var lifetimeMs: Double; var rangeMeters: Double
    }
    struct Shield: Codable, Equatable, Sendable {
      var radius: Double; var offsetMeters: Double; var durationMs: Double; var cooldownMs: Double; var energy: Double
    }
    struct SlowField: Codable, Equatable, Sendable {
      var radius: Double; var durationMs: Double; var cooldownMs: Double; var scale: Double
    }
    var durationMs: Double; var geometry: String; var respawnMs: Double; var protectionMs: Double
    var weapon: Weapon; var shield: Shield; var slowField: SlowField
  }
  struct Player: Codable, Equatable, Sendable, Identifiable {
    struct Shield: Codable, Equatable, Sendable {
      var activeUntilMs: Double?; var cooldownUntilMs: Double; var energy: Double
    }
    var playerId: String; var displayName: String; var role: String
    var health: Int; var ammo: Int; var kills: Int; var deaths: Int
    var connected: Bool; var frameReady: Bool
    var lastFireAtMs: Double?; var reloadEndsAtMs: Double?; var respawnAtMs: Double?; var protectedUntilMs: Double?
    var shield: Shield; var slowFieldReadyAtMs: Double
    var id: String {playerId}
  }
  struct Projectile: Codable, Equatable, Sendable, Identifiable {
    var projectileId: String; var shotId: String; var shooterId: String
    var spawnedAtMs: Double; var position: [Double]; var direction: [Double]; var speed: Double
    var segmentStartedAtMs: Double; var segmentOrigin: [Double]; var timeScale: Double
    var radius: Double; var expiresAtMs: Double; var distanceTravelled: Double
    var id: String {projectileId}

    func position(at matchTimeMs: Double) -> [Double] {
      let elapsed = max(0, min(matchTimeMs, expiresAtMs) - segmentStartedAtMs) / 1000
      guard segmentOrigin.count == 3, direction.count == 3 else {return position}
      return zip(segmentOrigin, direction).map {$0 + $1 * speed * timeScale * elapsed}
    }
  }
  struct SlowField: Codable, Equatable, Sendable, Identifiable {
    var fieldId: String; var ownerId: String; var center: [Double]; var radius: Double
    var startsAtMs: Double; var endsAtMs: Double; var scale: Double
    var id: String {fieldId}
  }
  enum Phase: String, Codable, Sendable {case calibrating, running, paused, finished}
  struct Snapshot: Codable, Equatable, Sendable {
    var matchId: String; var authorityEpoch: Int; var frameEpoch: Int
    var tick: Int; var matchTimeMs: Double; var phase: Phase; var rules: Rules
    var players: [Player]; var projectiles: [Projectile]; var slowFields: [SlowField]
    var phonePoses: [PlayerPose] = []
    var roundStartedAtMs: Double? = nil
  }

  enum Command: Encodable, Sendable {
    case pose(Pose, observations: [Observation])
    case frameReady(ready: Bool, residualMeters: Double, residualDegrees: Double, clockUncertaintyMs: Double)
    case start, reload, leave
    case fire(shotId: String, poseSequence: Int, origin: [Double], direction: [Double])
    case shield(active: Bool, poseSequence: Int)
    case slowField(poseSequence: Int)

    private enum Key: String, CodingKey {
      case kind, pose, observations, ready, residualMeters, residualDegrees, clockUncertaintyMs
      case shotId, poseSequence, origin, direction, active
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Key.self)
      switch self {
      case .pose(let pose, let observations):
        try c.encode("pose", forKey: .kind); try c.encode(pose, forKey: .pose); try c.encode(observations, forKey: .observations)
      case .frameReady(let ready, let metres, let degrees, let uncertainty):
        try c.encode("frameReady", forKey: .kind); try c.encode(ready, forKey: .ready)
        try c.encode(metres, forKey: .residualMeters); try c.encode(degrees, forKey: .residualDegrees); try c.encode(uncertainty, forKey: .clockUncertaintyMs)
      case .start: try c.encode("start", forKey: .kind)
      case .reload: try c.encode("reload", forKey: .kind)
      case .leave: try c.encode("leave", forKey: .kind)
      case .fire(let id, let sequence, let origin, let direction):
        try c.encode("fire", forKey: .kind); try c.encode(id, forKey: .shotId); try c.encode(sequence, forKey: .poseSequence)
        try c.encode(origin, forKey: .origin); try c.encode(direction, forKey: .direction)
      case .shield(let active, let sequence):
        try c.encode("shield", forKey: .kind); try c.encode(active, forKey: .active); try c.encode(sequence, forKey: .poseSequence)
      case .slowField(let sequence): try c.encode("slowField", forKey: .kind); try c.encode(sequence, forKey: .poseSequence)
      }
    }
  }
  struct Envelope: Encodable, Sendable {
    let v = 1
    var commandId: String; var clientSequence: Int; var authorityEpoch: Int; var frameEpoch: Int; var sentAtMs: Double
    var command: Command
  }
  enum ClientMessage: Encodable, Sendable {
    case command(Envelope), received(eventSequence: Int), resume(afterEventSequence: Int), ping(nonce: String, clientSentAtMs: Double)
    private enum Key: String, CodingKey {case type, envelope, eventSequence, afterEventSequence, nonce, clientSentAtMs}
    func encode(to encoder: Encoder) throws {
      var c=encoder.container(keyedBy:Key.self)
      switch self {
      case .command(let value): try c.encode("command",forKey:.type); try c.encode(value,forKey:.envelope)
      case .received(let sequence): try c.encode("received",forKey:.type); try c.encode(sequence,forKey:.eventSequence)
      case .resume(let sequence): try c.encode("resume",forKey:.type); try c.encode(sequence,forKey:.afterEventSequence)
      case .ping(let nonce,let time): try c.encode("ping",forKey:.type); try c.encode(nonce,forKey:.nonce); try c.encode(time,forKey:.clientSentAtMs)
      }
    }
  }
  struct Terminal: Decodable, Equatable, Sendable {
    var projectileId: String; var shotId: String; var shooterId: String
    var reason: String; var atMs: Double; var position: [Double]
    var targetPlayerId: String?; var zone: HitZone?; var damage: Int
  }
  enum Event: Decodable, Sendable {
    case poseChanged(playerId: String, pose: Pose)
    case commandResult(commandId: String, clientSequence: Int, playerId: String, accepted: Bool, reason: String?)
    case projectileSpawn(Projectile)
    case projectileSegment(projectileId: String, atMs: Double, position: [Double], timeScale: Double)
    case projectileTerminal(Terminal)
    case fireRefused(commandId: String, shotId: String?, playerId: String, reason: String)
    case playerChanged(Player), slowFieldChanged(SlowField), phaseChanged(Phase, reason: String)
    private enum Key: String, CodingKey {case kind, commandId, clientSequence, playerId, accepted, reason, projectile, projectileId, atMs, position, timeScale, shotId, player, field, phase, pose}
    init(from decoder: Decoder) throws {
      let c=try decoder.container(keyedBy:Key.self)
      switch try c.decode(String.self,forKey:.kind) {
      case "poseChanged": self = .poseChanged(playerId:try c.decode(String.self,forKey:.playerId),pose:try c.decode(Pose.self,forKey:.pose))
      case "commandResult": self = .commandResult(commandId:try c.decode(String.self,forKey:.commandId),clientSequence:try c.decode(Int.self,forKey:.clientSequence),playerId:try c.decode(String.self,forKey:.playerId),accepted:try c.decode(Bool.self,forKey:.accepted),reason:try c.decodeIfPresent(String.self,forKey:.reason))
      case "projectileSpawn": self = .projectileSpawn(try c.decode(Projectile.self,forKey:.projectile))
      case "projectileSegment": self = .projectileSegment(projectileId:try c.decode(String.self,forKey:.projectileId),atMs:try c.decode(Double.self,forKey:.atMs),position:try c.decode([Double].self,forKey:.position),timeScale:try c.decode(Double.self,forKey:.timeScale))
      case "projectileTerminal": self = .projectileTerminal(try Terminal(from:decoder))
      case "fireRefused": self = .fireRefused(commandId:try c.decode(String.self,forKey:.commandId),shotId:try c.decodeIfPresent(String.self,forKey:.shotId),playerId:try c.decode(String.self,forKey:.playerId),reason:try c.decode(String.self,forKey:.reason))
      case "playerChanged": self = .playerChanged(try c.decode(Player.self,forKey:.player))
      case "slowFieldChanged": self = .slowFieldChanged(try c.decode(SlowField.self,forKey:.field))
      case "phaseChanged": self = .phaseChanged(try c.decode(Phase.self,forKey:.phase),reason:try c.decode(String.self,forKey:.reason))
      default: throw DecodingError.dataCorruptedError(forKey:.kind,in:c,debugDescription:"Unknown combat event version")
      }
    }
  }
  struct ServerEvent: Decodable, Sendable {
    var v: Int; var matchId: String; var authorityEpoch: Int; var frameEpoch: Int
    var eventSequence: Int; var tick: Int; var matchTimeMs: Double; var event: Event
  }
  enum ServerMessage: Decodable, Sendable {
    case snapshot(Snapshot, eventSequence: Int, clientSequence: Int)
    case events([ServerEvent])
    case ack(commandId: String, clientSequence: Int, replayed: Bool, eventSequence: Int)
    case pong(nonce: String, clientSentAtMs: Double, serverReceivedAtMs: Double, serverSentAtMs: Double)
    case error(code: String, commandId: String?)
    private enum Key: String, CodingKey {case type, snapshot, eventSequence, clientSequence, events, commandId, replayed, nonce, clientSentAtMs, serverReceivedAtMs, serverSentAtMs, code}
    init(from decoder: Decoder) throws {
      let c=try decoder.container(keyedBy:Key.self)
      switch try c.decode(String.self,forKey:.type) {
      case "snapshot": self = .snapshot(try c.decode(Snapshot.self,forKey:.snapshot),eventSequence:try c.decode(Int.self,forKey:.eventSequence),clientSequence:try c.decode(Int.self,forKey:.clientSequence))
      case "events": self = .events(try c.decode([ServerEvent].self,forKey:.events))
      case "ack": self = .ack(commandId:try c.decode(String.self,forKey:.commandId),clientSequence:try c.decode(Int.self,forKey:.clientSequence),replayed:try c.decode(Bool.self,forKey:.replayed),eventSequence:try c.decode(Int.self,forKey:.eventSequence))
      case "pong": self = .pong(nonce:try c.decode(String.self,forKey:.nonce),clientSentAtMs:try c.decode(Double.self,forKey:.clientSentAtMs),serverReceivedAtMs:try c.decode(Double.self,forKey:.serverReceivedAtMs),serverSentAtMs:try c.decode(Double.self,forKey:.serverSentAtMs))
      case "error": self = .error(code:try c.decode(String.self,forKey:.code),commandId:try c.decodeIfPresent(String.self,forKey:.commandId))
      default: throw DecodingError.dataCorruptedError(forKey:.type,in:c,debugDescription:"Unknown combat message version")
      }
    }
  }
}
