import Foundation
import PewPewSimulation

public struct AuthorityClientConfiguration: Equatable, Sendable {
  public var hostTimeoutMs: Int64

  public init(hostTimeoutMs: Int64 = 1_500) {
    self.hostTimeoutMs = hostTimeoutMs
  }
}

public enum MatchPhase: Equatable, Sendable {
  case awaitingHost
  case live
  case hostLost
}

public struct PredictedShot: Equatable, Sendable {
  public let claim: ShotClaim
  public let predictedAtMs: Int64

  public init(claim: ShotClaim, predictedAtMs: Int64) {
    self.claim = claim
    self.predictedAtMs = predictedAtMs
  }
}

public enum FireLockReason: Equatable, Sendable {
  case hostLost
  case awaitingHost
  case memberFireLocked
}

public enum AuthorityClientEffect: Equatable, Sendable {
  case send(AuthorityMessage)
  case predictionResolved(shotID: String, verdict: ShotVerdictRecord, latencyMs: Int64)
  case predictionRefused(shotID: String, reason: FireRefusalReason, latencyMs: Int64)
  case eventApplied(SimulationEvent)
  case snapshotApplied(StateSnapshot)
  case verdictGap(expected: UInt32, received: UInt32)
  case hostLost(atMs: Int64)
  case fireRefusedLocally(FireLockReason)
}

public struct AuthorityClient: Equatable, Sendable {
  public let slot: UInt8
  public let roster: AuthorityRoster
  public let configuration: AuthorityClientConfiguration
  public private(set) var phase: MatchPhase = .awaitingHost
  public private(set) var players: [UInt8: PlayerSnapshot] = [:]
  public private(set) var pendingPredictions: [String: PredictedShot] = [:]
  public private(set) var appliedVerdicts: [VerdictFrame] = []
  public private(set) var lastVerdictSequence: UInt32 = 0
  public private(set) var lastHeardFromHostAtMs: Int64?

  private var poseSequence: UInt32 = 0
  private var reliableSequence: UInt32 = 0

  public init(
    slot: UInt8,
    roster: AuthorityRoster,
    configuration: AuthorityClientConfiguration = .init()
  ) {
    self.slot = slot
    self.roster = roster
    self.configuration = configuration
    for memberSlot in 0..<UInt8(roster.playerCount) {
      players[memberSlot] = PlayerSnapshot(
        slot: memberSlot,
        health: SimulationConstants.initialHealth,
        lifeState: .alive,
        kills: 0,
        deaths: 0,
        ammo: SidearmRules.magazineSize,
        reloadEndsAtMs: nil,
        respawnAtMs: nil,
        spawnProtectedUntilMs: nil,
        fireLocked: false
      )
    }
  }

  public mutating func pose(_ sample: PoseSample) -> AuthorityClientEffect {
    poseSequence &+= 1
    return .send(
      .pose(PoseInput(slot: slot, sequence: poseSequence, sample: sample))
    )
  }

  public mutating func fire(
    _ claim: ShotClaim,
    atMs: Int64
  ) -> [AuthorityClientEffect] {
    switch phase {
    case .hostLost:
      return [.fireRefusedLocally(.hostLost)]
    case .awaitingHost:
      return [.fireRefusedLocally(.awaitingHost)]
    case .live:
      if players[slot]?.fireLocked == true {
        return [.fireRefusedLocally(.memberFireLocked)]
      }
    }
    reliableSequence &+= 1
    pendingPredictions[claim.shotID] = PredictedShot(
      claim: claim,
      predictedAtMs: atMs
    )
    return [
      .send(
        .fire(
          FireInput(slot: slot, sequence: reliableSequence, claim: claim)
        )
      )
    ]
  }

  public mutating func reload(atMs: Int64) -> [AuthorityClientEffect] {
    reliableSequence &+= 1
    return [
      .send(
        .reload(
          ReloadInput(
            slot: slot,
            sequence: reliableSequence,
            requestedAtMs: atMs
          )
        )
      )
    ]
  }

  public mutating func receive(
    _ message: AuthorityMessage,
    atMs: Int64
  ) -> [AuthorityClientEffect] {
    guard phase != .hostLost else { return [] }
    lastHeardFromHostAtMs = atMs
    if phase == .awaitingHost {
      phase = .live
    }
    switch message {
    case let .snapshot(snapshot):
      players = Dictionary(uniqueKeysWithValues: snapshot.players.map { ($0.slot, $0) })
      lastVerdictSequence = snapshot.sequence
      return [.snapshotApplied(snapshot)]
    case let .verdict(frame):
      var effects: [AuthorityClientEffect] = []
      let expected = lastVerdictSequence &+ 1
      if frame.sequence != expected {
        effects.append(.verdictGap(expected: expected, received: frame.sequence))
      }
      lastVerdictSequence = frame.sequence
      appliedVerdicts.append(frame)
      switch frame.event {
      case let .verdict(record)
        where record.shot.shooterID == roster.playerID(for: slot)
          && pendingPredictions[record.shot.shotID] != nil:
        let prediction = pendingPredictions.removeValue(forKey: record.shot.shotID)!
        effects.append(
          .predictionResolved(
            shotID: record.shot.shotID,
            verdict: record,
            latencyMs: atMs - prediction.predictedAtMs
          )
        )
        apply(frame.event)
      case let .fireRefused(shotID, shooter, reason, _)
        where shooter == roster.playerID(for: slot)
          && pendingPredictions[shotID] != nil:
        let prediction = pendingPredictions.removeValue(forKey: shotID)!
        effects.append(
          .predictionRefused(
            shotID: shotID,
            reason: reason,
            latencyMs: atMs - prediction.predictedAtMs
          )
        )
        apply(frame.event)
      default:
        apply(frame.event)
        effects.append(.eventApplied(frame.event))
      }
      return effects
    case .pose, .fire, .reload:
      return []
    }
  }

  public mutating func advance(nowMs: Int64) -> [AuthorityClientEffect] {
    guard phase == .live,
          let lastHeardFromHostAtMs,
          nowMs - lastHeardFromHostAtMs > configuration.hostTimeoutMs
    else { return [] }
    phase = .hostLost
    return [.hostLost(atMs: nowMs)]
  }

  private mutating func apply(_ event: SimulationEvent) {
    switch event {
    case let .verdict(record):
      guard case let .hit(_, damage) = record.verdict,
            let targetSlot = record.targetID.flatMap(roster.slot(for:))
      else { return }
      update(targetSlot) { player in
        player.health = max(0, player.health - damage)
      }
    case let .playerKilled(target, _, _):
      guard let targetSlot = roster.slot(for: target) else { return }
      update(targetSlot) { player in
        player.lifeState = .dead
        player.deaths += 1
        player.respawnAtMs = nil
      }
    case .fireRefused:
      break
    case let .reloadStarted(player, endsAtMs, _):
      guard let playerSlot = roster.slot(for: player) else { return }
      update(playerSlot) { $0.reloadEndsAtMs = endsAtMs }
    case let .reloadCompleted(player, _):
      guard let playerSlot = roster.slot(for: player) else { return }
      update(playerSlot) {
        $0.ammo = SidearmRules.magazineSize
        $0.reloadEndsAtMs = nil
      }
    case let .playerRespawned(player, protectedUntilMs, _):
      guard let playerSlot = roster.slot(for: player) else { return }
      update(playerSlot) {
        $0.health = SimulationConstants.initialHealth
        $0.lifeState = .alive
        $0.ammo = SidearmRules.magazineSize
        $0.respawnAtMs = nil
        $0.spawnProtectedUntilMs = protectedUntilMs
      }
    }
  }

  private mutating func update(
    _ slot: UInt8,
    _ body: (inout PlayerSnapshot) -> Void
  ) {
    guard let old = players[slot] else { return }
    var updated = old
    body(&updated)
    players[slot] = updated
  }
}
