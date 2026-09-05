import Foundation

/// Frozen baselines from docs/features/shared-spatial-hit-registration/requirements.md
/// and the phase0.v1 shared constant catalog. Changing any of these requires an
/// accepted contract update before implementation.
public enum SimulationConstants {
  public static let rewindCapMilliseconds: Int64 = 250
  public static let maxPoseAgeMilliseconds: Int64 = 100
  public static let proxyRadiusMeters: Double = 0.35
  public static let minimumSeparationMeters: Double = 3
  public static let maximumRangeMeters: Double = 15

  public static let playerCapacityMin = 2
  public static let playerCapacityMax = 4

  public static let initialHealth = 100
}

/// Sidearm (`sidearm-mk1`) weapon and life-cycle rules. Values mirror
/// `convex/domain/config.ts` and the KIL-39 registry draft so the realtime
/// authority and the durable ledger never disagree on a number.
public enum SidearmRules {
  public static let magazineSize = 8
  public static let fireCooldownMilliseconds: Int64 = 150
  public static let reloadDurationMilliseconds: Int64 = 1250
  public static let respawnDelayMilliseconds: Int64 = 5000
  public static let spawnProtectionMilliseconds: Int64 = 2000

  public static let headDamage = 75
  public static let torsoDamage = 34
  public static let limbsDamage = 20
}
