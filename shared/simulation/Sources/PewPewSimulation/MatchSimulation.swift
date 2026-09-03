import Foundation

public struct SimulationConfiguration: Equatable, Sendable {
  public let tickDurationMs: Int64
  public let poseHistoryCapacity: Int

  public init(tickDurationMs: Int64 = 50, poseHistoryCapacity: Int = 64) {
    precondition(tickDurationMs > 0, "tick duration must be positive")
    precondition(poseHistoryCapacity > 0, "pose history capacity must be positive")
    self.tickDurationMs = tickDurationMs
    self.poseHistoryCapacity = poseHistoryCapacity
  }
}

public enum SimulationLifeState: String, Equatable, Sendable, Codable {
  case alive
  case dead
}

public struct SimulationPlayerState: Equatable, Sendable {
  public let id: SimulationPlayerID
  public internal(set) var health: Int
  public internal(set) var lifeState: SimulationLifeState
  public internal(set) var kills: Int
  public internal(set) var deaths: Int
  public internal(set) var shotsFired: Int
  public internal(set) var shotsHit: Int
  public internal(set) var damageDealt: Int
  public internal(set) var ammo: Int
  /// Fire instant of the last accepted shot; the cooldown is measured from it.
  public internal(set) var lastShotFiredAtMs: Int64?
  /// Match-clock instant the in-progress reload completes; nil when not reloading.
  public internal(set) var reloadEndsAtMs: Int64?
  /// Match-clock instant a dead player returns; nil while alive.
  public internal(set) var respawnAtMs: Int64?
  /// Match-clock instant spawn protection lapses; nil when never protected.
  public internal(set) var spawnProtectedUntilMs: Int64?

  init(id: SimulationPlayerID) {
    self.id = id
    self.health = SimulationConstants.initialHealth
    self.lifeState = .alive
    self.kills = 0
    self.deaths = 0
    self.shotsFired = 0
    self.shotsHit = 0
    self.damageDealt = 0
    self.ammo = SidearmRules.magazineSize
    self.lastShotFiredAtMs = nil
    self.reloadEndsAtMs = nil
    self.respawnAtMs = nil
    self.spawnProtectedUntilMs = nil
  }

  public func isReloading(atMs instant: Int64) -> Bool {
    guard let reloadEndsAtMs else { return false }
    return instant < reloadEndsAtMs
  }

  public func isSpawnProtected(atMs instant: Int64) -> Bool {
    guard let spawnProtectedUntilMs else { return false }
    return instant < spawnProtectedUntilMs
  }
}

/// One element of a tick's input set. Inputs are canonicalized by
/// `MatchSimulation.advance(inputs:)`, so arrival order is not part of the log.
public enum SimulationInput: Equatable, Sendable {
  case poseSample(SimulationPlayerID, PoseSample)
  case fire(ShotClaim)
  case reload(SimulationPlayerID)
}

public enum SimulationEvent: Equatable, Sendable, Codable {
  case verdict(ShotVerdictRecord)
  case playerKilled(target: SimulationPlayerID, by: SimulationPlayerID, atTick: Int64)
  case fireRefused(shotID: String, shooter: SimulationPlayerID, reason: FireRefusalReason, atTick: Int64)
  case reloadStarted(player: SimulationPlayerID, endsAtMs: Int64, atTick: Int64)
  case reloadCompleted(player: SimulationPlayerID, atTick: Int64)
  case playerRespawned(player: SimulationPlayerID, protectedUntilMs: Int64, atTick: Int64)
}

public enum SimulationSetupError: Error, Equatable {
  case invalidPlayerCount(Int)
  case duplicatePlayerID(SimulationPlayerID)
}

/// The pure, deterministic realtime combat core (roadmap L1). One authoritative
/// instance exists per match; it owns the fixed-tick match clock, the player set
/// (2–4 members, match.v2 vocabulary — never exactly two), per-player pose-history
/// ring buffers, Sidearm weapon state, and bounded-rewind hitscan verdicts. It
/// reads no wall clock and canonicalizes each tick's input set, so identical
/// input sets always produce identical event sequences regardless of arrival order.
public struct MatchSimulation: Equatable, Sendable {
  public let configuration: SimulationConfiguration
  public private(set) var tick: Int64
  public private(set) var playerOrder: [SimulationPlayerID]
  private var players: [SimulationPlayerID: SimulationPlayerState]
  private var poseHistories: [SimulationPlayerID: PoseHistoryRingBuffer]

  public init(
    configuration: SimulationConfiguration = SimulationConfiguration(),
    playerIDs: [SimulationPlayerID]
  ) throws {
    guard
      playerIDs.count >= SimulationConstants.playerCapacityMin,
      playerIDs.count <= SimulationConstants.playerCapacityMax
    else {
      throw SimulationSetupError.invalidPlayerCount(playerIDs.count)
    }
    var players: [SimulationPlayerID: SimulationPlayerState] = [:]
    var poseHistories: [SimulationPlayerID: PoseHistoryRingBuffer] = [:]
    for id in playerIDs {
      guard players[id] == nil else {
        throw SimulationSetupError.duplicatePlayerID(id)
      }
      players[id] = SimulationPlayerState(id: id)
      poseHistories[id] = PoseHistoryRingBuffer(capacity: configuration.poseHistoryCapacity)
    }
    self.configuration = configuration
    self.tick = 0
    self.playerOrder = playerIDs
    self.players = players
    self.poseHistories = poseHistories
  }

  /// Match clock in milliseconds, defined entirely by the tick counter.
  public var clockMs: Int64 {
    tick * configuration.tickDurationMs
  }

  public func player(_ id: SimulationPlayerID) -> SimulationPlayerState? {
    players[id]
  }

  public func poseHistory(for id: SimulationPlayerID) -> PoseHistoryRingBuffer? {
    poseHistories[id]
  }

  /// Advances the match clock by one tick, settles due respawns and reloads in
  /// player order, canonicalizes the input set, applies all poses, evaluates all
  /// fire claims in canonical order against the post-advance clock, then starts
  /// requested reloads. A canonically-first lethal claim applies
  /// `min(zoneDamage, remainingHealth)`, marks its target dead, credits one kill,
  /// schedules the respawn, and emits `playerKilled`; later same-tick claims on
  /// that target no longer see it as a candidate.
  @discardableResult
  public mutating func advance(inputs: [SimulationInput] = []) -> [SimulationEvent] {
    tick += 1
    var events = settleTimers()

    let canonicalInputs = inputs.sorted { lhs, rhs in
      switch (lhs, rhs) {
      case (.poseSample(let leftPlayer, let leftSample), .poseSample(let rightPlayer, let rightSample)):
        return (
          leftPlayer.rawValue,
          leftSample.timestampMs,
          leftSample.position.x,
          leftSample.position.y,
          leftSample.position.z,
          leftSample.tracking.rawValue
        ) < (
          rightPlayer.rawValue,
          rightSample.timestampMs,
          rightSample.position.x,
          rightSample.position.y,
          rightSample.position.z,
          rightSample.tracking.rawValue
        )
      case (.fire(let left), .fire(let right)):
        return (
          left.firedAtMs,
          left.shooterID.rawValue,
          left.targetID?.rawValue ?? "",
          left.shotID
        ) < (
          right.firedAtMs,
          right.shooterID.rawValue,
          right.targetID?.rawValue ?? "",
          right.shotID
        )
      case (.reload(let left), .reload(let right)):
        return left < right
      case (.poseSample, _):
        return true
      case (_, .poseSample):
        return false
      case (.fire, .reload):
        return true
      case (.reload, .fire):
        return false
      }
    }

    for input in canonicalInputs {
      guard case .poseSample(let playerID, let sample) = input else { continue }
      poseHistories[playerID]?.record(sample)
    }
    for input in canonicalInputs {
      guard case .fire(let claim) = input else { continue }
      events.append(contentsOf: evaluate(claim))
    }
    for input in canonicalInputs {
      guard case .reload(let playerID) = input else { continue }
      events.append(contentsOf: startReload(playerID))
    }
    return events
  }

  // MARK: - Timers

  /// Respawns and reload completions due at the post-advance clock, in player order.
  private mutating func settleTimers() -> [SimulationEvent] {
    let now = clockMs
    var events: [SimulationEvent] = []
    for id in playerOrder {
      guard var state = players[id] else { continue }
      if state.lifeState == .dead, let respawnAtMs = state.respawnAtMs, respawnAtMs <= now {
        state.lifeState = .alive
        state.health = SimulationConstants.initialHealth
        state.ammo = SidearmRules.magazineSize
        state.respawnAtMs = nil
        state.reloadEndsAtMs = nil
        state.spawnProtectedUntilMs = now + SidearmRules.spawnProtectionMilliseconds
        events.append(.playerRespawned(player: id, protectedUntilMs: now + SidearmRules.spawnProtectionMilliseconds, atTick: tick))
      }
      if state.lifeState == .alive, let reloadEndsAtMs = state.reloadEndsAtMs, reloadEndsAtMs <= now {
        state.ammo = SidearmRules.magazineSize
        state.reloadEndsAtMs = nil
        events.append(.reloadCompleted(player: id, atTick: tick))
      }
      players[id] = state
    }
    return events
  }

  /// Player-initiated reload. Ignored (no event) for unknown or dead players,
  /// while a reload is already running, or when the magazine is full.
  private mutating func startReload(_ playerID: SimulationPlayerID) -> [SimulationEvent] {
    let now = clockMs
    guard var state = players[playerID],
      state.lifeState == .alive,
      !state.isReloading(atMs: now),
      state.ammo < SidearmRules.magazineSize
    else {
      return []
    }
    let endsAtMs = now + SidearmRules.reloadDurationMilliseconds
    state.reloadEndsAtMs = endsAtMs
    players[playerID] = state
    return [.reloadStarted(player: playerID, endsAtMs: endsAtMs, atTick: tick)]
  }

  // MARK: - Fire evaluation

  private enum CandidateOutcome {
    case eligible(rewoundPosition: Vector3)
    /// Spawn-protected: transparent to rays in both readings.
    case transparent
    case failed(ShotRejectionReason)
  }

  /// Bounded-rewind hitscan in the frozen §5.6 order.
  ///
  /// Shooter-side, first failure rejects: ingress geometry (`trackingLost`) →
  /// a named target that is the shooter or not a member (`invalidTarget`, a
  /// malformed claim, so no round is spent) → shooter alive (`shooterNotAlive`) →
  /// rewind window (`shotTooLate`) → shooter's latest-sample tracking
  /// (`trackingLost`). Then the Sidearm gate refuses the
  /// trigger (`fireRefused`) for spawn protection, an in-progress reload, an empty
  /// magazine, or the fire cooldown. A press that clears both spends one round and
  /// counts as fired whatever the ray finds.
  ///
  /// Candidate-side: with no named target every other member is tested and the
  /// nearest forward proxy intersection is the hit, otherwise `miss`. With a named
  /// target only that member is a candidate and its failures are reported as
  /// `invalidTarget` → `targetNotAlive` → `trackingLost` → `poseTooOld` →
  /// `targetTooClose` → `targetOutOfRange`.
  private mutating func evaluate(_ claim: ShotClaim) -> [SimulationEvent] {
    let now = clockMs
    let rewindMs = now - claim.firedAtMs

    func rejected(_ reason: ShotRejectionReason, target: SimulationPlayerID? = nil) -> [SimulationEvent] {
      [
        .verdict(
          ShotVerdictRecord(
            shot: claim,
            verdict: .rejected(reason),
            targetID: target,
            evaluatedAtTick: tick,
            rewindMilliseconds: rewindMs
          ))
      ]
    }
    func refused(_ reason: FireRefusalReason) -> [SimulationEvent] {
      [.fireRefused(shotID: claim.shotID, shooter: claim.shooterID, reason: reason, atTick: tick)]
    }

    guard claim.origin.isFinite, claim.direction.isFinite, let direction = claim.direction.normalized else {
      return rejected(.trackingLost)
    }
    guard let shooter = players[claim.shooterID] else {
      return rejected(.invalidTarget)
    }
    if let named = claim.targetID, named == claim.shooterID || players[named] == nil {
      return rejected(.invalidTarget, target: named)
    }
    guard shooter.lifeState == .alive else {
      return rejected(.shooterNotAlive)
    }
    guard rewindMs >= 0, rewindMs <= SimulationConstants.rewindCapMilliseconds else {
      return rejected(.shotTooLate)
    }
    guard let shooterLatest = poseHistories[claim.shooterID]?.latest, shooterLatest.tracking == .normal else {
      return rejected(.trackingLost)
    }

    if shooter.isSpawnProtected(atMs: claim.firedAtMs) {
      return refused(.spawnProtected)
    }
    if shooter.isReloading(atMs: claim.firedAtMs) {
      return refused(.reloading)
    }
    guard shooter.ammo > 0 else {
      return refused(.magazineEmpty)
    }
    if let lastShotFiredAtMs = shooter.lastShotFiredAtMs,
      claim.firedAtMs - lastShotFiredAtMs < SidearmRules.fireCooldownMilliseconds
    {
      return refused(.cooldownActive)
    }

    players[claim.shooterID]?.ammo -= 1
    players[claim.shooterID]?.shotsFired += 1
    players[claim.shooterID]?.lastShotFiredAtMs = claim.firedAtMs

    var eligible: [(id: SimulationPlayerID, position: Vector3)] = []
    if let named = claim.targetID {
      switch candidate(named, for: claim) {
      case .failed(let reason):
        return rejected(reason, target: named)
      case .transparent:
        break
      case .eligible(let position):
        eligible.append((named, position))
      }
    } else {
      for id in playerOrder where id != claim.shooterID {
        if case .eligible(let position) = candidate(id, for: claim) {
          eligible.append((id, position))
        }
      }
    }

    var nearest: (id: SimulationPlayerID, hit: ProxyIntersection)?
    for entry in eligible {
      guard let hit = ProxyGeometry.intersect(origin: claim.origin, direction: direction, proxyCenter: entry.position) else {
        continue
      }
      if let current = nearest {
        if hit.entryDistance < current.hit.entryDistance
          || (hit.entryDistance == current.hit.entryDistance && entry.id < current.id)
        {
          nearest = (entry.id, hit)
        }
      } else {
        nearest = (entry.id, hit)
      }
    }

    guard let (targetID, hit) = nearest, let target = players[targetID] else {
      return [
        .verdict(
          ShotVerdictRecord(
            shot: claim,
            verdict: .miss,
            evaluatedAtTick: tick,
            rewindMilliseconds: rewindMs
          ))
      ]
    }

    let appliedDamage = min(hit.zone.damage, target.health)
    players[targetID]?.health -= appliedDamage
    players[claim.shooterID]?.shotsHit += 1
    players[claim.shooterID]?.damageDealt += appliedDamage

    var events: [SimulationEvent] = [
      .verdict(
        ShotVerdictRecord(
          shot: claim,
          verdict: .hit(zone: hit.zone, appliedDamage: appliedDamage),
          targetID: targetID,
          evaluatedAtTick: tick,
          rewindMilliseconds: rewindMs
        ))
    ]

    if players[targetID]?.health == 0 {
      players[targetID]?.lifeState = .dead
      players[targetID]?.deaths += 1
      players[targetID]?.reloadEndsAtMs = nil
      players[targetID]?.respawnAtMs = now + SidearmRules.respawnDelayMilliseconds
      players[claim.shooterID]?.kills += 1
      events.append(.playerKilled(target: targetID, by: claim.shooterID, atTick: tick))
    }

    return events
  }

  /// Candidate-side checks for one member (§5.6): alive, latest tracking normal,
  /// pose resolvable within 100 ms, separation in the lane. Membership and
  /// not-self are validated at ingress for named targets and by construction
  /// (`playerOrder` minus the shooter) otherwise.
  private func candidate(_ id: SimulationPlayerID, for claim: ShotClaim) -> CandidateOutcome {
    guard let target = players[id] else {
      return .failed(.invalidTarget)
    }
    guard target.lifeState == .alive else {
      return .failed(.targetNotAlive)
    }
    if target.isSpawnProtected(atMs: claim.firedAtMs) {
      return .transparent
    }
    guard let latest = poseHistories[id]?.latest, latest.tracking == .normal else {
      return .failed(.trackingLost)
    }
    guard let resolution = poseHistories[id]?.resolvePose(atMs: claim.firedAtMs) else {
      return .failed(.poseTooOld)
    }

    let rewoundPosition: Vector3
    switch resolution {
    case .unavailable:
      return .failed(.poseTooOld)
    case .exact(let sample), .trailingEdge(let sample):
      guard sample.tracking == .normal else {
        return .failed(.trackingLost)
      }
      guard claim.firedAtMs - sample.timestampMs <= SimulationConstants.maxPoseAgeMilliseconds else {
        return .failed(.poseTooOld)
      }
      rewoundPosition = sample.position
    case .interpolated(let position, let earlier, let later):
      guard earlier.tracking == .normal, later.tracking == .normal else {
        return .failed(.trackingLost)
      }
      guard claim.firedAtMs - earlier.timestampMs <= SimulationConstants.maxPoseAgeMilliseconds else {
        return .failed(.poseTooOld)
      }
      guard later.timestampMs - earlier.timestampMs <= SimulationConstants.maxPoseAgeMilliseconds else {
        return .failed(.poseTooOld)
      }
      rewoundPosition = position
    }

    let separation = claim.origin.distance(to: rewoundPosition)
    guard separation >= SimulationConstants.minimumSeparationMeters else {
      return .failed(.targetTooClose)
    }
    guard separation <= SimulationConstants.maximumRangeMeters else {
      return .failed(.targetOutOfRange)
    }
    return .eligible(rewoundPosition: rewoundPosition)
  }
}
