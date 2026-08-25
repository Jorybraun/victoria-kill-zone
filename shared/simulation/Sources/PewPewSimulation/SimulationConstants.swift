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
  public static let hitDamage = 34
}
