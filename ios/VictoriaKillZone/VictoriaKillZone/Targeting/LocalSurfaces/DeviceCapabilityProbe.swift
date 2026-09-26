import Foundation

struct DeviceCapabilityReport: Codable, Equatable, Sendable {
  let deviceModel: String
  let systemVersion: String
  let supportsBodyTracking: Bool
  let supportsPlaneClassification: Bool
  let supportsSceneReconstructionMesh: Bool
  let supportsSceneDepth: Bool

  var summary: String {
    "model=\(deviceModel) ios=\(systemVersion) body=\(supportsBodyTracking ? 1 : 0) planeClass=\(supportsPlaneClassification ? 1 : 0) mesh=\(supportsSceneReconstructionMesh ? 1 : 0) sceneDepth=\(supportsSceneDepth ? 1 : 0)"
  }
}

#if os(iOS) && canImport(ARKit)
  import ARKit
  import UIKit

  enum DeviceCapabilityProbe {
    static func probe() -> DeviceCapabilityReport {
      var info = utsname()
      uname(&info)
      let model = withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      }
      return DeviceCapabilityReport(
        deviceModel: model,
        systemVersion: UIDevice.current.systemVersion,
        supportsBodyTracking: ARBodyTrackingConfiguration.isSupported,
        supportsPlaneClassification: ARPlaneAnchor.isClassificationSupported,
        supportsSceneReconstructionMesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
        supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
    }
  }
#endif
