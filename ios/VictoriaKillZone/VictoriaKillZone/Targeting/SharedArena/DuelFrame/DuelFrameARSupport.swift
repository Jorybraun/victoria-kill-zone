#if os(iOS) && canImport(ARKit)
  import ARKit
  import Foundation

  /// Apple permits sharing an extending world map as well as a fully mapped one.
  /// Capture availability never grants combat alignment or spatial fire permission.
  enum DuelFrameMapCaptureEligibility {
    static func permits(mapping: ARFrame.WorldMappingStatus, tracking: ARCamera.TrackingState) -> Bool {
      guard case .normal = tracking else { return false }
      switch mapping {
      case .extending, .mapped: return true
      case .notAvailable, .limited: return false
      @unknown default: return false
      }
    }

    static func feedback(mapping: ARFrame.WorldMappingStatus, tracking: ARCamera.TrackingState) -> DuelFrameScanFeedback {
      switch tracking {
      case .notAvailable: return .trackingUnavailable
      case .normal: return permits(mapping: mapping, tracking: tracking) ? .ready : .mapping
      case .limited(let reason):
        switch reason {
        case .initializing: return .initializing
        case .excessiveMotion: return .movingTooFast
        case .insufficientFeatures: return .insufficientDetail
        case .relocalizing: return .relocalizing
        @unknown default: return .trackingLimited
        }
      @unknown default: return .trackingUnavailable
      }
    }
  }

  struct DuelFrameSessionConfiguration: Equatable, Sendable {
    let epoch: UInt16
    let frameID: String?
    let phase: DuelFrameSessionPhase
    /// Relocalized matches keep the world configuration for the whole match;
    /// the targeting pipeline must run during it, not only under body tracking.
    let processesTargeting: Bool
  }

  /// Immutable captured/decoded maps cross onto the archive queue as Apple
  /// recommends; their anchors are never mutated after capture or decoding.
  final class DuelFrameWorldMapBox: @unchecked Sendable {
    let map: ARWorldMap
    init(_ map: ARWorldMap) { self.map = map }
  }

  final class DuelFrameARState: @unchecked Sendable {
    let hub = DuelFrameObservationHub()
    /// Ordered, lossless: a dropped collaboration delta would corrupt the
    /// merge stream, so the transport (not this hub) applies backpressure.
    let collaborationHub = DuelFrameStreamHub<Data>(buffering: .unbounded)
    let archiveQueue = DispatchQueue(label: "com.victoriakillzone.frame.archive", qos: .userInitiated)
    // Mutable fields belong exclusively to ARVisionTargetingSession.sessionQueue.
    var configuration: DuelFrameSessionConfiguration?
    var alignmentMode: DuelFrameAlignmentMode = .measured
    var generation = 0
    var minimumFrameTimestamp = -Double.infinity
    var lastPublishedTimestamp = -Double.infinity
    var lastTracking: DuelFrameTracking?
    var pendingCapture: (generation: Int, continuation: CheckedContinuation<Data, any Error>)?
    var pendingReference: (generation: Int, continuation: CheckedContinuation<DuelFrameReference, any Error>)?
    var referenceCaptureTask: Task<Void, Never>?
    var reference: DuelFrameReference?
    var latestReferenceObservation: DuelFrameReferenceObservation?
    var pendingReferenceEvent: DuelFrameReferenceSensorEvent?
    var lastFrameTimestamp = -Double.infinity
    var lastFrameCapturedAt: Date?

    func cancelPendingCapture() {
      if let pendingCapture {
        self.pendingCapture = nil
        pendingCapture.continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
      }
      if let pendingReference {
        self.pendingReference = nil
        referenceCaptureTask?.cancel()
        referenceCaptureTask = nil
        pendingReference.continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
      }
    }

    func decode(_ bytes: Data) async throws -> DuelFrameWorldMapBox {
      try await withCheckedThrowingContinuation { continuation in
        archiveQueue.async {
          guard !bytes.isEmpty, bytes.count <= DuelFrameMap.maximumBytes,
            let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes)
          else {
            continuation.resume(throwing: DuelFrameFailure.invalidMap)
            return
          }
          continuation.resume(returning: DuelFrameWorldMapBox(map))
        }
      }
    }
  }
#endif
