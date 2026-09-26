import Foundation
import XCTest

@testable import VictoriaKillZone

final class LocalSurfaceTelemetryTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  private func plane(alignment: LocalSurfaceAlignment = .horizontal,
    classification: LocalSurfaceClassification = .floor) -> LocalSurfacePlane {
    LocalSurfacePlane(id: UUID(), alignment: alignment, classification: classification,
      center: TargetingVector3(x: 0, y: 0, z: 0), normal: TargetingVector3(x: 0, y: 1, z: 0),
      xAxis: TargetingVector3(x: 1, y: 0, z: 0), extentX: 4, extentZ: 4,
      boundaryVertexCount: 6, firstObservedAt: base, lastUpdatedAt: base, updateCount: 0)
  }

  func testOneSamplePerCompletedSecond() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    for index in 0..<12 {
      telemetry.recordFrame(at: base.addingTimeInterval(Double(index) / 60),
        planeCount: 3, boundaryVertexTotal: 30, thermalState: "nominal")
    }
    for index in 0..<7 {
      telemetry.recordFrame(at: base.addingTimeInterval(1 + Double(index) / 60),
        planeCount: 4, boundaryVertexTotal: 40, thermalState: "nominal")
    }
    XCTAssertEqual(telemetry.samples.count, 1)
    XCTAssertEqual(telemetry.samples[0].frames, 12)
    XCTAssertEqual(telemetry.samples[0].elapsedMs, 1_000)
    telemetry.recordFrame(at: base.addingTimeInterval(2),
      planeCount: 4, boundaryVertexTotal: 40, thermalState: "nominal")
    XCTAssertEqual(telemetry.samples.count, 2)
    XCTAssertEqual(telemetry.samples[0].planeCount, 3)
    XCTAssertEqual(telemetry.samples[0].boundaryVertexTotal, 30)
    XCTAssertEqual(telemetry.samples[1].frames, 7)
    XCTAssertEqual(telemetry.samples[1].elapsedMs, 2_000)
  }

  func testPreStartFrameIsIgnored() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordFrame(at: base.addingTimeInterval(-0.5), planeCount: 9,
      boundaryVertexTotal: 90, thermalState: "critical")
    telemetry.recordFrame(at: base, planeCount: 1, boundaryVertexTotal: 6, thermalState: "nominal")
    telemetry.recordFrame(at: base.addingTimeInterval(0.5), planeCount: 1,
      boundaryVertexTotal: 6, thermalState: "nominal")
    telemetry.recordFrame(at: base.addingTimeInterval(1), planeCount: 1,
      boundaryVertexTotal: 6, thermalState: "nominal")
    XCTAssertEqual(telemetry.samples.count, 1)
    XCTAssertEqual(telemetry.samples[0].frames, 2)
    XCTAssertEqual(telemetry.samples[0].planeCount, 1)
    XCTAssertEqual(telemetry.samples[0].thermalState, "nominal")
  }

  func testRolloverRowCarriesPreRolloverPlaneCount() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordFrame(at: base.addingTimeInterval(0.9), planeCount: 1,
      boundaryVertexTotal: 6, thermalState: "nominal")
    telemetry.recordFrame(at: base.addingTimeInterval(1), planeCount: 2,
      boundaryVertexTotal: 12, thermalState: "fair")
    XCTAssertEqual(telemetry.samples.count, 1)
    XCTAssertEqual(telemetry.samples[0].elapsedMs, 1_000)
    XCTAssertEqual(telemetry.samples[0].planeCount, 1)
    XCTAssertEqual(telemetry.samples[0].boundaryVertexTotal, 6)
    XCTAssertEqual(telemetry.samples[0].thermalState, "nominal")
  }

  func testSixHourGapEmitsSingleBoundaryRow() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordFrame(at: base, planeCount: 1, boundaryVertexTotal: 6, thermalState: "nominal")
    telemetry.recordFrame(at: base.addingTimeInterval(21_600), planeCount: 2,
      boundaryVertexTotal: 12, thermalState: "nominal")
    XCTAssertEqual(telemetry.samples.count, 1)
    XCTAssertEqual(telemetry.samples[0].frames, 1)
    telemetry.recordFrame(at: base.addingTimeInterval(21_600.5), planeCount: 2,
      boundaryVertexTotal: 12, thermalState: "nominal")
    telemetry.recordFrame(at: base.addingTimeInterval(21_601), planeCount: 3,
      boundaryVertexTotal: 18, thermalState: "nominal")
    XCTAssertEqual(telemetry.samples.count, 2)
    XCTAssertEqual(telemetry.samples[1].frames, 2)
    XCTAssertEqual(telemetry.samples[1].elapsedMs, 21_601_000)
  }

  func testPlaneCountersAndAddRemoveEvents() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    let p = plane()
    telemetry.recordPlaneAdded(p, at: base.addingTimeInterval(0.5))
    telemetry.recordPlaneUpdated(p, at: base.addingTimeInterval(0.6))
    telemetry.recordPlaneRemoved(id: p.id, at: base.addingTimeInterval(0.7))
    XCTAssertEqual(telemetry.planeAdds, 1)
    XCTAssertEqual(telemetry.planeUpdates, 1)
    XCTAssertEqual(telemetry.planeRemoves, 1)
    XCTAssertEqual(telemetry.events.count, 2)
    XCTAssertEqual(telemetry.events[0].kind, "surface")
    XCTAssertTrue(telemetry.events[0].detail.contains("align=horizontal"))
    XCTAssertTrue(telemetry.events[0].detail.contains("class=floor"))
    XCTAssertTrue(telemetry.events[0].detail.contains("verts=6"))
    XCTAssertEqual(telemetry.events[1].detail, "remove")
    XCTAssertEqual(telemetry.events[0].elapsedMs, 500)
  }

  func testTimeToFirstFloorAndWallSetOnce() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordPlaneAdded(plane(classification: .floor), at: base.addingTimeInterval(1))
    telemetry.recordPlaneAdded(plane(alignment: .vertical, classification: .wall),
      at: base.addingTimeInterval(2))
    telemetry.recordPlaneAdded(plane(classification: .floor), at: base.addingTimeInterval(3))
    telemetry.recordPlaneAdded(plane(alignment: .vertical, classification: .wall),
      at: base.addingTimeInterval(4))
    XCTAssertEqual(telemetry.timeToFirstFloorMs, 1_000)
    XCTAssertEqual(telemetry.timeToFirstWallMs, 2_000)
  }

  func testUnclassifiedAlignmentsCountAsFirstFloorAndWall() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordPlaneAdded(plane(classification: .none), at: base.addingTimeInterval(1))
    telemetry.recordPlaneAdded(plane(alignment: .vertical, classification: .unknown),
      at: base.addingTimeInterval(2))
    XCTAssertEqual(telemetry.timeToFirstFloorMs, 1_000)
    XCTAssertEqual(telemetry.timeToFirstWallMs, 2_000)
  }

  func testCSVHeaderAndRows() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    for index in 0..<30 {
      telemetry.recordFrame(at: base.addingTimeInterval(Double(index) / 60),
        planeCount: 2, boundaryVertexTotal: 12, thermalState: "nominal")
    }
    telemetry.recordFrame(at: base.addingTimeInterval(1),
      planeCount: 2, boundaryVertexTotal: 12, thermalState: "nominal")
    let rows = telemetry.csv().split(separator: "\n")
    XCTAssertEqual(rows.first.map(String.init), LocalSurfaceTelemetry.csvHeader)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(String(rows[1]), "1000,30,30.0,2,12,0,0,0,nominal")
  }

  func testEventsBoundedTo256() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    for index in 0..<300 {
      telemetry.recordEvent("surface", "event \(index)", at: base)
    }
    XCTAssertEqual(telemetry.events.count, 256)
    XCTAssertEqual(telemetry.events.first?.detail, "event 44")
    XCTAssertEqual(telemetry.events.last?.detail, "event 299")
  }

  func testNoUUIDStringsInEventDetails() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    let p = plane()
    telemetry.recordPlaneAdded(p, at: base)
    telemetry.recordPlaneUpdated(p, at: base)
    telemetry.recordPlaneRemoved(id: p.id, at: base)
    telemetry.recordCapability(DeviceCapabilityReport(deviceModel: "iPhone16,1",
      systemVersion: "18.1", supportsBodyTracking: true, supportsPlaneClassification: false,
      supportsSceneReconstructionMesh: true, supportsSceneDepth: false), at: base)
    for event in telemetry.events {
      XCTAssertFalse(event.detail.contains(p.id.uuidString))
      XCTAssertNil(event.detail.range(of: "[0-9A-F]{8}-[0-9A-F]{4}-",
        options: .regularExpression))
    }
  }

  func testSummaryDetailFormat() {
    var telemetry = LocalSurfaceTelemetry(startedAt: base)
    telemetry.recordPlaneAdded(plane(), at: base.addingTimeInterval(1))
    XCTAssertEqual(telemetry.summaryDetail(),
      "adds=1 updates=0 removes=0 firstFloorMs=1000 firstWallMs=- samples=0")
  }
}
