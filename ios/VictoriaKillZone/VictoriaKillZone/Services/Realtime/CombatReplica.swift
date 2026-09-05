import Foundation

enum CombatReplicaError: Error, Equatable {case wrongMatch, wrongEpoch, invalidSnapshot, eventGap, invalidEvent}

/// Applies an entire ordered event batch atomically. Presentation receives only
/// new authority events, so reconnect replay cannot award damage or flash twice.
struct CombatReplica: Sendable {
  let matchID: String
  let localPlayerID: String
  private(set) var snapshot: CombatWire.Snapshot?
  private(set) var eventSequence = 0
  private(set) var clientSequence = 0

  @discardableResult
  mutating func replace(_ next: CombatWire.Snapshot, eventSequence: Int, clientSequence: Int) throws -> Bool {
    guard next.matchId == matchID, next.players.contains(where:{$0.playerId == localPlayerID}) else {throw CombatReplicaError.wrongMatch}
    guard CombatWireValidation.valid(next), eventSequence >= 0, clientSequence >= 0 else {throw CombatReplicaError.invalidSnapshot}
    if let current=snapshot {
      guard next.authorityEpoch >= current.authorityEpoch, next.frameEpoch >= current.frameEpoch else {throw CombatReplicaError.wrongEpoch}
      if next.authorityEpoch == current.authorityEpoch && eventSequence < self.eventSequence {return false}
    }
    let changedEpoch = snapshot?.authorityEpoch != next.authorityEpoch || snapshot?.frameEpoch != next.frameEpoch
    snapshot=next; self.eventSequence=eventSequence; self.clientSequence=clientSequence
    return changedEpoch
  }

  mutating func apply(_ events: [CombatWire.ServerEvent]) throws -> [CombatWire.ServerEvent] {
    guard var candidate=snapshot else {throw CombatReplicaError.invalidSnapshot}
    var nextSequence=eventSequence
    var fresh: [CombatWire.ServerEvent] = []
    for wrapped in events {
      guard wrapped.matchId == matchID else {throw CombatReplicaError.wrongMatch}
      guard wrapped.authorityEpoch == candidate.authorityEpoch, wrapped.frameEpoch == candidate.frameEpoch else {throw CombatReplicaError.wrongEpoch}
      if wrapped.eventSequence <= nextSequence {continue}
      guard wrapped.v == 1, wrapped.eventSequence == nextSequence + 1,
        wrapped.tick >= candidate.tick, wrapped.matchTimeMs >= candidate.matchTimeMs else {throw CombatReplicaError.eventGap}
      guard CombatWireValidation.valid(wrapped.event) else {throw CombatReplicaError.invalidEvent}
      try Self.apply(wrapped.event,to:&candidate)
      candidate.tick=wrapped.tick; candidate.matchTimeMs=wrapped.matchTimeMs
      nextSequence=wrapped.eventSequence; fresh.append(wrapped)
    }
    guard CombatWireValidation.valid(candidate) else {throw CombatReplicaError.invalidSnapshot}
    snapshot=candidate; eventSequence=nextSequence
    return fresh
  }

  private static func apply(_ event: CombatWire.Event,to state: inout CombatWire.Snapshot) throws {
    let members = Set(state.players.map(\.playerId))
    switch event {
    case .poseChanged(let id,let pose):
      guard members.contains(id) else {throw CombatReplicaError.invalidEvent}
      state.phonePoses.removeAll {$0.playerId == id}
      state.phonePoses.append(.init(playerId:id,pose:pose))
    case .projectileSpawn(let projectile):
      guard members.contains(projectile.shooterId), !state.projectiles.contains(where:{$0.id == projectile.id}) else {throw CombatReplicaError.invalidEvent}
      state.projectiles.append(projectile)
    case .projectileSegment(let id,let at,let position,let scale):
      guard let index=state.projectiles.firstIndex(where:{$0.id == id}), at >= state.projectiles[index].segmentStartedAtMs else {throw CombatReplicaError.invalidEvent}
      state.projectiles[index].position=position; state.projectiles[index].segmentOrigin=position
      state.projectiles[index].segmentStartedAtMs=at; state.projectiles[index].timeScale=scale
    case .projectileTerminal(let terminal):
      guard members.contains(terminal.shooterId), terminal.targetPlayerId.map({members.contains($0)}) ?? true else {throw CombatReplicaError.invalidEvent}
      // A hitscan terminal has no live projectile; it still has one event identity.
      state.projectiles.removeAll {$0.id == terminal.projectileId}
    case .playerChanged(let player):
      guard let index=state.players.firstIndex(where:{$0.id == player.id}), state.players[index].role == player.role else {throw CombatReplicaError.invalidEvent}
      state.players[index]=player
      if !player.connected || !player.frameReady {state.phonePoses.removeAll {$0.playerId == player.id}}
    case .slowFieldChanged(let field):
      guard members.contains(field.ownerId) else {throw CombatReplicaError.invalidEvent}
      state.slowFields.removeAll {$0.id == field.id || $0.endsAtMs <= field.startsAtMs}
      state.slowFields.append(field)
    case .phaseChanged(let phase,_): state.phase=phase
    case .commandResult(_,_,let player,_,_), .fireRefused(_,_,let player,_):
      guard members.contains(player) else {throw CombatReplicaError.invalidEvent}
    }
  }
}
