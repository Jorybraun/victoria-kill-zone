import Foundation
import PewPewSimulation
import CombatTransport

public struct AuthorityWireCodec: Equatable, Sendable {
  public static let version: UInt8 = 1
  public let roster: AuthorityRoster

  public init(roster: AuthorityRoster) {
    self.roster = roster
  }

  public func encodePayload(_ message: AuthorityMessage) throws -> Data {
    var writer = WireWriter()
    writer.append(Self.version)
    switch message {
    case .pose:
      throw AuthorityError.malformedPayload("poses use PoseFrame")
    case let .fire(input):
      writer.append(1)
      writer.append(input.sequence)
      writer.append(try slot(for: input.slot))
      guard input.claim.shooterID == roster.playerID(for: input.slot) else {
        throw AuthorityError.malformedPayload("shooter slot mismatch")
      }
      try append(claim: input.claim, to: &writer)
    case let .reload(input):
      writer.append(2)
      writer.append(input.sequence)
      writer.append(try slot(for: input.slot))
      writer.append(input.requestedAtMs)
    case let .verdict(frame):
      writer.append(3)
      writer.append(frame.sequence)
      writer.append(frame.tick)
      try append(event: frame.event, to: &writer)
    case let .snapshot(snapshot):
      writer.append(4)
      writer.append(snapshot.sequence)
      writer.append(snapshot.tick)
      writer.append(snapshot.clockMs)
      guard snapshot.players.count <= 255 else {
        throw AuthorityError.malformedPayload("too many players")
      }
      writer.append(UInt8(snapshot.players.count))
      for player in snapshot.players {
        writer.append(player.slot)
        writer.append(try int32(player.health))
        writer.append(player.lifeState == .alive ? UInt8(0) : UInt8(1))
        writer.append(try int32(player.kills))
        writer.append(try int32(player.deaths))
        writer.append(try int32(player.ammo))
        append(optional: player.reloadEndsAtMs, to: &writer)
        append(optional: player.respawnAtMs, to: &writer)
        append(optional: player.spawnProtectedUntilMs, to: &writer)
        writer.append(player.fireLocked ? UInt8(1) : UInt8(0))
      }
    }
    return try checked(writer.data)
  }

  public func decodePayload(
    kind: ReliableEventKind,
    _ data: Data,
    senderSlot: UInt8
  ) throws -> AuthorityMessage {
    guard roster.playerID(for: senderSlot) != nil else {
      throw AuthorityError.unknownSlot(senderSlot)
    }
    guard data.count <= TransportFrameCodec.maxPayloadLength else {
      throw AuthorityError.payloadTooLarge(data.count)
    }
    var reader = WireReader(data)
    guard try reader.read(UInt8.self) == Self.version else {
      throw AuthorityError.malformedPayload("unsupported authority payload version")
    }
    let tag = try reader.read(UInt8.self)
    let message: AuthorityMessage
    switch (kind, tag) {
    case (.fire, 1):
      let sequence = try reader.read(UInt32.self)
      let slot = try reader.read(UInt8.self)
      guard slot == senderSlot else { throw AuthorityError.malformedPayload("sender slot mismatch") }
      let claim = try readClaim(from: &reader)
      guard claim.shooterID == roster.playerID(for: slot) else {
        throw AuthorityError.malformedPayload("shooter slot mismatch")
      }
      message = .fire(FireInput(slot: slot, sequence: sequence, claim: claim))
    case (.control, 2):
      let sequence = try reader.read(UInt32.self)
      let slot = try reader.read(UInt8.self)
      guard slot == senderSlot else { throw AuthorityError.malformedPayload("sender slot mismatch") }
      let requestedAtMs = try reader.read(Int64.self)
      message = .reload(
        ReloadInput(slot: slot, sequence: sequence, requestedAtMs: requestedAtMs)
      )
    case (.verdict, 3):
      let sequence = try reader.read(UInt32.self)
      let tick = try reader.read(Int64.self)
      message = .verdict(
        VerdictFrame(sequence: sequence, tick: tick, event: try readEvent(from: &reader))
      )
    case (.snapshot, 4):
      let sequence = try reader.read(UInt32.self)
      let tick = try reader.read(Int64.self)
      let clockMs = try reader.read(Int64.self)
      let count = Int(try reader.read(UInt8.self))
      guard count == roster.playerCount else {
        throw AuthorityError.malformedPayload("snapshot player count")
      }
      var players: [PlayerSnapshot] = []
      for expectedSlot in 0..<count {
        let slot = try reader.read(UInt8.self)
        guard slot == UInt8(expectedSlot),
              roster.playerID(for: slot) != nil else {
          throw AuthorityError.unknownSlot(slot)
        }
        let health = Int(try reader.read(Int32.self))
        let lifeRaw = try reader.read(UInt8.self)
        guard let lifeState = [SimulationLifeState.alive, .dead].dropFirst(Int(lifeRaw)).first,
              lifeRaw <= 1
        else {
          throw AuthorityError.malformedPayload("snapshot life state")
        }
        let kills = Int(try reader.read(Int32.self))
        let deaths = Int(try reader.read(Int32.self))
        let ammo = Int(try reader.read(Int32.self))
        let reloadEndsAtMs = try readOptional(from: &reader)
        let respawnAtMs = try readOptional(from: &reader)
        let spawnProtectedUntilMs = try readOptional(from: &reader)
        let fireLocked = try reader.read(UInt8.self)
        guard fireLocked <= 1 else {
          throw AuthorityError.malformedPayload("snapshot fire lock")
        }
        players.append(
          PlayerSnapshot(
            slot: slot,
            health: health,
            lifeState: lifeState,
            kills: kills,
            deaths: deaths,
            ammo: ammo,
            reloadEndsAtMs: reloadEndsAtMs,
            respawnAtMs: respawnAtMs,
            spawnProtectedUntilMs: spawnProtectedUntilMs,
            fireLocked: fireLocked == 1
          )
        )
      }
      message = .snapshot(
        StateSnapshot(
          sequence: sequence,
          tick: tick,
          clockMs: clockMs,
          players: players
        )
      )
    default:
      throw AuthorityError.malformedPayload("payload kind mismatch")
    }
    guard reader.isAtEnd else { throw AuthorityError.malformedPayload("trailing bytes") }
    return message
  }

  public func poseFrame(
    from input: PoseInput,
    epoch: UInt16,
    orientation: SIMD4<Float>
  ) -> PoseFrame {
    PoseFrame(
      epoch: epoch,
      senderSlot: input.slot,
      sequence: input.sequence,
      timestampMs: input.sample.timestampMs,
      position: SIMD3(
        Float(input.sample.position.x),
        Float(input.sample.position.y),
        Float(input.sample.position.z)
      ),
      orientation: orientation,
      tracking: input.sample.tracking == .normal ? .normal : .lost
    )
  }

  public func poseInput(from frame: PoseFrame) -> PoseInput {
    PoseInput(
      slot: frame.senderSlot,
      sequence: frame.sequence,
      sample: PoseSample(
        timestampMs: frame.timestampMs,
        position: Vector3(
          Double(frame.position.x),
          Double(frame.position.y),
          Double(frame.position.z)
        ),
        tracking: frame.tracking == .normal ? .normal : .lost
      )
    )
  }

  public func reliableFrame(
    _ message: AuthorityMessage,
    epoch: UInt16,
    senderSlot: UInt8,
    sequence: UInt32
  ) throws -> ReliableEventFrame {
    let kind: ReliableEventKind
    switch message {
    case .fire: kind = .fire
    case .reload: kind = .control
    case .verdict: kind = .verdict
    case .snapshot: kind = .snapshot
    case .pose:
      throw AuthorityError.malformedPayload("poses use PoseFrame")
    }
    return ReliableEventFrame(
      epoch: epoch,
      senderSlot: senderSlot,
      sequence: sequence,
      eventKind: kind,
      payload: try encodePayload(message)
    )
  }

  public func message(from frame: ReliableEventFrame) throws -> AuthorityMessage {
    try decodePayload(kind: frame.eventKind, frame.payload, senderSlot: frame.senderSlot)
  }

  private func checked(_ data: Data) throws -> Data {
    guard data.count <= TransportFrameCodec.maxPayloadLength else {
      throw AuthorityError.payloadTooLarge(data.count)
    }
    return data
  }

  private func slot(for id: UInt8) throws -> UInt8 {
    guard roster.playerID(for: id) != nil else { throw AuthorityError.unknownSlot(id) }
    return id
  }

  private func slot(for id: SimulationPlayerID) throws -> UInt8 {
    guard let slot = roster.slot(for: id) else {
      throw AuthorityError.unknownPlayer(id)
    }
    return slot
  }

  private func int32(_ value: Int) throws -> Int32 {
    guard let result = Int32(exactly: value) else {
      throw AuthorityError.malformedPayload("integer out of range")
    }
    return result
  }

  private func append(
    optional value: Int64?,
    to writer: inout WireWriter
  ) {
    if let value {
      writer.append(UInt8(1))
      writer.append(value)
    } else {
      writer.append(UInt8(0))
    }
  }

  private func readOptional(from reader: inout WireReader) throws -> Int64? {
    let present = try reader.read(UInt8.self)
    guard present <= 1 else {
      throw AuthorityError.malformedPayload("invalid optional value")
    }
    return present == 1 ? try reader.read(Int64.self) : nil
  }

  private func append(
    claim: ShotClaim,
    to writer: inout WireWriter
  ) throws {
    try append(string: claim.shotID, to: &writer)
    writer.append(try slot(for: claim.shooterID))
    if let targetID = claim.targetID {
      writer.append(try slot(for: targetID))
    } else {
      writer.append(UInt8.max)
    }
    append(vector: claim.origin, to: &writer)
    append(vector: claim.direction, to: &writer)
    writer.append(claim.firedAtMs)
  }

  private func readClaim(from reader: inout WireReader) throws -> ShotClaim {
    let shotID = try readString(from: &reader)
    let shooterSlot = try reader.read(UInt8.self)
    guard let shooterID = roster.playerID(for: shooterSlot) else {
      throw AuthorityError.unknownSlot(shooterSlot)
    }
    let targetSlot = try reader.read(UInt8.self)
    let targetID: SimulationPlayerID?
    if targetSlot == UInt8.max {
      targetID = nil
    } else {
      guard let id = roster.playerID(for: targetSlot) else {
        throw AuthorityError.unknownSlot(targetSlot)
      }
      targetID = id
    }
    let origin = try readVector(from: &reader)
    let direction = try readVector(from: &reader)
    let firedAtMs = try reader.read(Int64.self)
    return ShotClaim(
      shotID: shotID,
      shooterID: shooterID,
      targetID: targetID,
      origin: origin,
      direction: direction,
      firedAtMs: firedAtMs
    )
  }

  private func append(
    event: SimulationEvent,
    to writer: inout WireWriter
  ) throws {
    switch event {
    case let .verdict(record):
      writer.append(UInt8(1))
      try append(record: record, to: &writer)
    case let .playerKilled(target, by, atTick):
      writer.append(UInt8(2))
      writer.append(try slot(for: target))
      writer.append(try slot(for: by))
      writer.append(atTick)
    case let .fireRefused(shotID, shooter, reason, atTick):
      writer.append(UInt8(3))
      try append(string: shotID, to: &writer)
      writer.append(try slot(for: shooter))
      writer.append(fireRefusalRaw(reason))
      writer.append(atTick)
    case let .reloadStarted(player, endsAtMs, atTick):
      writer.append(UInt8(4))
      writer.append(try slot(for: player))
      writer.append(endsAtMs)
      writer.append(atTick)
    case let .reloadCompleted(player, atTick):
      writer.append(UInt8(5))
      writer.append(try slot(for: player))
      writer.append(atTick)
    case let .playerRespawned(player, protectedUntilMs, atTick):
      writer.append(UInt8(6))
      writer.append(try slot(for: player))
      writer.append(protectedUntilMs)
      writer.append(atTick)
    }
  }

  private func readEvent(from reader: inout WireReader) throws -> SimulationEvent {
    switch try reader.read(UInt8.self) {
    case 1:
      return .verdict(try readRecord(from: &reader))
    case 2:
      return .playerKilled(
        target: try player(from: &reader),
        by: try player(from: &reader),
        atTick: try reader.read(Int64.self)
      )
    case 3:
      let shotID = try readString(from: &reader)
      let shooter = try player(from: &reader)
      let reason = try fireRefusal(from: &reader)
      return .fireRefused(
        shotID: shotID,
        shooter: shooter,
        reason: reason,
        atTick: try reader.read(Int64.self)
      )
    case 4:
      return .reloadStarted(
        player: try player(from: &reader),
        endsAtMs: try reader.read(Int64.self),
        atTick: try reader.read(Int64.self)
      )
    case 5:
      return .reloadCompleted(
        player: try player(from: &reader),
        atTick: try reader.read(Int64.self)
      )
    case 6:
      return .playerRespawned(
        player: try player(from: &reader),
        protectedUntilMs: try reader.read(Int64.self),
        atTick: try reader.read(Int64.self)
      )
    default:
      throw AuthorityError.malformedPayload("unknown simulation event")
    }
  }

  private func append(
    record: ShotVerdictRecord,
    to writer: inout WireWriter
  ) throws {
    try append(claim: record.shot, to: &writer)
    append(verdict: record.verdict, to: &writer)
    if let targetID = record.targetID {
      writer.append(try slot(for: targetID))
    } else {
      writer.append(UInt8.max)
    }
    writer.append(record.evaluatedAtTick)
    writer.append(record.rewindMilliseconds)
  }

  private func readRecord(from reader: inout WireReader) throws -> ShotVerdictRecord {
    let shot = try readClaim(from: &reader)
    let verdict = try readVerdict(from: &reader)
    let targetSlot = try reader.read(UInt8.self)
    let targetID: SimulationPlayerID?
    if targetSlot == UInt8.max {
      targetID = nil
    } else {
      guard let id = roster.playerID(for: targetSlot) else {
        throw AuthorityError.unknownSlot(targetSlot)
      }
      targetID = id
    }
    return ShotVerdictRecord(
      shot: shot,
      verdict: verdict,
      targetID: targetID,
      evaluatedAtTick: try reader.read(Int64.self),
      rewindMilliseconds: try reader.read(Int64.self)
    )
  }

  private func append(
    verdict: SpatialVerdict,
    to writer: inout WireWriter
  ) {
    switch verdict {
    case let .hit(zone, appliedDamage):
      writer.append(UInt8(1))
      writer.append(hitZoneRaw(zone))
      writer.append(Int32(appliedDamage))
    case .miss:
      writer.append(UInt8(2))
    case let .rejected(reason):
      writer.append(UInt8(3))
      writer.append(shotRejectionRaw(reason))
    }
  }

  private func readVerdict(from reader: inout WireReader) throws -> SpatialVerdict {
    switch try reader.read(UInt8.self) {
    case 1:
      let zone = try hitZone(from: &reader)
      return .hit(zone: zone, appliedDamage: Int(try reader.read(Int32.self)))
    case 2:
      return .miss
    case 3:
      return .rejected(try shotRejection(from: &reader))
    default:
      throw AuthorityError.malformedPayload("unknown spatial verdict")
    }
  }

  private func player(from reader: inout WireReader) throws -> SimulationPlayerID {
    let slot = try reader.read(UInt8.self)
    guard let id = roster.playerID(for: slot) else {
      throw AuthorityError.unknownSlot(slot)
    }
    return id
  }

  private func append(string: String, to writer: inout WireWriter) throws {
    let bytes = Array(string.utf8)
    guard bytes.count <= 64 else {
      throw AuthorityError.malformedPayload("string too long")
    }
    writer.append(UInt8(bytes.count))
    writer.append(contentsOf: bytes)
  }

  private func readString(from reader: inout WireReader) throws -> String {
    let length = Int(try reader.read(UInt8.self))
    guard length <= 64 else { throw AuthorityError.malformedPayload("string too long") }
    let bytes = try reader.readData(count: length)
    guard let value = String(data: bytes, encoding: .utf8) else {
      throw AuthorityError.malformedPayload("invalid UTF-8")
    }
    return value
  }

  private func append(vector: Vector3, to writer: inout WireWriter) {
    writer.append(Float(vector.x).bitPattern)
    writer.append(Float(vector.y).bitPattern)
    writer.append(Float(vector.z).bitPattern)
  }

  private func readVector(from reader: inout WireReader) throws -> Vector3 {
    let values = try (0..<3).map { _ in
      Float(bitPattern: try reader.read(UInt32.self))
    }
    guard values.allSatisfy(\.isFinite) else {
      throw AuthorityError.malformedPayload("non-finite vector")
    }
    return Vector3(Double(values[0]), Double(values[1]), Double(values[2]))
  }

  private func hitZoneRaw(_ zone: HitZone) -> UInt8 {
    switch zone {
    case .head: 1
    case .torso: 2
    case .limbs: 3
    }
  }

  private func hitZone(from reader: inout WireReader) throws -> HitZone {
    switch try reader.read(UInt8.self) {
    case 1: .head
    case 2: .torso
    case 3: .limbs
    default: throw AuthorityError.malformedPayload("unknown hit zone")
    }
  }

  private func shotRejectionRaw(_ reason: ShotRejectionReason) -> UInt8 {
    switch reason {
    case .trackingLost: 1
    case .targetTooClose: 2
    case .targetOutOfRange: 3
    case .poseTooOld: 4
    case .shotTooLate: 5
    case .invalidTarget: 6
    case .targetNotAlive: 7
    case .shooterNotAlive: 8
    }
  }

  private func shotRejection(from reader: inout WireReader) throws -> ShotRejectionReason {
    switch try reader.read(UInt8.self) {
    case 1: .trackingLost
    case 2: .targetTooClose
    case 3: .targetOutOfRange
    case 4: .poseTooOld
    case 5: .shotTooLate
    case 6: .invalidTarget
    case 7: .targetNotAlive
    case 8: .shooterNotAlive
    default: throw AuthorityError.malformedPayload("unknown shot rejection")
    }
  }

  private func fireRefusalRaw(_ reason: FireRefusalReason) -> UInt8 {
    switch reason {
    case .spawnProtected: 1
    case .reloading: 2
    case .magazineEmpty: 3
    case .cooldownActive: 4
    }
  }

  private func fireRefusal(from reader: inout WireReader) throws -> FireRefusalReason {
    switch try reader.read(UInt8.self) {
    case 1: .spawnProtected
    case 2: .reloading
    case 3: .magazineEmpty
    case 4: .cooldownActive
    default: throw AuthorityError.malformedPayload("unknown fire refusal")
    }
  }
}

private struct WireWriter: Sendable {
  var data = Data()

  mutating func append(_ value: UInt8) {
    data.append(value)
  }

  mutating func append(_ value: UInt32) {
    appendBytes(
      UInt8(truncatingIfNeeded: value),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 24)
    )
  }

  mutating func append(_ value: Int32) {
    append(UInt32(bitPattern: value))
  }

  mutating func append(_ value: Int64) {
    let bits = UInt64(bitPattern: value)
    appendBytes(
      UInt8(truncatingIfNeeded: bits),
      UInt8(truncatingIfNeeded: bits >> 8),
      UInt8(truncatingIfNeeded: bits >> 16),
      UInt8(truncatingIfNeeded: bits >> 24),
      UInt8(truncatingIfNeeded: bits >> 32),
      UInt8(truncatingIfNeeded: bits >> 40),
      UInt8(truncatingIfNeeded: bits >> 48),
      UInt8(truncatingIfNeeded: bits >> 56)
    )
  }

  mutating func append(_ value: Int) {
    precondition((0...255).contains(value))
    data.append(UInt8(value))
  }

  mutating func append<T: FixedWidthInteger>(_ value: T) {
    let littleEndian = value.littleEndian
    data.append(contentsOf: withUnsafeBytes(of: littleEndian, Array.init))
  }

  mutating func appendBytes(_ bytes: UInt8...) {
    data.append(contentsOf: bytes)
  }

  mutating func append(contentsOf bytes: [UInt8]) {
    data.append(contentsOf: bytes)
  }
}

private struct WireReader: Sendable {
  let data: Data
  var index = 0

  var isAtEnd: Bool { index == data.count }

  init(_ data: Data) {
    self.data = data
  }

  mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
    let bytes = try readData(count: MemoryLayout<T>.size)
    var value: T = 0
    for byte in bytes {
      value = (value << 8) | T(byte)
    }
    return T(littleEndian: value.byteSwapped)
  }

  mutating func readData(count: Int) throws -> Data {
    guard count >= 0, data.count - index >= count else {
      throw AuthorityError.malformedPayload("truncated payload")
    }
    defer { index += count }
    return Data(data[index..<(index + count)])
  }
}
