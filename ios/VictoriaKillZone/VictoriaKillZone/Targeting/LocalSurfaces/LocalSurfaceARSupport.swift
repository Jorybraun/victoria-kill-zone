#if os(iOS) && canImport(ARKit)
  import ARKit
  import Foundation

  extension LocalSurfacePlane {
    /// Maps an ARKit plane anchor into the phone's local gravity-aligned frame.
    init(anchor: ARPlaneAnchor, at now: Date, firstObservedAt: Date? = nil, updateCount: Int = 0) {
      let extent = anchor.planeExtent
      let transform = anchor.transform
      let worldCenter4 = transform * SIMD4<Float>(anchor.center, 1)
      let worldCenter = SIMD3<Float>(worldCenter4.x, worldCenter4.y, worldCenter4.z)
      let localX = simd_quatf(angle: extent.rotationOnYAxis, axis: SIMD3<Float>(0, 1, 0))
        .act(SIMD3<Float>(1, 0, 0))
      let worldX4 = transform * SIMD4<Float>(localX, 0)
      let worldX = simd_normalize(SIMD3<Float>(worldX4.x, worldX4.y, worldX4.z))
      let normalColumn = transform.columns.1
      let worldNormal = simd_normalize(SIMD3<Float>(normalColumn.x, normalColumn.y, normalColumn.z))
      self.init(
        id: anchor.identifier,
        alignment: LocalSurfaceAlignment(anchor.alignment),
        classification: LocalSurfaceClassification(anchor.classification),
        center: TargetingVector3(x: Double(worldCenter.x), y: Double(worldCenter.y),
          z: Double(worldCenter.z)),
        normal: TargetingVector3(x: Double(worldNormal.x), y: Double(worldNormal.y),
          z: Double(worldNormal.z)),
        xAxis: TargetingVector3(x: Double(worldX.x), y: Double(worldX.y), z: Double(worldX.z)),
        extentX: Double(extent.width),
        extentZ: Double(extent.height),
        boundaryVertexCount: anchor.geometry.boundaryVertices.count,
        firstObservedAt: firstObservedAt ?? now,
        lastUpdatedAt: now,
        updateCount: updateCount)
    }
  }

  extension LocalSurfaceClassification {
    init(_ classification: ARPlaneAnchor.Classification) {
      switch classification {
      case .none: self = .none
      case .wall: self = .wall
      case .floor: self = .floor
      case .ceiling: self = .ceiling
      case .table: self = .table
      case .seat: self = .seat
      case .window: self = .window
      case .door: self = .door
      @unknown default: self = .unknown
      }
    }
  }

  extension LocalSurfaceAlignment {
    init(_ alignment: ARPlaneAnchor.Alignment) {
      switch alignment {
      case .horizontal: self = .horizontal
      case .vertical: self = .vertical
      @unknown default: self = .horizontal
      }
    }
  }
#endif
