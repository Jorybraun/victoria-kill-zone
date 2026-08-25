import Foundation

/// Projectile worldline scaffolding: spawn parameters fully determine position
/// as a pure function of match time. Projectiles are never position-streamed.
/// No gameplay logic (collision, damage, expiry) lives here yet — Phase 2 owns that.
public struct ProjectileWorldline: Equatable, Sendable, Codable {
  public let projectileID: String
  public let shooterID: SimulationPlayerID
  public let spawnedAtMs: Int64
  public let origin: Vector3
  public let velocityMetersPerSecond: Vector3
  public let accelerationMetersPerSecondSquared: Vector3

  public init(
    projectileID: String,
    shooterID: SimulationPlayerID,
    spawnedAtMs: Int64,
    origin: Vector3,
    velocityMetersPerSecond: Vector3,
    accelerationMetersPerSecondSquared: Vector3 = .zero
  ) {
    self.projectileID = projectileID
    self.shooterID = shooterID
    self.spawnedAtMs = spawnedAtMs
    self.origin = origin
    self.velocityMetersPerSecond = velocityMetersPerSecond
    self.accelerationMetersPerSecondSquared = accelerationMetersPerSecondSquared
  }

  /// Position at match time `timestampMs`, or nil before the spawn instant.
  /// origin + v·t + ½·a·t² with t in seconds.
  public func position(atMs timestampMs: Int64) -> Vector3? {
    guard timestampMs >= spawnedAtMs else { return nil }
    let t = Double(timestampMs - spawnedAtMs) / 1000
    return origin
      + velocityMetersPerSecond * t
      + accelerationMetersPerSecondSquared * (0.5 * t * t)
  }
}
