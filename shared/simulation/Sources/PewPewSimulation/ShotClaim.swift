import Foundation

/// Stable identity of a match member. Comparable so ordered iteration never
/// depends on hash order.
public struct SimulationPlayerID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public static func < (lhs: SimulationPlayerID, rhs: SimulationPlayerID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    rawValue
  }
}

/// One Frame-Aligned Shot Claim (spatial-hit.v1 vocabulary): the shooter's ray
/// in the Shared Arena Frame plus the match-clock instant it was fired.
///
/// `targetID` is optional (§5.0). When nil the authority tests the ray against
/// every hittable candidate and the nearest forward intersection is the hit.
/// When a target is named — the legacy contract shape — only that member is a
/// candidate and its candidate-side failures are reported as rejections in the
/// §5.6 order. Naming a target can never turn a geometric miss into a hit.
public struct ShotClaim: Equatable, Sendable, Codable {
  public let shotID: String
  public let shooterID: SimulationPlayerID
  public let targetID: SimulationPlayerID?
  public let origin: Vector3
  public let direction: Vector3
  public let firedAtMs: Int64

  public init(
    shotID: String,
    shooterID: SimulationPlayerID,
    targetID: SimulationPlayerID? = nil,
    origin: Vector3,
    direction: Vector3,
    firedAtMs: Int64
  ) {
    self.shotID = shotID
    self.shooterID = shooterID
    self.targetID = targetID
    self.origin = origin
    self.direction = direction
    self.firedAtMs = firedAtMs
  }
}

/// Fixed rejection reasons from the shared-spatial-hit-registration requirements.
/// `invalidTarget`, `targetNotAlive`, and `shooterNotAlive` mirror the match.v2
/// fire-validation rules for claims outside the targetable set.
public enum ShotRejectionReason: String, Equatable, Sendable, Codable {
  case trackingLost
  case targetTooClose
  case targetOutOfRange
  case poseTooOld
  case shotTooLate
  case invalidTarget
  case targetNotAlive
  case shooterNotAlive
}

/// One Spatial Verdict (spatial-hit.v1 vocabulary) for one Frame-Aligned Shot Claim.
public enum SpatialVerdict: Equatable, Sendable, Codable {
  case hit(zone: HitZone, appliedDamage: Int)
  case miss
  case rejected(ShotRejectionReason)
}

/// A verdict paired with the claim it judged, the member it resolved to (if any),
/// and the tick that judged it.
public struct ShotVerdictRecord: Equatable, Sendable, Codable {
  public let shot: ShotClaim
  public let verdict: SpatialVerdict
  public let targetID: SimulationPlayerID?
  public let evaluatedAtTick: Int64
  public let rewindMilliseconds: Int64

  public init(
    shot: ShotClaim,
    verdict: SpatialVerdict,
    targetID: SimulationPlayerID? = nil,
    evaluatedAtTick: Int64,
    rewindMilliseconds: Int64
  ) {
    self.shot = shot
    self.verdict = verdict
    self.targetID = targetID
    self.evaluatedAtTick = evaluatedAtTick
    self.rewindMilliseconds = rewindMilliseconds
  }
}

/// Why a trigger press was refused by the shooter's own weapon or life state
/// before any spatial claim was evaluated. Kept separate from
/// `ShotRejectionReason` so the frozen spatial-hit.v1 vocabulary is untouched.
public enum FireRefusalReason: String, Equatable, Sendable, Codable {
  case spawnProtected
  case reloading
  case magazineEmpty
  case cooldownActive
}
