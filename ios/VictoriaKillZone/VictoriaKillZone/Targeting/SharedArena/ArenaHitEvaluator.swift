import Foundation

// MARK: - Deterministic shared-arena prototype (KIL-19)

enum ArenaPrototypeError: Error, Equatable, Sendable {
  case nonFinite
  case nonInvertibleTransform
  case nonUnitScale
  case nonOrthonormalTransform
  case invalidDirection
  case nonIncreasingSequence
  case nonIncreasingTimestamp
  case trackingLost
  case missingHistory
  case poseTooOld
  case shotTooLate
}

struct ArenaVector3: Equatable, Sendable {
  let x: Double
  let y: Double
  let z: Double

  static let zero = ArenaVector3(x: 0, y: 0, z: 0)

  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
  var squaredLength: Double { dot(self) }
  var length: Double { sqrt(squaredLength) }

  func dot(_ other: ArenaVector3) -> Double {
    x * other.x + y * other.y + z * other.z
  }

  func cross(_ other: ArenaVector3) -> ArenaVector3 {
    ArenaVector3(
      x: y * other.z - z * other.y,
      y: z * other.x - x * other.z,
      z: x * other.y - y * other.x
    )
  }

  func normalized() throws -> ArenaVector3 {
    guard isFinite else { throw ArenaPrototypeError.nonFinite }
    let magnitude = length
    guard magnitude.isFinite, magnitude > ArenaRigidTransform.tolerance else {
      throw ArenaPrototypeError.invalidDirection
    }
    return self / magnitude
  }

  static func + (lhs: ArenaVector3, rhs: ArenaVector3) -> ArenaVector3 {
    ArenaVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
  }

  static func - (lhs: ArenaVector3, rhs: ArenaVector3) -> ArenaVector3 {
    ArenaVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
  }

  static func * (lhs: ArenaVector3, rhs: Double) -> ArenaVector3 {
    ArenaVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
  }

  static func / (lhs: ArenaVector3, rhs: Double) -> ArenaVector3 {
    ArenaVector3(x: lhs.x / rhs, y: lhs.y / rhs, z: lhs.z / rhs)
  }
}

/// A right-handed, metre-scaled rigid transform stored in the same column-major
/// order as ARKit's `simd_float4x4`. Points use homogeneous `w = 1`, while
/// directions use `w = 0` and therefore never receive translation.
struct ArenaRigidTransform: Equatable, Sendable {
  static let tolerance = 1e-6
  static let identityStorage: [Double] = [
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  ]

  let columnMajor: [Double]

  init(columnMajor: [Double]) throws {
    guard columnMajor.count == 16, columnMajor.allSatisfy(\.isFinite) else {
      throw ArenaPrototypeError.nonFinite
    }

    let xAxis = ArenaVector3(x: columnMajor[0], y: columnMajor[1], z: columnMajor[2])
    let yAxis = ArenaVector3(x: columnMajor[4], y: columnMajor[5], z: columnMajor[6])
    let zAxis = ArenaVector3(x: columnMajor[8], y: columnMajor[9], z: columnMajor[10])
    let determinant = xAxis.dot(yAxis.cross(zAxis))
    guard abs(determinant) > Self.tolerance else {
      throw ArenaPrototypeError.nonInvertibleTransform
    }
    guard abs(xAxis.length - 1) <= Self.tolerance,
      abs(yAxis.length - 1) <= Self.tolerance,
      abs(zAxis.length - 1) <= Self.tolerance
    else {
      throw ArenaPrototypeError.nonUnitScale
    }
    guard abs(xAxis.dot(yAxis)) <= Self.tolerance,
      abs(xAxis.dot(zAxis)) <= Self.tolerance,
      abs(yAxis.dot(zAxis)) <= Self.tolerance,
      abs(determinant - 1) <= Self.tolerance,
      abs(columnMajor[3]) <= Self.tolerance,
      abs(columnMajor[7]) <= Self.tolerance,
      abs(columnMajor[11]) <= Self.tolerance,
      abs(columnMajor[15] - 1) <= Self.tolerance
    else {
      throw ArenaPrototypeError.nonOrthonormalTransform
    }
    self.columnMajor = columnMajor
  }

  static func translation(x: Double, y: Double, z: Double) throws -> ArenaRigidTransform {
    var storage = identityStorage
    storage[12] = x
    storage[13] = y
    storage[14] = z
    return try ArenaRigidTransform(columnMajor: storage)
  }

  var translation: ArenaVector3 {
    ArenaVector3(x: columnMajor[12], y: columnMajor[13], z: columnMajor[14])
  }

  func applying(toPoint point: ArenaVector3) -> ArenaVector3 {
    applying(toDirection: point) + translation
  }

  func applying(toDirection direction: ArenaVector3) -> ArenaVector3 {
    ArenaVector3(
      x: columnMajor[0] * direction.x + columnMajor[4] * direction.y + columnMajor[8] * direction.z,
      y: columnMajor[1] * direction.x + columnMajor[5] * direction.y + columnMajor[9] * direction.z,
      z: columnMajor[2] * direction.x + columnMajor[6] * direction.y + columnMajor[10] * direction.z
    )
  }

  func inverse() throws -> ArenaRigidTransform {
    let inverseRotation: [Double] = [
      columnMajor[0], columnMajor[4], columnMajor[8], 0,
      columnMajor[1], columnMajor[5], columnMajor[9], 0,
      columnMajor[2], columnMajor[6], columnMajor[10], 0,
      0, 0, 0, 1,
    ]
    let rotationOnly = try ArenaRigidTransform(columnMajor: inverseRotation)
    let inverseTranslation = rotationOnly.applying(toDirection: translation) * -1
    var storage = inverseRotation
    storage[12] = inverseTranslation.x
    storage[13] = inverseTranslation.y
    storage[14] = inverseTranslation.z
    return try ArenaRigidTransform(columnMajor: storage)
  }
}

enum ArenaTrackingQuality: Equatable, Sendable {
  case normal
  case lost
}

struct ArenaPoseSample: Equatable, Sendable {
  let sequence: Int64
  let timestampMs: Int64
  let tracking: ArenaTrackingQuality
  let arenaFromPhone: ArenaRigidTransform
}

struct ArenaPoseHistory: Equatable, Sendable {
  static let maximumPoseAgeMs: Int64 = 100

  private let capacity: Int
  private var samples: [ArenaPoseSample] = []
  private var lastSequence: Int64?
  private var lastTimestampMs: Int64?

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  var count: Int { samples.count }

  mutating func append(_ sample: ArenaPoseSample) throws {
    if let lastSequence, sample.sequence <= lastSequence {
      throw ArenaPrototypeError.nonIncreasingSequence
    }
    if let lastTimestampMs, sample.timestampMs <= lastTimestampMs {
      throw ArenaPrototypeError.nonIncreasingTimestamp
    }

    lastSequence = sample.sequence
    lastTimestampMs = sample.timestampMs

    guard sample.tracking == .normal else {
      samples.removeAll(keepingCapacity: true)
      throw ArenaPrototypeError.trackingLost
    }

    samples.append(sample)
    if samples.count > capacity {
      samples.removeFirst(samples.count - capacity)
    }
  }

  func resolvedOrigin(at timestampMs: Int64) throws -> ArenaVector3 {
    guard let first = samples.first, let last = samples.last else {
      throw ArenaPrototypeError.missingHistory
    }
    guard timestampMs >= first.timestampMs else {
      throw ArenaPrototypeError.missingHistory
    }

    if let exact = samples.first(where: { $0.timestampMs == timestampMs }) {
      return exact.arenaFromPhone.translation
    }

    if timestampMs > last.timestampMs {
      let age = timestampMs - last.timestampMs
      guard age <= Self.maximumPoseAgeMs else {
        throw ArenaPrototypeError.poseTooOld
      }
      return last.arenaFromPhone.translation
    }

    guard let laterIndex = samples.firstIndex(where: { $0.timestampMs > timestampMs }),
      laterIndex > samples.startIndex
    else {
      throw ArenaPrototypeError.missingHistory
    }
    let earlier = samples[samples.index(before: laterIndex)]
    let later = samples[laterIndex]
    let bracketWidth = later.timestampMs - earlier.timestampMs
    let earlierAge = timestampMs - earlier.timestampMs
    guard bracketWidth <= Self.maximumPoseAgeMs, earlierAge <= Self.maximumPoseAgeMs else {
      throw ArenaPrototypeError.poseTooOld
    }

    let fraction = Double(earlierAge) / Double(bracketWidth)
    let start = earlier.arenaFromPhone.translation
    let end = later.arenaFromPhone.translation
    return start + (end - start) * fraction
  }
}

struct ArenaShotRay: Equatable, Sendable {
  let origin: ArenaVector3
  let direction: ArenaVector3
  let firedAtMs: Int64

  init(origin: ArenaVector3, direction: ArenaVector3, firedAtMs: Int64) throws {
    guard origin.isFinite else { throw ArenaPrototypeError.nonFinite }
    self.origin = origin
    self.direction = try direction.normalized()
    self.firedAtMs = firedAtMs
  }
}

struct ArenaCandidate: Equatable, Sendable {
  let id: String
  let poseHistory: ArenaPoseHistory
}

enum ArenaPrototypeVerdict: Equatable, Sendable {
  case hit(String)
  case miss
  case rejected(ArenaPrototypeError)
}

enum ArenaHitEvaluator {
  static let proxyRadiusMeters = 0.35
  static let minimumLaneMeters = 3.0
  static let maximumLaneMeters = 15.0
  static let maximumRewindMs: Int64 = 250

  static func evaluate(
    shot: ArenaShotRay,
    authorityNowMs: Int64,
    candidates: [ArenaCandidate]
  ) -> ArenaPrototypeVerdict {
    let (rewind, overflow) = authorityNowMs.subtractingReportingOverflow(shot.firedAtMs)
    guard !overflow, rewind >= 0, rewind <= maximumRewindMs else {
      return .rejected(.shotTooLate)
    }

    var nearest: (id: String, entryDistance: Double)?
    for candidate in candidates {
      guard let centre = try? candidate.poseHistory.resolvedOrigin(at: shot.firedAtMs) else {
        continue
      }
      let fromShooter = centre - shot.origin
      let laneDistance = fromShooter.length
      guard laneDistance >= minimumLaneMeters, laneDistance <= maximumLaneMeters else {
        continue
      }

      let projectedDistance = fromShooter.dot(shot.direction)
      guard projectedDistance >= 0 else { continue }
      let perpendicularSquared = max(0, fromShooter.squaredLength - projectedDistance * projectedDistance)
      let radiusSquared = proxyRadiusMeters * proxyRadiusMeters
      guard perpendicularSquared <= radiusSquared + ArenaRigidTransform.tolerance else {
        continue
      }
      let halfChord = sqrt(max(0, radiusSquared - perpendicularSquared))
      let entryDistance = max(0, projectedDistance - halfChord)

      if let current = nearest {
        let isCloser = entryDistance < current.entryDistance - ArenaRigidTransform.tolerance
        let isDeterministicTie = abs(entryDistance - current.entryDistance) <= ArenaRigidTransform.tolerance
          && candidate.id < current.id
        if isCloser || isDeterministicTie {
          nearest = (candidate.id, entryDistance)
        }
      } else {
        nearest = (candidate.id, entryDistance)
      }
    }

    return nearest.map { .hit($0.id) } ?? .miss
  }
}
