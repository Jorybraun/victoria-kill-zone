import CryptoKit
import Foundation

enum DuelFrameStage: String, Equatable, Sendable {
  case unaligned, mapping, mapReady, relocalizingWorld, relocalizingBody
  case awaitingResidual, aligned, degraded, lost
}

enum DuelFrameFailure: String, Error, Equatable, Sendable {
  case unsupported, cameraUnavailable, invalidEpoch, staleEpoch, mapNotReady
  case mapCaptureFailed, mapCaptureTimedOut, mapTooLarge, invalidMap, hashMismatch
  case operationSuperseded, relocalizationTimedOut, trackingLost, sessionInterrupted
  case backgrounded, sessionStopped, stalePose, staleResidual, residualExceeded, invalidResidual
}

/// Targeting-local value, not a transport envelope. The app authenticates the
/// sender and match epoch before handing reassembled bytes to this provider.
struct DuelFrameMap: Equatable, Sendable {
  static let maximumBytes = 8 * 1024 * 1024
  let epoch: UInt16
  let frameID: String
  let bytes: Data

  init(epoch: UInt16, bytes: Data, expectedFrameID: String? = nil) throws {
    guard epoch > 0 else { throw DuelFrameFailure.invalidEpoch }
    guard !bytes.isEmpty else { throw DuelFrameFailure.invalidMap }
    guard bytes.count <= Self.maximumBytes else { throw DuelFrameFailure.mapTooLarge }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard expectedFrameID == nil || expectedFrameID == digest else { throw DuelFrameFailure.hashMismatch }
    self.epoch = epoch
    frameID = digest
    self.bytes = bytes
  }
}

enum DuelFrameSessionPhase: Equatable, Sendable {
  case mapping, worldRelocalization, bodyRelocalization
}

enum DuelFrameTracking: Equatable, Sendable {
  case unavailable, limited, relocalizing, normal
}

/// A rigid, column-major camera transform in the installed map's frame. The AR
/// adapter validates/orthonormalizes sensor precision before publishing it.
struct DuelFramePose: Equatable, Sendable {
  let columnMajor: [Double]
  let capturedAt: Date
  let frameTimestamp: TimeInterval

  var isValid: Bool {
    columnMajor.count == 16 && columnMajor.allSatisfy(\.isFinite)
      && frameTimestamp.isFinite && frameTimestamp >= 0
  }
}

struct DuelFrameObservation: Equatable, Sendable {
  let epoch: UInt16
  let frameID: String?
  let phase: DuelFrameSessionPhase
  let tracking: DuelFrameTracking
  let isMapped: Bool
  let pose: DuelFramePose?
  let observedAt: Date
  let failure: DuelFrameFailure?
}

struct DuelFrameResidual: Equatable, Sendable {
  let translationMeters: Double
  let yawDegrees: Double
  let observedAt: Date
}

struct DuelFrameSnapshot: Equatable, Sendable {
  var stage: DuelFrameStage = .unaligned
  var epoch: UInt16?
  var frameID: String?
  var localPose: DuelFramePose?
  var residual: DuelFrameResidual?
  var failure: DuelFrameFailure?

  /// Read this at the instant of firing; a delayed UI publisher cannot extend
  /// permission after the last pose or independently measured residual expires.
  func permitsSpatialFire(at date: Date = Date()) -> Bool {
    stage == .aligned && epoch != nil && frameID != nil
      && localPose.map { $0.isValid && DuelFramePolicy.isFresh($0.capturedAt, at: date) } == true
      && residual.map { DuelFramePolicy.isFresh($0.observedAt, at: date) } == true
  }
}

protocol DuelFrameSessionDriving: Sendable {
  func duelFrameObservations() -> AsyncStream<DuelFrameObservation>
  func beginFrameMapping(epoch: UInt16) async throws
  func captureFrameMap(epoch: UInt16) async throws -> Data
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws
  func endFrameMapping() async
}

struct DuelFrameOperationToken: Equatable, Sendable {
  let generation: UInt64
  let epoch: UInt16
}
