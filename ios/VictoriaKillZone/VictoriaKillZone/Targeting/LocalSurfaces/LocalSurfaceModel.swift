import Foundation

enum LocalSurfaceAlignment: String, Codable, Equatable, Sendable {
  case horizontal, vertical
}

enum LocalSurfaceClassification: String, Codable, Equatable, Sendable {
  case none, wall, floor, ceiling, table, seat, window, door, unknown
}

struct LocalSurfacePlane: Equatable, Sendable {
  let id: UUID
  var alignment: LocalSurfaceAlignment
  var classification: LocalSurfaceClassification
  var center: TargetingVector3
  var normal: TargetingVector3
  var xAxis: TargetingVector3
  var extentX: Double
  var extentZ: Double
  var boundaryVertexCount: Int
  let firstObservedAt: Date
  var lastUpdatedAt: Date
  /// When the geometry last meaningfully changed; the settle gate keys off
  /// this so unchanged ARKit refreshes do not reset settle.
  var stableSince: Date
  var updateCount: Int

  init(id: UUID, alignment: LocalSurfaceAlignment, classification: LocalSurfaceClassification,
    center: TargetingVector3, normal: TargetingVector3, xAxis: TargetingVector3,
    extentX: Double, extentZ: Double, boundaryVertexCount: Int,
    firstObservedAt: Date, lastUpdatedAt: Date, stableSince: Date? = nil, updateCount: Int) {
    self.id = id
    self.alignment = alignment
    self.classification = classification
    self.center = center
    self.normal = normal
    self.xAxis = xAxis
    self.extentX = extentX
    self.extentZ = extentZ
    self.boundaryVertexCount = boundaryVertexCount
    self.firstObservedAt = firstObservedAt
    self.lastUpdatedAt = lastUpdatedAt
    self.stableSince = stableSince ?? firstObservedAt
    self.updateCount = updateCount
  }
}

struct LocalSurfaceHit: Equatable, Sendable {
  let anchorID: UUID
  let distance: Double
  let point: TargetingVector3
  let normal: TargetingVector3
  let alignment: LocalSurfaceAlignment
  let classification: LocalSurfaceClassification
  let age: TimeInterval
}

extension TargetingVector3 {
  fileprivate func cross(_ other: TargetingVector3) -> TargetingVector3 {
    TargetingVector3(
      x: y * other.z - z * other.y,
      y: z * other.x - x * other.z,
      z: x * other.y - y * other.x)
  }

  fileprivate var length: Double { dot(self).squareRoot() }
}

struct LocalSurfaceModel: Equatable, Sendable {
  static let defaultCapacity = 64
  static let defaultSettleInterval: TimeInterval = 1.5
  static let defaultStaleAfter: TimeInterval = 30
  static let settleCenterTolerance = 0.03
  static let settleExtentTolerance = 0.05
  static let settleNormalCosine = 0.9986

  let capacity: Int
  let settleInterval: TimeInterval
  let staleAfter: TimeInterval
  private(set) var planes: [UUID: LocalSurfacePlane] = [:]

  init(capacity: Int = defaultCapacity, settleInterval: TimeInterval = defaultSettleInterval,
    staleAfter: TimeInterval = defaultStaleAfter) {
    self.capacity = capacity
    self.settleInterval = settleInterval
    self.staleAfter = staleAfter
  }

  var count: Int { planes.count }
  var boundaryVertexTotal: Int { planes.values.reduce(0) { $0 + $1.boundaryVertexCount } }

  func plane(id: UUID) -> LocalSurfacePlane? { planes[id] }

  @discardableResult
  mutating func upsert(_ plane: LocalSurfacePlane) -> UUID? {
    var evicted: UUID?
    if planes[plane.id] == nil, planes.count >= capacity,
      let oldest = planes.values.min(by: Self.lruOrder) {
      planes.removeValue(forKey: oldest.id)
      evicted = oldest.id
    }
    var stored = plane
    stored.stableSince = plane.lastUpdatedAt
    planes[plane.id] = stored
    return evicted
  }

  mutating func update(_ plane: LocalSurfacePlane) {
    guard let existing = planes[plane.id] else {
      upsert(plane)
      return
    }
    planes[plane.id] = LocalSurfacePlane(
      id: plane.id,
      alignment: plane.alignment,
      classification: plane.classification,
      center: plane.center,
      normal: plane.normal,
      xAxis: plane.xAxis,
      extentX: plane.extentX,
      extentZ: plane.extentZ,
      boundaryVertexCount: plane.boundaryVertexCount,
      firstObservedAt: existing.firstObservedAt,
      lastUpdatedAt: plane.lastUpdatedAt,
      stableSince: Self.geometryChanged(plane, vs: existing)
        ? plane.lastUpdatedAt : existing.stableSince,
      updateCount: existing.updateCount + 1)
  }

  mutating func remove(id: UUID) { planes.removeValue(forKey: id) }

  mutating func removeAll() { planes.removeAll() }

  func staleIDs(at now: Date) -> [UUID] {
    planes.values.filter { now.timeIntervalSince($0.lastUpdatedAt) > staleAfter }
      .map(\.id)
      .sorted { $0.uuidString < $1.uuidString }
  }

  @discardableResult
  mutating func pruneStale(at now: Date) -> Int {
    let stale = staleIDs(at: now)
    for id in stale { planes.removeValue(forKey: id) }
    return stale.count
  }

  func nearestHit(origin: TargetingVector3, direction: TargetingVector3, maxDistance: Double,
    at now: Date) -> LocalSurfaceHit? {
    let length = direction.length
    guard length > 0 else { return nil }
    let unit = direction * (1 / length)
    var best: (plane: LocalSurfacePlane, t: Double)?
    for plane in planes.values {
      let age = now.timeIntervalSince(plane.lastUpdatedAt)
      guard now.timeIntervalSince(plane.stableSince) >= settleInterval,
        age <= staleAfter else { continue }
      let denominator = plane.normal.dot(unit)
      guard abs(denominator) > 1e-9 else { continue }
      let t = (plane.center - origin).dot(plane.normal) / denominator
      guard t > 1e-4, t <= maxDistance else { continue }
      let point = origin + unit * t
      let offset = point - plane.center
      let zAxis = plane.normal.cross(plane.xAxis)
      guard abs(offset.dot(plane.xAxis)) <= plane.extentX / 2,
        abs(offset.dot(zAxis)) <= plane.extentZ / 2 else { continue }
      if let current = best {
        if t < current.t || (t == current.t && plane.id.uuidString < current.plane.id.uuidString) {
          best = (plane, t)
        }
      } else {
        best = (plane, t)
      }
    }
    guard let (plane, t) = best else { return nil }
    return LocalSurfaceHit(
      anchorID: plane.id,
      distance: t,
      point: origin + unit * t,
      normal: plane.normal,
      alignment: plane.alignment,
      classification: plane.classification,
      age: now.timeIntervalSince(plane.lastUpdatedAt))
  }

  private static func geometryChanged(_ plane: LocalSurfacePlane,
    vs existing: LocalSurfacePlane) -> Bool {
    let delta = plane.center - existing.center
    return delta.dot(delta).squareRoot() > settleCenterTolerance
      || abs(plane.extentX - existing.extentX) > settleExtentTolerance
      || abs(plane.extentZ - existing.extentZ) > settleExtentTolerance
      || plane.normal.dot(existing.normal) < settleNormalCosine
      || plane.alignment != existing.alignment
      || plane.classification != existing.classification
  }

  private static func lruOrder(_ lhs: LocalSurfacePlane, _ rhs: LocalSurfacePlane) -> Bool {
    if lhs.lastUpdatedAt != rhs.lastUpdatedAt { return lhs.lastUpdatedAt < rhs.lastUpdatedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
