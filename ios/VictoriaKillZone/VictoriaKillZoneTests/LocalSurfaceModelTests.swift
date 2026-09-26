import Foundation
import XCTest

@testable import VictoriaKillZone

final class LocalSurfaceModelTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  private func plane(id: UUID = UUID(), alignment: LocalSurfaceAlignment = .horizontal,
    classification: LocalSurfaceClassification = .floor,
    center: TargetingVector3 = TargetingVector3(x: 0, y: 0, z: 0),
    normal: TargetingVector3 = TargetingVector3(x: 0, y: 1, z: 0),
    xAxis: TargetingVector3 = TargetingVector3(x: 1, y: 0, z: 0),
    extentX: Double = 4, extentZ: Double = 4, boundaryVertexCount: Int = 8,
    firstObservedAt: Date? = nil, lastUpdatedAt: Date? = nil, updateCount: Int = 0) -> LocalSurfacePlane {
    LocalSurfacePlane(id: id, alignment: alignment, classification: classification,
      center: center, normal: normal, xAxis: xAxis, extentX: extentX, extentZ: extentZ,
      boundaryVertexCount: boundaryVertexCount,
      firstObservedAt: firstObservedAt ?? base, lastUpdatedAt: lastUpdatedAt ?? base,
      updateCount: updateCount)
  }

  func testUpsertInsertsAndReplaces() {
    var model = LocalSurfaceModel()
    let id = UUID()
    XCTAssertNil(model.upsert(plane(id: id)))
    XCTAssertEqual(model.count, 1)
    XCTAssertNil(model.upsert(plane(id: id, extentX: 9)))
    XCTAssertEqual(model.count, 1)
    XCTAssertEqual(model.plane(id: id)?.extentX, 9)
    XCTAssertEqual(model.boundaryVertexTotal, 8)
  }

  func testUpdatePreservesFirstObservedAndBumpsUpdateCount() {
    var model = LocalSurfaceModel()
    let id = UUID()
    model.upsert(plane(id: id, firstObservedAt: base, lastUpdatedAt: base, updateCount: 0))
    model.update(plane(id: id, firstObservedAt: base.addingTimeInterval(5),
      lastUpdatedAt: base.addingTimeInterval(5), updateCount: 0))
    let stored = model.plane(id: id)
    XCTAssertEqual(stored?.firstObservedAt, base)
    XCTAssertEqual(stored?.lastUpdatedAt, base.addingTimeInterval(5))
    XCTAssertEqual(stored?.updateCount, 1)
    model.update(plane(id: id, lastUpdatedAt: base.addingTimeInterval(6)))
    XCTAssertEqual(model.plane(id: id)?.updateCount, 2)
  }

  func testUpdateOnMissingIDInserts() {
    var model = LocalSurfaceModel()
    let id = UUID()
    model.update(plane(id: id))
    XCTAssertEqual(model.count, 1)
    XCTAssertEqual(model.plane(id: id)?.updateCount, 0)
  }

  func testRemoveAndRemoveAll() {
    var model = LocalSurfaceModel()
    let a = UUID(); let b = UUID()
    model.upsert(plane(id: a))
    model.upsert(plane(id: b))
    model.remove(id: a)
    XCTAssertNil(model.plane(id: a))
    XCTAssertEqual(model.count, 1)
    model.removeAll()
    XCTAssertEqual(model.count, 0)
  }

  func testLRUEvictionAtCapacityReturnsEvictedID() {
    var model = LocalSurfaceModel(capacity: 2)
    let oldest = UUID()
    let middle = UUID()
    model.upsert(plane(id: oldest, lastUpdatedAt: base))
    model.upsert(plane(id: middle, lastUpdatedAt: base.addingTimeInterval(1)))
    let evicted = model.upsert(plane(id: UUID(), lastUpdatedAt: base.addingTimeInterval(2)))
    XCTAssertEqual(evicted, oldest)
    XCTAssertNil(model.plane(id: oldest))
    XCTAssertEqual(model.count, 2)
  }

  func testStaleIDsAndPruneStale() {
    var model = LocalSurfaceModel()
    let stale = UUID()
    model.upsert(plane(id: stale, lastUpdatedAt: base))
    model.upsert(plane(id: UUID(), lastUpdatedAt: base.addingTimeInterval(40)))
    let now = base.addingTimeInterval(31)
    XCTAssertEqual(model.staleIDs(at: now), [stale])
    XCTAssertEqual(model.pruneStale(at: now), 1)
    XCTAssertNil(model.plane(id: stale))
    XCTAssertEqual(model.pruneStale(at: now), 0)
  }

  func testNearestHitFloorFromAbove() {
    var model = LocalSurfaceModel()
    let id = UUID()
    model.upsert(plane(id: id, classification: .floor))
    let hit = model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(5))
    XCTAssertEqual(hit?.anchorID, id)
    XCTAssertEqual(hit?.distance ?? 0, 1.5, accuracy: 1e-9)
    XCTAssertEqual(hit?.normal, TargetingVector3(x: 0, y: 1, z: 0))
    XCTAssertEqual(hit?.classification, .floor)
    XCTAssertEqual(hit?.age ?? 0, 5, accuracy: 1e-9)
  }

  func testNearestHitWallAheadReturnsCloserPlane() {
    var model = LocalSurfaceModel()
    model.upsert(plane(id: UUID(), alignment: .vertical, classification: .wall,
      center: TargetingVector3(x: 0, y: 1.5, z: -3), normal: TargetingVector3(x: 0, y: 0, z: 1),
      xAxis: TargetingVector3(x: 1, y: 0, z: 0), extentX: 4, extentZ: 3))
    model.upsert(plane(id: UUID(), alignment: .vertical, classification: .wall,
      center: TargetingVector3(x: 0, y: 1.5, z: -5), normal: TargetingVector3(x: 0, y: 0, z: 1),
      xAxis: TargetingVector3(x: 1, y: 0, z: 0), extentX: 4, extentZ: 3))
    let hit = model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: 0, z: -1), maxDistance: 20,
      at: base.addingTimeInterval(5))
    XCTAssertEqual(hit?.distance ?? 0, 3, accuracy: 1e-9)
  }

  func testNearestHitOutsideExtentIsNil() {
    var model = LocalSurfaceModel()
    model.upsert(plane(extentX: 2, extentZ: 2))
    XCTAssertNil(model.nearestHit(origin: TargetingVector3(x: 5, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(5)))
  }

  func testNearestHitParallelRayIsNil() {
    var model = LocalSurfaceModel()
    model.upsert(plane())
    XCTAssertNil(model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 1, y: 0, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(5)))
  }

  func testNearestHitBeyondMaxDistanceIsNil() {
    var model = LocalSurfaceModel()
    model.upsert(plane())
    XCTAssertNil(model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 1,
      at: base.addingTimeInterval(5)))
  }

  func testNearestHitIgnoresUnsettledThenAcceptsSettled() {
    var model = LocalSurfaceModel()
    let id = UUID()
    model.upsert(plane(id: id, lastUpdatedAt: base.addingTimeInterval(5)))
    let queryAt = base.addingTimeInterval(5.5)
    XCTAssertNil(model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 10, at: queryAt))
    XCTAssertNotNil(model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(7)))
  }

  func testNearestHitIgnoresStalePlane() {
    var model = LocalSurfaceModel()
    model.upsert(plane(lastUpdatedAt: base))
    XCTAssertNil(model.nearestHit(origin: TargetingVector3(x: 0, y: 1.5, z: 0),
      direction: TargetingVector3(x: 0, y: -1, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(31)))
  }

  func testNearestHitBackFaceCounts() {
    var model = LocalSurfaceModel()
    let id = UUID()
    model.upsert(plane(id: id))
    let hit = model.nearestHit(origin: TargetingVector3(x: 0, y: -1.5, z: 0),
      direction: TargetingVector3(x: 0, y: 1, z: 0), maxDistance: 10,
      at: base.addingTimeInterval(5))
    XCTAssertEqual(hit?.anchorID, id)
    XCTAssertEqual(hit?.distance ?? 0, 1.5, accuracy: 1e-9)
  }
}
