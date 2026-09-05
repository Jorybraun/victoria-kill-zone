#if os(iOS) && canImport(ARKit)
  import ARKit
  import Foundation

  struct DuelFrameSessionConfiguration: Equatable, Sendable {
    let epoch: UInt16
    let frameID: String?
    let phase: DuelFrameSessionPhase
  }

  /// Immutable captured/decoded maps cross onto the archive queue as Apple
  /// recommends; their anchors are never mutated after capture or decoding.
  final class DuelFrameWorldMapBox: @unchecked Sendable {
    let map: ARWorldMap
    init(_ map: ARWorldMap) { self.map = map }
  }

  final class DuelFrameARState: @unchecked Sendable {
    let hub = DuelFrameObservationHub()
    let archiveQueue = DispatchQueue(label: "com.victoriakillzone.frame.archive", qos: .userInitiated)
    // Mutable fields belong exclusively to ARVisionTargetingSession.sessionQueue.
    var configuration: DuelFrameSessionConfiguration?
    var generation = 0
    var minimumFrameTimestamp = -Double.infinity
    var lastPublishedTimestamp = -Double.infinity
    var lastTracking: DuelFrameTracking?
    var pendingCapture: (generation: Int, continuation: CheckedContinuation<Data, any Error>)?

    func cancelPendingCapture() {
      if let pendingCapture {
        self.pendingCapture = nil
        pendingCapture.continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
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
