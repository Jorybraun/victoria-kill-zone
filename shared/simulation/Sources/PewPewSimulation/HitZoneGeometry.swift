import Foundation

/// Damage zone of a Phone Target Proxy hit. Zones partition the *interior* of
/// the frozen 0.35 m proxy sphere (§5.1); they never change whether a shot hits,
/// only how much it hurts. Damage values mirror `convex/domain/config.ts`.
public enum HitZone: String, Equatable, Sendable, Codable, CaseIterable {
  case head
  case torso
  case limbs

  public var damage: Int {
    switch self {
    case .head: return SidearmRules.headDamage
    case .torso: return SidearmRules.torsoDamage
    case .limbs: return SidearmRules.limbsDamage
    }
  }
}

/// One forward intersection of a shot ray with one player's proxy.
public struct ProxyIntersection: Equatable, Sendable {
  /// Distance along the unit direction from the origin to where the ray enters
  /// the 0.35 m envelope. Used to pick the nearest candidate (§5.0).
  public let entryDistance: Double
  public let zone: HitZone
}

/// Zoned Phone Target Proxy geometry in the Shared Arena Frame (+Y up).
///
/// Envelope: the frozen sphere — centre at the rewound phone origin, radius
/// exactly 0.35 m, forward ray only, tangent counts as a hit (§5.1). Inside it:
///
/// - `head`  — sphere, centre 0.21 m above the phone, radius 0.14 m (top of the envelope)
/// - `torso` — vertical capsule from 0.17 m below the phone to the phone, radius 0.17 m
/// - `limbs` — every other point of the envelope (shoulders, arms, lower periphery)
///
/// Where head and torso overlap the ray's first entry wins; an exact tie is `head`.
/// All arithmetic is plain `Double`, so the same claim always classifies the same way.
public enum ProxyGeometry {
  public static let headCenterOffset = Vector3(0, 0.21, 0)
  public static let headRadiusMeters: Double = 0.14
  public static let torsoSegmentBottomOffset = Vector3(0, -0.17, 0)
  public static let torsoSegmentTopOffset = Vector3.zero
  public static let torsoRadiusMeters: Double = 0.17

  private static let parallelEpsilon = 1e-12

  /// Frozen §5.1 hit predicate plus zone classification. `direction` must be unit length.
  public static func intersect(
    origin: Vector3,
    direction: Vector3,
    proxyCenter: Vector3
  ) -> ProxyIntersection? {
    let toCenter = proxyCenter - origin
    let projection = toCenter.dot(direction)
    guard projection >= 0 else { return nil }
    let radiusSquared = SimulationConstants.proxyRadiusMeters * SimulationConstants.proxyRadiusMeters
    let closestDistanceSquared = toCenter.lengthSquared - projection * projection
    guard closestDistanceSquared <= radiusSquared else { return nil }
    let entryDistance = max(projection - (radiusSquared - closestDistanceSquared).squareRoot(), 0)

    let headEntry = sphereEntryDistance(
      origin: origin, direction: direction,
      center: proxyCenter + headCenterOffset, radius: headRadiusMeters)
    let torsoEntry = capsuleEntryDistance(
      origin: origin, direction: direction,
      segmentStart: proxyCenter + torsoSegmentBottomOffset,
      segmentEnd: proxyCenter + torsoSegmentTopOffset,
      radius: torsoRadiusMeters)

    let zone: HitZone
    switch (headEntry, torsoEntry) {
    case (nil, nil): zone = .limbs
    case (.some, nil): zone = .head
    case (nil, .some): zone = .torso
    case (.some(let head), .some(let torso)): zone = head <= torso ? .head : .torso
    }
    return ProxyIntersection(entryDistance: entryDistance, zone: zone)
  }

  /// Forward ray vs sphere. Returns the entry distance, or 0 when the origin is
  /// inside, or nil when the sphere is missed or entirely behind the origin.
  static func sphereEntryDistance(
    origin: Vector3,
    direction: Vector3,
    center: Vector3,
    radius: Double
  ) -> Double? {
    let toCenter = center - origin
    let projection = toCenter.dot(direction)
    let radiusSquared = radius * radius
    let closestDistanceSquared = toCenter.lengthSquared - projection * projection
    guard closestDistanceSquared <= radiusSquared else { return nil }
    let halfChord = (radiusSquared - closestDistanceSquared).squareRoot()
    guard projection + halfChord >= 0 else { return nil }
    return max(projection - halfChord, 0)
  }

  /// Forward ray vs capsule (segment swept by a sphere). The capsule is the union
  /// of its two end spheres and the finite cylinder between them, so the entry
  /// distance is the smallest entry into any of the three parts.
  static func capsuleEntryDistance(
    origin: Vector3,
    direction: Vector3,
    segmentStart: Vector3,
    segmentEnd: Vector3,
    radius: Double
  ) -> Double? {
    var best: Double?
    func consider(_ candidate: Double?) {
      guard let candidate else { return }
      if let current = best, current <= candidate { return }
      best = candidate
    }

    consider(sphereEntryDistance(origin: origin, direction: direction, center: segmentStart, radius: radius))
    consider(sphereEntryDistance(origin: origin, direction: direction, center: segmentEnd, radius: radius))

    let axis = segmentEnd - segmentStart
    let axisLengthSquared = axis.lengthSquared
    guard axisLengthSquared > 0 else { return best }

    // Ericson, Real-Time Collision Detection §5.3.7, specialised to an infinite
    // cylinder and then clipped to the segment's axial extent.
    let m = origin - segmentStart
    let md = m.dot(axis)
    let nd = direction.dot(axis)
    let a = axisLengthSquared * direction.lengthSquared - nd * nd
    let k = m.lengthSquared - radius * radius
    let c = axisLengthSquared * k - md * md
    let b = axisLengthSquared * m.dot(direction) - nd * md
    guard abs(a) > parallelEpsilon else { return best }
    let discriminant = b * b - a * c
    guard discriminant >= 0 else { return best }
    let root = discriminant.squareRoot()
    let t0 = (-b - root) / a
    let t1 = (-b + root) / a
    let entry: Double
    if t0 >= 0 {
      entry = t0
    } else if t1 >= 0 {
      entry = 0
    } else {
      return best
    }
    let axial = md + entry * nd
    if axial >= 0, axial <= axisLengthSquared {
      consider(entry)
    }
    return best
  }
}
