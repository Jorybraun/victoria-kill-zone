import Foundation
import XCTest

@testable import VictoriaKillZone

final class DeviceCapabilityReportTests: XCTestCase {
  func testSummaryFormatsFlagsAsDigits() {
    let report = DeviceCapabilityReport(deviceModel: "iPhone16,1", systemVersion: "18.1",
      supportsBodyTracking: true, supportsPlaneClassification: true,
      supportsSceneReconstructionMesh: true, supportsSceneDepth: false)
    XCTAssertEqual(report.summary,
      "model=iPhone16,1 ios=18.1 body=1 planeClass=1 mesh=1 sceneDepth=0")
  }

  func testSummaryAllUnsupported() {
    let report = DeviceCapabilityReport(deviceModel: "iPhone10,4", systemVersion: "17.0",
      supportsBodyTracking: false, supportsPlaneClassification: false,
      supportsSceneReconstructionMesh: false, supportsSceneDepth: false)
    XCTAssertEqual(report.summary,
      "model=iPhone10,4 ios=17.0 body=0 planeClass=0 mesh=0 sceneDepth=0")
  }
}
