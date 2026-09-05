import Foundation

struct CombatAccessTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  var endpoint: URL
  var token: String
  var expiresAt: Date
  var authorityEpoch: Int
  var frameEpoch: Int
  var description: String {"CombatAccessTicket(<redacted>)"}
  var debugDescription: String {description}
}

enum CombatTransportError: Error, Equatable {case invalidEndpoint, oversizedMessage, invalidMessage, disconnected, consumerTooSlow}

@MainActor
protocol CombatSocketConnecting: AnyObject {
  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage, Error>
  func send(_ message: CombatWire.ClientMessage) async throws
  func close()
}

/// One owned socket, bounded inbound messages and a cancelable receive loop.
/// Reconciliation owns retry/idempotency; this layer never invents a verdict.
@MainActor
final class CombatSocketTransport: CombatSocketConnecting {
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var reader: Task<Void, Never>?
  private var continuation: AsyncThrowingStream<CombatWire.ServerMessage, Error>.Continuation?
  private var generation = 0

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    session = URLSession(configuration:configuration)
  }

  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage, Error> {
    close()
    guard ticket.expiresAt > Date(), !ticket.token.isEmpty,
      var components = URLComponents(url:ticket.endpoint,resolvingAgainstBaseURL:false),
      components.scheme == "https", components.host != nil, components.user == nil,
      components.password == nil, components.query == nil, components.fragment == nil else {throw CombatTransportError.invalidEndpoint}
    components.scheme = "wss"
    guard let url = components.url else {throw CombatTransportError.invalidEndpoint}
    var request = URLRequest(url:url)
    request.setValue("Bearer \(ticket.token)",forHTTPHeaderField:"Authorization")
    let task = session.webSocketTask(with:request)
    task.maximumMessageSize = CombatWire.maximumServerBytes
    socket = task
    let current = generation
    let stream = AsyncThrowingStream<CombatWire.ServerMessage,Error>(bufferingPolicy:.bufferingOldest(64)) {continuation in
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          guard let self, self.generation == current else {return}
          self.close()
        }
      }
    }
    task.resume()
    reader = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let received = try await task.receive()
          guard let self, self.generation == current else {return}
          let bytes: Data
          switch received {
          case .data(let data): bytes = data
          case .string(let text): bytes = Data(text.utf8)
          @unknown default: throw CombatTransportError.invalidMessage
          }
          guard bytes.count <= CombatWire.maximumServerBytes else {throw CombatTransportError.oversizedMessage}
          let decoded = try JSONDecoder().decode(CombatWire.ServerMessage.self,from:bytes)
          guard CombatWireValidation.valid(decoded) else {throw CombatTransportError.invalidMessage}
          if case .dropped = self.continuation?.yield(decoded) {throw CombatTransportError.consumerTooSlow}
        }
      } catch {
        guard let self, self.generation == current else {return}
        // Never propagate URLRequest descriptions or server bodies containing capabilities.
        self.continuation?.finish(throwing:(error as? CombatTransportError) ?? CombatTransportError.disconnected)
        self.close()
      }
    }
    return stream
  }

  func send(_ message: CombatWire.ClientMessage) async throws {
    guard let socket else {throw CombatTransportError.disconnected}
    let bytes = try JSONEncoder().encode(message)
    guard bytes.count <= CombatWire.maximumClientBytes, let text = String(data:bytes,encoding:.utf8) else {throw CombatTransportError.oversizedMessage}
    try await socket.send(.string(text))
  }

  func close() {
    generation += 1
    reader?.cancel(); reader = nil
    socket?.cancel(with:.goingAway,reason:nil); socket = nil
    continuation?.finish(); continuation = nil
  }

  deinit {
    reader?.cancel()
    socket?.cancel(with:.goingAway,reason:nil)
    session.invalidateAndCancel()
  }
}

enum CombatWireValidation {
  static func valid(_ message: CombatWire.ServerMessage) -> Bool {
    switch message {
    case .snapshot(let s,let eventSequence,let clientSequence):
      return eventSequence >= 0 && clientSequence >= 0 && valid(s)
    case .events(let events):
      return events.count <= 64 && events.allSatisfy {
        $0.v == 1 && validID($0.matchId) && $0.authorityEpoch > 0 && $0.frameEpoch > 0 &&
          $0.eventSequence > 0 && $0.tick >= 0 && time($0.matchTimeMs) && valid($0.event)
      }
    case .ack(let id,let clientSequence,_,let eventSequence): return validID(id) && clientSequence > 0 && eventSequence >= 0
    case .pong(let nonce,let sent,let received,let serverSent): return validID(nonce) && time(sent) && time(received) && time(serverSent) && serverSent >= received
    case .error(let code,let id): return code.count <= 64 && (id == nil || validID(id!))
    }
  }

  static func valid(_ s: CombatWire.Snapshot) -> Bool {
    validID(s.matchId) && s.authorityEpoch > 0 && s.frameEpoch > 0 && s.tick >= 0 && time(s.matchTimeMs) &&
      (s.roundStartedAtMs == nil || (time(s.roundStartedAtMs!) && s.roundStartedAtMs! <= s.matchTimeMs)) &&
      (2...4).contains(s.players.count) && Set(s.players.map(\.playerId)).count == s.players.count &&
      s.players.filter({$0.role == "host"}).count == 1 && s.players.allSatisfy(valid) &&
      s.phonePoses.count <= 4 && Set(s.phonePoses.map(\.playerId)).count == s.phonePoses.count &&
      s.phonePoses.allSatisfy({sample in validID(sample.playerId) && valid(sample.pose) && s.players.contains(where:{$0.playerId == sample.playerId})}) &&
      s.projectiles.count <= 128 && Set(s.projectiles.map(\.projectileId)).count == s.projectiles.count && s.projectiles.allSatisfy(valid) &&
      s.slowFields.count <= 4 && s.slowFields.allSatisfy(valid) && valid(s.rules)
  }
  static func valid(_ p: CombatWire.Player) -> Bool {
    validID(p.playerId) && !p.displayName.isEmpty && p.displayName.count <= 24 && ["host","player"].contains(p.role) &&
      (0...100).contains(p.health) && (0...100).contains(p.ammo) && p.kills >= 0 && p.deaths >= 0 &&
      [p.lastFireAtMs,p.reloadEndsAtMs,p.respawnAtMs,p.protectedUntilMs,p.shield.activeUntilMs].allSatisfy({$0 == nil || time($0!)}) &&
      time(p.shield.cooldownUntilMs) && finite(p.shield.energy,0,1000) && time(p.slowFieldReadyAtMs)
  }
  static func valid(_ p: CombatWire.Projectile) -> Bool {
    [p.projectileId,p.shotId,p.shooterId].allSatisfy(validID) &&
      [p.spawnedAtMs,p.segmentStartedAtMs,p.expiresAtMs].allSatisfy(time) && p.expiresAtMs >= p.spawnedAtMs &&
      vector(p.position) && vector(p.segmentOrigin) && unit(p.direction) && finite(p.speed,0.1,1000) &&
      finite(p.timeScale,0.05,1) && finite(p.radius,0.001,0.25) && finite(p.distanceTravelled,0,100)
  }
  static func valid(_ f: CombatWire.SlowField) -> Bool {
    validID(f.fieldId) && validID(f.ownerId) && vector(f.center) && finite(f.radius,0.1,10) &&
      time(f.startsAtMs) && time(f.endsAtMs) && f.endsAtMs >= f.startsAtMs && finite(f.scale,0.05,1)
  }
  static func valid(_ r: CombatWire.Rules) -> Bool {
    finite(r.durationMs,10_000,3_600_000) && ["trackedBody","phoneProxy"].contains(r.geometry) &&
      finite(r.respawnMs,100,60_000) && finite(r.protectionMs,0,30_000) &&
      ["sidearm","pulse"].contains(r.weapon.id) && ["hitscan","projectile"].contains(r.weapon.kind) &&
      [r.weapon.damage.head,r.weapon.damage.torso,r.weapon.damage.limbs].allSatisfy({(1...100).contains($0)}) &&
      finite(r.weapon.cooldownMs,50,5000) && (1...100).contains(r.weapon.magazine) && finite(r.weapon.reloadMs,100,10_000) &&
      finite(r.weapon.speed,0.1,1000) && finite(r.weapon.projectileRadius,0.001,0.25) && finite(r.weapon.lifetimeMs,50,30_000) && finite(r.weapon.rangeMeters,0.1,100) &&
      finite(r.shield.radius,0.05,1) && finite(r.shield.offsetMeters,0,0.5) && finite(r.shield.durationMs,50,10_000) && finite(r.shield.cooldownMs,r.shield.durationMs,120_000) && finite(r.shield.energy,1,1000) &&
      finite(r.slowField.radius,0.1,10) && finite(r.slowField.durationMs,50,10_000) && finite(r.slowField.cooldownMs,r.slowField.durationMs,120_000) && finite(r.slowField.scale,0.05,1)
  }
  static func valid(_ event: CombatWire.Event) -> Bool {
    switch event {
    case .poseChanged(let id,let pose): return validID(id) && valid(pose)
    case .commandResult(let id,let sequence,let player,_,let reason): return validID(id) && sequence > 0 && validID(player) && (reason?.count ?? 0) <= 64
    case .projectileSpawn(let p): return valid(p)
    case .projectileSegment(let id,let at,let position,let scale): return validID(id) && time(at) && vector(position) && finite(scale,0.05,1)
    case .projectileTerminal(let t): return [t.projectileId,t.shotId,t.shooterId].allSatisfy(validID) && ["bodyHit","shieldBlocked","missExpired","cancelled"].contains(t.reason) && time(t.atMs) && vector(t.position) && (0...100).contains(t.damage) && (t.targetPlayerId == nil || validID(t.targetPlayerId!))
    case .fireRefused(let id,let shot,let player,let reason): return validID(id) && (shot == nil || validID(shot!)) && validID(player) && reason.count <= 64
    case .playerChanged(let p): return valid(p)
    case .slowFieldChanged(let f): return valid(f)
    case .phaseChanged(_,let reason): return reason.count <= 128
    }
  }
  static func valid(_ pose: CombatWire.Pose) -> Bool {
    pose.sequence >= 0 && time(pose.capturedAtMs) && vector(pose.position) &&
      pose.orientation.count == 4 && pose.orientation.allSatisfy({finite($0,-1.001,1.001)}) &&
      abs(pose.orientation.reduce(0,{$0 + $1 * $1}) - 1) <= 0.02 && ["normal","limited","lost"].contains(pose.tracking)
  }
  static func finite(_ value: Double,_ min: Double,_ max: Double) -> Bool {value.isFinite && value >= min && value <= max}
  static func time(_ value: Double) -> Bool {finite(value,0,9_007_199_254_740_991)}
  static func vector(_ value: [Double]) -> Bool {value.count == 3 && value.allSatisfy({finite($0,-1000,1000)})}
  static func unit(_ value: [Double]) -> Bool {vector(value) && abs(value.reduce(0,{$0 + $1 * $1}) - 1) <= 0.02}
  static func validID(_ value: String) -> Bool {!value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-:").contains($0)}}
}
