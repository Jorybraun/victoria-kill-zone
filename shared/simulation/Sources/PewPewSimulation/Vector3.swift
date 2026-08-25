import Foundation

/// Minimal metre-based vector for the Shared Arena Frame. Foundation-only so the
/// simulation core stays platform-neutral and deterministic.
public struct Vector3: Equatable, Hashable, Sendable, Codable {
  public var x: Double
  public var y: Double
  public var z: Double

  public init(_ x: Double, _ y: Double, _ z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }

  public static let zero = Vector3(0, 0, 0)

  public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
    Vector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
  }

  public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
    Vector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
  }

  public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
    Vector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
  }

  public func dot(_ other: Vector3) -> Double {
    x * other.x + y * other.y + z * other.z
  }

  public var lengthSquared: Double {
    dot(self)
  }

  public var length: Double {
    lengthSquared.squareRoot()
  }

  public func distance(to other: Vector3) -> Double {
    (other - self).length
  }

  /// Returns nil for a zero-length vector instead of dividing by zero.
  public var normalized: Vector3? {
    let magnitude = length
    guard magnitude > 0 else { return nil }
    return Vector3(x / magnitude, y / magnitude, z / magnitude)
  }
}
