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

  init(id: SimulationPlayerID) {
    self.id = id
    self.health = SimulationConstants.initialHealth
    self.lifeState = .alive
    self.kills = 0
    self.deaths = 0
    self.shotsFired = 0
    self.shotsHit = 0
    self.damageDealt = 0
  }
}

/// One element of the deterministic input log. Inputs inside a tick are applied
/// strictly in array order; that order is part of the recorded log.
public enum SimulationInput: Equatable, Sendable {
  case poseSample(SimulationPlayerID, PoseSample)
  case fire(ShotClaim)
}

public enum SimulationEvent: Equatable, Sendable {
  case verdict(ShotVerdictRecord)
  case playerKilled(target: SimulationPlayerID, by: SimulationPlayerID, atTick: Int64)
}

public enum SimulationSetupError: Error, Equatable {
  case invalidPlayerCount(Int)
  case duplicatePlayerID(SimulationPlayerID)
}

/// The pure, deterministic realtime combat core (roadmap L1). One authoritative
/// instance exists per match; it owns the fixed-tick match clock, the player set
/// (2–4 members, match.v2 vocabulary — never exactly two), per-player pose-history
/// ring buffers, and bounded-rewind hitscan verdicts. It reads no wall clock and
/// iterates players only in join order, so identical input logs always produce
/// identical event sequences.
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

  /// Advances the match clock by one tick, then applies the tick's inputs in
  /// array order. Fire claims are evaluated against the post-advance clock.
  @discardableResult
  public mutating func advance(inputs: [SimulationInput] = []) -> [SimulationEvent] {
    tick += 1
    var events: [SimulationEvent] = []
    for input in inputs {
      switch input {
      case .poseSample(let playerID, let sample):
        poseHistories[playerID]?.record(sample)

      case .fire(let claim):
        events.append(contentsOf: evaluate(claim))
      }
    }
    return events
  }

  /// Bounded-rewind hitscan. Checks run in a fixed order so a claim that fails
  /// several rules always reports the same reason:
  /// membership → life states → rewind cap → tracking → pose age → separation
  /// → range → ray-vs-sphere geometry.
  private mutating func evaluate(_ claim: ShotClaim) -> [SimulationEvent] {
    let now = clockMs
    let rewindMs = now - claim.firedAtMs

    func rejected(_ reason: ShotRejectionReason) -> [SimulationEvent] {
      [
        .verdict(
          ShotVerdictRecord(
            shot: claim,
            verdict: .rejected(reason),
            evaluatedAtTick: tick,
            rewindMilliseconds: rewindMs
          ))
      ]
    }

    guard let shooter = players[claim.shooterID],
      players[claim.targetID] != nil,
      claim.targetID != claim.shooterID
    else {
      return rejected(.invalidTarget)
    }
    guard shooter.lifeState == .alive else {
      return rejected(.shooterNotAlive)
    }
    guard let target = players[claim.targetID], target.lifeState == .alive else {
      return rejected(.targetNotAlive)
    }
    guard rewindMs >= 0, rewindMs <= SimulationConstants.rewindCapMilliseconds else {
      return rejected(.shotTooLate)
    }
    guard let shooterLatest = poseHistories[claim.shooterID]?.latest,
      shooterLatest.tracking == .normal,
      let targetLatest = poseHistories[claim.targetID]?.latest,
      targetLatest.tracking == .normal
    else {
      return rejected(.trackingLost)
    }
    guard let rewoundPose = poseHistories[claim.targetID]?.sample(atOrBefore: claim.firedAtMs),
      claim.firedAtMs - rewoundPose.timestampMs <= SimulationConstants.maxPoseAgeMilliseconds
    else {
      return rejected(.poseTooOld)
    }
    guard rewoundPose.tracking == .normal else {
      return rejected(.trackingLost)
    }

    let separation = claim.origin.distance(to: rewoundPose.position)
    guard separation >= SimulationConstants.minimumSeparationMeters else {
      return rejected(.targetTooClose)
    }
    guard separation <= SimulationConstants.maximumRangeMeters else {
      return rejected(.targetOutOfRange)
    }

    players[claim.shooterID]?.shotsFired += 1

    guard let direction = claim.direction.normalized,
      rayIntersectsSphere(
        origin: claim.origin,
        direction: direction,
        center: rewoundPose.position,
        radius: SimulationConstants.proxyRadiusMeters
      )
    else {
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

    let appliedDamage = min(SimulationConstants.hitDamage, target.health)
    players[claim.targetID]?.health -= appliedDamage
    players[claim.shooterID]?.shotsHit += 1
    players[claim.shooterID]?.damageDealt += appliedDamage

    var events: [SimulationEvent] = [
      .verdict(
        ShotVerdictRecord(
          shot: claim,
          verdict: .hit(appliedDamage: appliedDamage),
          evaluatedAtTick: tick,
          rewindMilliseconds: rewindMs
        ))
    ]

    if players[claim.targetID]?.health == 0 {
      players[claim.targetID]?.lifeState = .dead
      players[claim.targetID]?.deaths += 1
      players[claim.shooterID]?.kills += 1
      events.append(.playerKilled(target: claim.targetID, by: claim.shooterID, atTick: tick))
    }

    return events
  }

  /// Forward ray against the 0.35 m phone-proxy sphere. A shot that starts
  /// inside the sphere cannot occur because the 3 m separation rule rejects first.
  private func rayIntersectsSphere(
    origin: Vector3,
    direction: Vector3,
    center: Vector3,
    radius: Double
  ) -> Bool {
    let toCenter = center - origin
    let projection = toCenter.dot(direction)
    guard projection >= 0 else { return false }
    let closestDistanceSquared = toCenter.lengthSquared - projection * projection
    return closestDistanceSquared <= radius * radius
  }
}
