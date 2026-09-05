import Foundation

enum TargetingAvailability: Equatable, Sendable {
  case available
  case notConfigured
}

enum TargetingTrackingState: String, CaseIterable, Equatable, Sendable {
  case cameraStarting = "CAMERA STARTING…"
  case searching = "SEARCHING"
  case bodyLock = "BODY LOCK"
  case torsoLock = "TORSO LOCK"
  case trackingLost = "TRACKING LOST"
  case targetingUnavailable = "TARGETING UNAVAILABLE"
  case targetReacquired = "TARGET REACQUIRED"

  var displayText: String { rawValue }
}

struct NormalizedTargetingRect: Equatable, Sendable {
  let minX: Double
  let minY: Double
  let width: Double
  let height: Double

  var area: Double { width * height }
  var centerX: Double { minX + width / 2 }
  var centerY: Double { minY + height / 2 }

  func contains(x: Double, y: Double) -> Bool {
    x >= minX && x <= minX + width && y >= minY && y <= minY + height
  }
}

struct NormalizedTargetingPoint: Equatable, Sendable {
  let x: Double
  let y: Double
  let confidence: Double
}

struct NormalizedTargetingEllipse: Equatable, Sendable {
  let centerX: Double
  let centerY: Double
  let radiusX: Double
  let radiusY: Double

  func contains(x: Double, y: Double) -> Bool {
    guard radiusX > 0, radiusY > 0 else { return false }
    let normalizedX = (x - centerX) / radiusX
    let normalizedY = (y - centerY) / radiusY
    return normalizedX * normalizedX + normalizedY * normalizedY <= 1
  }
}

struct NormalizedTargetingPolygon: Equatable, Sendable {
  let points: [NormalizedTargetingPoint]

  var bounds: NormalizedTargetingRect? {
    guard !points.isEmpty else { return nil }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(),
      let minY = ys.min(), let maxY = ys.max()
    else {
      return nil
    }
    return NormalizedTargetingRect(
      minX: minX,
      minY: minY,
      width: maxX - minX,
      height: maxY - minY
    )
  }

  func contains(x: Double, y: Double) -> Bool {
    guard points.count >= 3 else { return false }
    var isInside = false
    var previousIndex = points.count - 1
    for currentIndex in points.indices {
      let current = points[currentIndex]
      let previous = points[previousIndex]
      let crossesHorizontalRay = (current.y > y) != (previous.y > y)
      if crossesHorizontalRay {
        let denominator = previous.y - current.y
        let intersectionX = (previous.x - current.x) * (y - current.y) / denominator + current.x
        if x < intersectionX {
          isInside.toggle()
        }
      }
      previousIndex = currentIndex
    }
    return isInside
  }
}

enum TargetingHitZone: String, Equatable, Sendable {
  case head
  case torso

  var displayText: String { rawValue.uppercased() }
}

/// A zone claim that is safe for the fire path to consume.
///
/// Claims are emitted only after the same centre-crosshair solution has been
/// observed across the configured stability window. `capturedAt` is the Vision
/// frame time, rather than the later UI publication time.
struct TargetingAimClaim: Equatable, Sendable {
  let zone: TargetingHitZone
  let confidence: Double
  let capturedAt: Date
}

enum TargetingRegionBuilder {
  static func headRegion(
    facialPoints: [NormalizedTargetingPoint],
    neck: NormalizedTargetingPoint?,
    leftShoulder: NormalizedTargetingPoint?,
    rightShoulder: NormalizedTargetingPoint?
  ) -> NormalizedTargetingEllipse? {
    guard let leftShoulder = confident(leftShoulder, minimum: 0.45),
      let rightShoulder = confident(rightShoulder, minimum: 0.45)
    else {
      return nil
    }

    let shoulderDistance = hypot(
      leftShoulder.x - rightShoulder.x,
      leftShoulder.y - rightShoulder.y
    )
    guard shoulderDistance > 0.02 else { return nil }

    let validFacePoints = facialPoints.filter { $0.confidence >= 0.6 }
    let center: (x: Double, y: Double)
    if validFacePoints.count >= 2 {
      center = (
        validFacePoints.map(\.x).reduce(0, +) / Double(validFacePoints.count),
        validFacePoints.map(\.y).reduce(0, +) / Double(validFacePoints.count)
      )
    } else if let neck = confident(neck, minimum: 0.45) {
      center = (
        neck.x,
        neck.y + 0.32 * shoulderDistance
      )
    } else {
      return nil
    }

    return NormalizedTargetingEllipse(
      centerX: center.x,
      centerY: center.y,
      radiusX: 0.24 * shoulderDistance,
      radiusY: 0.32 * shoulderDistance
    )
  }

  static func headRegionConfidence(
    facialPoints: [NormalizedTargetingPoint],
    neck: NormalizedTargetingPoint?,
    leftShoulder: NormalizedTargetingPoint?,
    rightShoulder: NormalizedTargetingPoint?
  ) -> Double? {
    let validFacePoints = facialPoints.filter { $0.confidence >= 0.6 }
    if validFacePoints.count >= 2 {
      return validFacePoints.map(\.confidence).reduce(0, +) / Double(validFacePoints.count)
    }

    guard let neck = confident(neck, minimum: 0.45),
      let leftShoulder = confident(leftShoulder, minimum: 0.45),
      let rightShoulder = confident(rightShoulder, minimum: 0.45)
    else {
      return nil
    }
    return min(neck.confidence, min(leftShoulder.confidence, rightShoulder.confidence))
  }

  static func torsoRegion(
    leftShoulder: NormalizedTargetingPoint?,
    rightShoulder: NormalizedTargetingPoint?,
    leftHip: NormalizedTargetingPoint?,
    rightHip: NormalizedTargetingPoint?,
    root: NormalizedTargetingPoint?
  ) -> NormalizedTargetingPolygon? {
    guard let leftShoulder = confident(leftShoulder, minimum: 0.45),
      let rightShoulder = confident(rightShoulder, minimum: 0.45)
    else {
      return nil
    }

    if let leftHip = confident(leftHip, minimum: 0.45),
      let rightHip = confident(rightHip, minimum: 0.45)
    {
      return NormalizedTargetingPolygon(points: [
        leftShoulder,
        rightShoulder,
        rightHip,
        leftHip,
      ])
    }

    guard
      let lowerAnchor = confident(root, minimum: 0.45)
        ?? confident(leftHip, minimum: 0.45)
        ?? confident(rightHip, minimum: 0.45)
    else {
      return nil
    }
    let shoulderWidth = abs(leftShoulder.x - rightShoulder.x)
    let lowerHalfWidth = max(shoulderWidth * 0.36, 0.02)
    return NormalizedTargetingPolygon(points: [
      leftShoulder,
      rightShoulder,
      NormalizedTargetingPoint(
        x: lowerAnchor.x + lowerHalfWidth,
        y: lowerAnchor.y,
        confidence: lowerAnchor.confidence
      ),
      NormalizedTargetingPoint(
        x: lowerAnchor.x - lowerHalfWidth,
        y: lowerAnchor.y,
        confidence: lowerAnchor.confidence
      ),
    ])
  }

  private static func confident(
    _ point: NormalizedTargetingPoint?,
    minimum: Double
  ) -> NormalizedTargetingPoint? {
    guard let point, point.confidence >= minimum else { return nil }
    return point
  }
}

struct TargetingVector3: Equatable, Sendable {
  let x: Double
  let y: Double
  let z: Double

  static func + (lhs: TargetingVector3, rhs: TargetingVector3) -> TargetingVector3 {
    TargetingVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
  }

  static func - (lhs: TargetingVector3, rhs: TargetingVector3) -> TargetingVector3 {
    TargetingVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
  }

  static func * (lhs: TargetingVector3, rhs: Double) -> TargetingVector3 {
    TargetingVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
  }

  func dot(_ other: TargetingVector3) -> Double {
    x * other.x + y * other.y + z * other.z
  }
}

struct TargetingSkeletonJoint: Equatable, Sendable {
  let name: String
  let position: TargetingVector3
}

struct TargetingSkeletonBone: Equatable, Sendable {
  let from: String
  let to: String
}

struct TargetingSkeleton: Equatable, Sendable {
  let joints: [TargetingSkeletonJoint]
  let bones: [TargetingSkeletonBone]
  let capturedAt: Date

  func position(of name: String) -> TargetingVector3? {
    joints.first(where: { $0.name == name })?.position
  }
}

struct TargetingCameraRay: Equatable, Sendable {
  let origin: TargetingVector3
  let direction: TargetingVector3
  let capturedAt: Date
}

struct TargetingObservation: Equatable, Sendable {
  let capturedAt: Date
  let bodyConfidence: Double
  let headConfidence: Double?
  let torsoConfidence: Double?
  let bodyBounds: NormalizedTargetingRect
  let torsoBounds: NormalizedTargetingRect?
  let headRegion: NormalizedTargetingEllipse?
  let torsoRegion: NormalizedTargetingPolygon?
  let aimZone3D: TargetingHitZone?
  let skeleton: TargetingSkeleton?

  init(
    capturedAt: Date,
    bodyConfidence: Double,
    headConfidence: Double? = nil,
    torsoConfidence: Double?,
    bodyBounds: NormalizedTargetingRect,
    torsoBounds: NormalizedTargetingRect?,
    headRegion: NormalizedTargetingEllipse? = nil,
    torsoRegion: NormalizedTargetingPolygon? = nil,
    aimZone3D: TargetingHitZone? = nil,
    skeleton: TargetingSkeleton? = nil
  ) {
    self.capturedAt = capturedAt
    self.bodyConfidence = bodyConfidence
    self.headConfidence = headConfidence
    self.torsoConfidence = torsoConfidence
    self.bodyBounds = bodyBounds
    self.torsoBounds = torsoBounds
    self.headRegion = headRegion
    self.torsoRegion = torsoRegion
    self.aimZone3D = aimZone3D
    self.skeleton = skeleton
  }
}

struct TargetingThresholds: Equatable, Sendable {
  let visionInterval: TimeInterval
  let poseStaleAfter: TimeInterval
  let trackingLostAfter: TimeInterval
  let returnToSearchingAfter: TimeInterval
  let reacquiredHoldDuration: TimeInterval
  let bodyConfidence: Double
  let headConfidence: Double
  let torsoConfidence: Double
  let minimumAimObservations: Int
  let aimStabilityDuration: TimeInterval

  init(
    visionInterval: TimeInterval = 0.1,
    poseStaleAfter: TimeInterval = 0.2,
    trackingLostAfter: TimeInterval = 0.35,
    returnToSearchingAfter: TimeInterval = 1.0,
    reacquiredHoldDuration: TimeInterval = 0.3,
    bodyConfidence: Double = 0.45,
    headConfidence: Double = 0.6,
    torsoConfidence: Double = 0.45,
    minimumAimObservations: Int = 2,
    aimStabilityDuration: TimeInterval = 0.08
  ) {
    precondition(visionInterval > 0)
    precondition(poseStaleAfter > 0)
    precondition(trackingLostAfter >= poseStaleAfter)
    precondition(returnToSearchingAfter > trackingLostAfter)
    precondition(reacquiredHoldDuration >= 0)
    precondition((0...1).contains(bodyConfidence))
    precondition((0...1).contains(headConfidence))
    precondition((0...1).contains(torsoConfidence))
    precondition(minimumAimObservations > 0)
    precondition(aimStabilityDuration >= 0)

    self.visionInterval = visionInterval
    self.poseStaleAfter = poseStaleAfter
    self.trackingLostAfter = trackingLostAfter
    self.returnToSearchingAfter = returnToSearchingAfter
    self.reacquiredHoldDuration = reacquiredHoldDuration
    self.bodyConfidence = bodyConfidence
    self.headConfidence = headConfidence
    self.torsoConfidence = torsoConfidence
    self.minimumAimObservations = minimumAimObservations
    self.aimStabilityDuration = aimStabilityDuration
  }

  static let phaseZero = TargetingThresholds()
}

struct TargetingSnapshot: Equatable, Sendable {
  let state: TargetingTrackingState
  let bodyDetected: Bool
  let torsoDetected: Bool
  let confidence: Double
  let observedAt: Date
  let poseObservedAt: Date?
  let bodyBounds: NormalizedTargetingRect?
  let torsoBounds: NormalizedTargetingRect?
  let headRegion: NormalizedTargetingEllipse?
  let torsoRegion: NormalizedTargetingPolygon?
  let aimClaim: TargetingAimClaim?
  let cameraRay: TargetingCameraRay?
  let poseStaleAfter: TimeInterval
  let skeleton: TargetingSkeleton?

  /// Compatibility/readability conveniences for HUD and fire-path callers.
  var hitZone: TargetingHitZone? { aimClaim?.zone }
  var hitConfidence: Double { aimClaim?.confidence ?? 0 }
  var isLocked: Bool {
    [.bodyLock, .torsoLock, .targetReacquired].contains(state)
  }

  init(
    state: TargetingTrackingState,
    bodyDetected: Bool,
    torsoDetected: Bool,
    confidence: Double,
    observedAt: Date,
    poseObservedAt: Date?,
    bodyBounds: NormalizedTargetingRect?,
    torsoBounds: NormalizedTargetingRect?,
    headRegion: NormalizedTargetingEllipse?,
    torsoRegion: NormalizedTargetingPolygon?,
    aimClaim: TargetingAimClaim?,
    cameraRay: TargetingCameraRay?,
    poseStaleAfter: TimeInterval,
    skeleton: TargetingSkeleton? = nil
  ) {
    self.state = state
    self.bodyDetected = bodyDetected
    self.torsoDetected = torsoDetected
    self.confidence = confidence
    self.observedAt = observedAt
    self.poseObservedAt = poseObservedAt
    self.bodyBounds = bodyBounds
    self.torsoBounds = torsoBounds
    self.headRegion = headRegion
    self.torsoRegion = torsoRegion
    self.aimClaim = aimClaim
    self.cameraRay = cameraRay
    self.poseStaleAfter = poseStaleAfter
    self.skeleton = skeleton
  }

  // Keeps the Phase 0 shell initializer source-compatible while callers move to
  // the richer state snapshot.
  init(bodyDetected: Bool, confidence: Double, observedAt: Date) {
    self.init(
      state: bodyDetected ? .bodyLock : .searching,
      bodyDetected: bodyDetected,
      torsoDetected: false,
      confidence: confidence,
      observedAt: observedAt,
      poseObservedAt: bodyDetected ? observedAt : nil,
      bodyBounds: nil,
      torsoBounds: nil,
      headRegion: nil,
      torsoRegion: nil,
      aimClaim: nil,
      cameraRay: nil,
      poseStaleAfter: TargetingThresholds.phaseZero.poseStaleAfter,
      skeleton: nil
    )
  }

  func isPoseFresh(at date: Date) -> Bool {
    guard bodyDetected, let poseObservedAt else { return false }
    return date.timeIntervalSince(poseObservedAt) <= poseStaleAfter
  }

  static func unavailable(at date: Date = Date()) -> TargetingSnapshot {
    TargetingSnapshot(
      state: .targetingUnavailable,
      bodyDetected: false,
      torsoDetected: false,
      confidence: 0,
      observedAt: date,
      poseObservedAt: nil,
      bodyBounds: nil,
      torsoBounds: nil,
      headRegion: nil,
      torsoRegion: nil,
      aimClaim: nil,
      cameraRay: nil,
      poseStaleAfter: TargetingThresholds.phaseZero.poseStaleAfter
    )
  }
}

struct TargetingStateMachine: Sendable {
  private(set) var snapshot: TargetingSnapshot
  let thresholds: TargetingThresholds

  private var lastValidObservation: TargetingObservation?
  private var lastProcessedObservationAt: Date?
  private var cameraRay: TargetingCameraRay?
  private var hasLockedTarget = false
  private var pendingLockState = TargetingTrackingState.bodyLock
  private var pendingAimZone: TargetingHitZone?
  private var pendingAimConfidence = 0.0
  private var pendingAimStartedAt: Date?
  private var pendingAimLastObservedAt: Date?
  private var pendingAimObservationCount = 0
  private var confirmedAimClaim: TargetingAimClaim?
  private var stateChangedAt: Date

  init(
    thresholds: TargetingThresholds = .phaseZero,
    now: Date = Date()
  ) {
    self.thresholds = thresholds
    stateChangedAt = now
    snapshot = .unavailable(at: now)
  }

  mutating func sessionStarted(at date: Date) {
    lastValidObservation = nil
    lastProcessedObservationAt = nil
    cameraRay = nil
    hasLockedTarget = false
    pendingLockState = .bodyLock
    resetAimTracking()
    transition(to: .cameraStarting, at: date)
  }

  mutating func cameraBecameReady(at date: Date) {
    guard snapshot.state == .cameraStarting || snapshot.state == .targetingUnavailable else {
      return
    }
    transition(to: .searching, at: date)
  }

  mutating func ingest(_ observation: TargetingObservation, evaluatedAt date: Date) {
    guard lastProcessedObservationAt.map({ observation.capturedAt > $0 }) ?? true else {
      return
    }
    lastProcessedObservationAt = observation.capturedAt
    cameraBecameReady(at: date)

    guard date.timeIntervalSince(observation.capturedAt) <= thresholds.poseStaleAfter,
      observation.bodyConfidence >= thresholds.bodyConfidence
    else {
      noBodyObserved(capturedAt: observation.capturedAt, evaluatedAt: date)
      return
    }

    let aimCandidate: (zone: TargetingHitZone, confidence: Double)?
    if let zone3D = observation.aimZone3D {
      let headIsConfident =
        observation.headConfidence.map { $0 >= thresholds.headConfidence } ?? true
      aimCandidate =
        zone3D == .head && !headIsConfident
        ? nil
        : (zone3D, observation.bodyConfidence)
    } else {
      if let headConfidence = observation.headConfidence,
        headConfidence >= thresholds.headConfidence,
        observation.headRegion?.contains(x: 0.5, y: 0.5) == true
      {
        aimCandidate = (.head, min(observation.bodyConfidence, headConfidence))
      } else if let torsoConfidence = observation.torsoConfidence,
        torsoConfidence >= thresholds.torsoConfidence,
        observation.torsoRegion?.contains(x: 0.5, y: 0.5) == true
      {
        aimCandidate = (.torso, min(observation.bodyConfidence, torsoConfidence))
      } else {
        aimCandidate = nil
      }
    }
    updateAimTracking(with: aimCandidate, capturedAt: observation.capturedAt)
    let lockState: TargetingTrackingState = aimCandidate?.zone == .torso ? .torsoLock : .bodyLock

    let isReacquisition =
      snapshot.state == .targetReacquired
      || (hasLockedTarget && (snapshot.state == .trackingLost || snapshot.state == .searching))
    lastValidObservation = observation
    hasLockedTarget = true
    pendingLockState = lockState
    transition(to: isReacquisition ? .targetReacquired : lockState, at: date)
  }

  mutating func noBodyObserved(capturedAt: Date, evaluatedAt date: Date) {
    if lastProcessedObservationAt.map({ capturedAt > $0 }) ?? true {
      lastProcessedObservationAt = capturedAt
    }
    cameraBecameReady(at: date)
    tick(at: date)
  }

  mutating func updateCameraRay(_ ray: TargetingCameraRay, at date: Date) {
    cameraRay = ray
    rebuildSnapshot(state: snapshot.state, at: date)
  }

  mutating func tick(at date: Date) {
    switch snapshot.state {
    case .cameraStarting, .targetingUnavailable:
      return
    case .searching where lastValidObservation == nil:
      return
    default:
      break
    }

    guard let lastValidObservation else {
      transition(to: .searching, at: date)
      return
    }

    let age = max(0, date.timeIntervalSince(lastValidObservation.capturedAt))
    if age > thresholds.returnToSearchingAfter {
      resetAimTracking()
      transition(to: .searching, at: date)
    } else if age > thresholds.trackingLostAfter {
      resetAimTracking()
      transition(to: .trackingLost, at: date)
    } else if snapshot.state == .targetReacquired,
      date.timeIntervalSince(stateChangedAt) >= thresholds.reacquiredHoldDuration
    {
      transition(to: pendingLockState, at: date)
    } else {
      rebuildSnapshot(state: snapshot.state, at: date)
    }
  }

  mutating func sessionBecameUnavailable(at date: Date) {
    lastValidObservation = nil
    lastProcessedObservationAt = nil
    cameraRay = nil
    hasLockedTarget = false
    resetAimTracking()
    transition(to: .targetingUnavailable, at: date)
  }

  private mutating func updateAimTracking(
    with candidate: (zone: TargetingHitZone, confidence: Double)?,
    capturedAt: Date
  ) {
    guard let candidate else {
      resetAimTracking()
      return
    }

    if pendingAimZone == candidate.zone, let pendingAimStartedAt,
      let pendingAimLastObservedAt,
      capturedAt.timeIntervalSince(pendingAimLastObservedAt) <= thresholds.poseStaleAfter
    {
      pendingAimObservationCount += 1
      pendingAimConfidence = min(pendingAimConfidence, candidate.confidence)
      self.pendingAimLastObservedAt = capturedAt
      let heldDuration = max(0, capturedAt.timeIntervalSince(pendingAimStartedAt))
      if pendingAimObservationCount >= thresholds.minimumAimObservations
        || heldDuration >= thresholds.aimStabilityDuration
      {
        confirmedAimClaim = TargetingAimClaim(
          zone: candidate.zone,
          confidence: pendingAimConfidence,
          capturedAt: capturedAt
        )
      }
      return
    }

    pendingAimZone = candidate.zone
    pendingAimConfidence = candidate.confidence
    pendingAimStartedAt = capturedAt
    pendingAimLastObservedAt = capturedAt
    pendingAimObservationCount = 1
    confirmedAimClaim =
      thresholds.minimumAimObservations == 1
      ? TargetingAimClaim(
        zone: candidate.zone,
        confidence: candidate.confidence,
        capturedAt: capturedAt
      )
      : nil
  }

  private mutating func resetAimTracking() {
    pendingAimZone = nil
    pendingAimConfidence = 0
    pendingAimStartedAt = nil
    pendingAimLastObservedAt = nil
    pendingAimObservationCount = 0
    confirmedAimClaim = nil
  }

  private mutating func transition(to state: TargetingTrackingState, at date: Date) {
    if snapshot.state != state {
      stateChangedAt = date
    }
    rebuildSnapshot(state: state, at: date)
  }

  private mutating func rebuildSnapshot(state: TargetingTrackingState, at date: Date) {
    let reportsBody = state == .bodyLock || state == .torsoLock || state == .targetReacquired
    let observation = lastValidObservation
    let reportsTorso =
      reportsBody
      && (observation?.torsoRegion != nil || observation?.aimZone3D == .torso)
    let poseAge = observation.map { max(0, date.timeIntervalSince($0.capturedAt)) }
    let reportsFreshAim =
      reportsBody
      && poseAge.map { $0 <= thresholds.poseStaleAfter } == true

    snapshot = TargetingSnapshot(
      state: state,
      bodyDetected: reportsBody,
      torsoDetected: reportsTorso,
      confidence: reportsBody ? (observation?.bodyConfidence ?? 0) : 0,
      observedAt: date,
      poseObservedAt: observation?.capturedAt,
      bodyBounds: observation?.bodyBounds,
      torsoBounds: observation?.torsoBounds,
      headRegion: observation?.headRegion,
      torsoRegion: observation?.torsoRegion,
      aimClaim: reportsFreshAim ? confirmedAimClaim : nil,
      cameraRay: cameraRay,
      poseStaleAfter: thresholds.poseStaleAfter,
      skeleton: reportsFreshAim ? observation?.skeleton : nil
    )
  }
}

protocol TargetingSession: Sendable {
  var availability: TargetingAvailability { get }
  var currentSnapshot: TargetingSnapshot { get }

  func snapshots() -> AsyncStream<TargetingSnapshot>
  func start() async throws
  func stop() async
}

enum TargetingSessionError: Error, Equatable, Sendable {
  case notConfigured
  case cameraPermissionDenied
}

struct UnavailableTargetingSession: TargetingSession {
  let availability = TargetingAvailability.notConfigured
  let currentSnapshot = TargetingSnapshot.unavailable()

  func snapshots() -> AsyncStream<TargetingSnapshot> {
    AsyncStream { continuation in
      continuation.yield(currentSnapshot)
      continuation.finish()
    }
  }

  func start() async throws {
    throw TargetingSessionError.notConfigured
  }

  func stop() async {}
}

/// Keeps app composition cross-platform while selecting the physical-device
/// implementation in iOS builds.
enum TargetingSessionFactory {
  static func liveOrUnavailable() -> any TargetingSession {
    #if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
      ARVisionTargetingSession()
    #else
      UnavailableTargetingSession()
    #endif
  }
}

#if os(iOS) && canImport(ARKit) && canImport(AVFoundation) && canImport(Vision)
  import ARKit
  import AVFoundation
  import Combine
  import ImageIO
  import SceneKit
  import SwiftUI
  import Vision

  final class ARVisionTargetingSession: NSObject, ObservableObject, TargetingSession,
    @unchecked Sendable
  {
    let availability: TargetingAvailability
    let arSession: ARSession
    @Published private(set) var snapshot: TargetingSnapshot

    var currentSnapshot: TargetingSnapshot { snapshotHub.currentSnapshot() }

    private let thresholds: TargetingThresholds
    private let usesBodyTracking = ARBodyTrackingConfiguration.isSupported
    private let snapshotHub: TargetingSnapshotHub
    private let sessionQueue = DispatchQueue(
      label: "com.victoriakillzone.targeting.session",
      qos: .userInteractive
    )
    private let visionQueue = DispatchQueue(
      label: "com.victoriakillzone.targeting.vision",
      qos: .userInitiated
    )
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private var machine: TargetingStateMachine
    private var notificationTokens: [NSObjectProtocol] = []
    private var runRequested = false
    private var isSessionRunning = false
    private var isBackgrounded = false
    private var visionInFlight = false
    private var lastVisionFrameTimestamp = -Double.infinity
    private var generation = 0
    private var lifecycleGeneration = 0
    private let duelFrameState = DuelFrameARState()

    override init() {
      let now = Date()
      let initialSnapshot = TargetingSnapshot.unavailable(at: now)
      let supported = ARWorldTrackingConfiguration.isSupported || ARBodyTrackingConfiguration.isSupported

      availability = supported ? .available : .notConfigured
      thresholds = .phaseZero
      arSession = ARSession()
      machine = TargetingStateMachine(thresholds: .phaseZero, now: now)
      snapshot = initialSnapshot
      snapshotHub = TargetingSnapshotHub(initialSnapshot: initialSnapshot)
      super.init()

      arSession.delegate = self
      arSession.delegateQueue = sessionQueue
      registerForLifecycleNotifications()
    }

    deinit {
      notificationTokens.forEach(NotificationCenter.default.removeObserver)
      arSession.pause()
      snapshotHub.finish()
      duelFrameState.hub.finish()
    }

    func snapshots() -> AsyncStream<TargetingSnapshot> {
      snapshotHub.makeStream()
    }

    /// `ARSCNView` installs itself as the session delegate when it is handed a
    /// session, which would disconnect frame processing (and body detection).
    /// Rendering views must call this after taking the session.
    func reassertSessionDelegate() {
      arSession.delegate = self
      arSession.delegateQueue = sessionQueue
    }

    func start() async throws {
      guard availability == .available else {
        throw TargetingSessionError.notConfigured
      }

      // Record intent before awaiting permission. A concurrent stop invalidates
      // this generation, so permission completion can never restart a stopped
      // session. Repeated starts are intentionally idempotent.
      let requestGeneration: Int? = await withCheckedContinuation { continuation in
        sessionQueue.async { [self] in
          guard !runRequested else {
            continuation.resume(returning: nil)
            return
          }
          runRequested = true
          lifecycleGeneration += 1
          continuation.resume(returning: lifecycleGeneration)
        }
      }
      guard let requestGeneration else { return }

      guard await Self.hasCameraAccess() else {
        await failStart(requestGeneration: requestGeneration)
        throw TargetingSessionError.cameraPermissionDenied
      }

      await withCheckedContinuation { continuation in
        sessionQueue.async { [self] in
          guard lifecycleGeneration == requestGeneration, runRequested else {
            continuation.resume()
            return
          }
          if !isBackgrounded, !isSessionRunning {
            startWorldTracking(resetTracking: true)
          }
          continuation.resume()
        }
      }
    }

    func stop() async {
      await withCheckedContinuation { continuation in
        sessionQueue.async { [self] in
          invalidateDuelFrameSession(reason: .sessionStopped)
          lifecycleGeneration += 1
          runRequested = false
          generation += 1
          visionInFlight = false
          arSession.pause()
          isSessionRunning = false
          machine.sessionBecameUnavailable(at: Date())
          publish(machine.snapshot)
          continuation.resume()
        }
      }
    }

    private func failStart(requestGeneration: Int) async {
      await withCheckedContinuation { continuation in
        sessionQueue.async { [self] in
          guard lifecycleGeneration == requestGeneration else {
            continuation.resume()
            return
          }
          lifecycleGeneration += 1
          runRequested = false
          generation += 1
          visionInFlight = false
          arSession.pause()
          isSessionRunning = false
          machine.sessionBecameUnavailable(at: Date())
          publish(machine.snapshot)
          continuation.resume()
        }
      }
    }

    private static func hasCameraAccess() async -> Bool {
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        return true
      case .notDetermined:
        return await AVCaptureDevice.requestAccess(for: .video)
      case .denied, .restricted:
        return false
      @unknown default:
        return false
      }
    }

    private func registerForLifecycleNotifications() {
      let center = NotificationCenter.default
      notificationTokens = [
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.suspendForBackground()
        },
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.resumeFromBackground()
        },
      ]
    }

    private func suspendForBackground() {
      sessionQueue.async { [weak self] in
        guard let self else { return }
        invalidateDuelFrameSession(reason: .backgrounded)
        isBackgrounded = true
        generation += 1
        visionInFlight = false
        arSession.pause()
        isSessionRunning = false
        machine.sessionBecameUnavailable(at: Date())
        publish(machine.snapshot)
      }
    }

    private func resumeFromBackground() {
      sessionQueue.async { [weak self] in
        guard let self else { return }
        isBackgrounded = false
        guard runRequested, !isSessionRunning else { return }
        startWorldTracking(resetTracking: false)
      }
    }

    private func startWorldTracking(resetTracking: Bool) {
      guard runRequested, !isBackgrounded, !isSessionRunning else { return }
      // A paused map session must be explicitly recalibrated. Resuming the
      // default local configuration would silently replace its coordinate frame.
      guard duelFrameState.configuration == nil else { return }
      generation += 1
      visionInFlight = false
      lastVisionFrameTimestamp = -Double.infinity
      machine.sessionStarted(at: Date())
      publish(machine.snapshot)

      let configuration: ARConfiguration
      if usesBodyTracking {
        let bodyConfiguration = ARBodyTrackingConfiguration()
        bodyConfiguration.worldAlignment = .gravity
        bodyConfiguration.automaticSkeletonScaleEstimationEnabled = true
        configuration = bodyConfiguration
      } else {
        let worldConfiguration = ARWorldTrackingConfiguration()
        worldConfiguration.worldAlignment = .gravity
        configuration = worldConfiguration
      }
      let options: ARSession.RunOptions =
        resetTracking
        ? [.resetTracking, .removeExistingAnchors]
        : []
      arSession.run(configuration, options: options)
      isSessionRunning = true
    }

    private func publish(_ nextSnapshot: TargetingSnapshot) {
      snapshotHub.yield(nextSnapshot)
      DispatchQueue.main.async { [weak self] in
        self?.snapshot = nextSnapshot
      }
    }

    private func process(frame: ARFrame) {
      guard runRequested, isSessionRunning, !isBackgrounded else { return }
      if let configuration = duelFrameState.configuration {
        guard frame.timestamp > duelFrameState.minimumFrameTimestamp,
          frame.timestamp > duelFrameState.lastFrameTimestamp,
          let cameraCapturedAt = DuelFrameSensorTime.capturedAt(deliveredTimestamp: frame.timestamp,
            latestTimestamp: arSession.currentFrame?.timestamp ?? frame.timestamp, now: Date())
        else { return }
        duelFrameState.lastFrameTimestamp = frame.timestamp
        duelFrameState.lastFrameCapturedAt = cameraCapturedAt
        if let event = duelFrameState.pendingReferenceEvent,
          let capturedAt = duelFrameState.lastFrameCapturedAt,
          event.frameTimestamp <= frame.timestamp {
          duelFrameState.latestReferenceObservation = event.observation(cameraTimestamp: frame.timestamp, cameraCapturedAt: capturedAt)
          duelFrameState.pendingReferenceEvent = nil
        }
        publishDuelFrameObservation(frame: frame, configuration: configuration)
        if configuration.phase != .bodyRelocalization { return }
      }
      let now = Date()
      machine.cameraBecameReady(at: now)
      machine.updateCameraRay(Self.cameraRay(from: frame, capturedAt: now), at: now)
      machine.tick(at: now)
      publish(machine.snapshot)

      if usesBodyTracking {
        let capturedAt = now
        let observation = frame.anchors.compactMap { $0 as? ARBodyAnchor }.first
          .flatMap { Self.bodyObservation(from: $0, frame: frame, capturedAt: capturedAt) }
        if let observation {
          machine.ingest(observation, evaluatedAt: now)
        } else {
          machine.noBodyObserved(capturedAt: capturedAt, evaluatedAt: now)
        }
        publish(machine.snapshot)
        return
      }

      guard !visionInFlight else { return }
      guard frame.timestamp - lastVisionFrameTimestamp >= thresholds.visionInterval else { return }

      visionInFlight = true
      lastVisionFrameTimestamp = frame.timestamp
      let capturedAt = now
      let pixelBuffer = frame.capturedImage
      let requestGeneration = generation

      visionQueue.async { [weak self] in
        guard let self else { return }
        let observation = detectPose(in: pixelBuffer, capturedAt: capturedAt)
        sessionQueue.async { [weak self] in
          guard let self else { return }
          visionInFlight = false
          guard requestGeneration == generation, runRequested, !isBackgrounded else { return }

          let evaluatedAt = Date()
          if let observation {
            machine.ingest(observation, evaluatedAt: evaluatedAt)
          } else {
            machine.noBodyObserved(capturedAt: capturedAt, evaluatedAt: evaluatedAt)
          }
          publish(machine.snapshot)
        }
      }
    }

    private func detectPose(
      in pixelBuffer: CVPixelBuffer,
      capturedAt: Date
    ) -> TargetingObservation? {
      let handler = VNImageRequestHandler(
        cvPixelBuffer: pixelBuffer,
        orientation: .right,
        options: [:]
      )
      do {
        try handler.perform([poseRequest])
      } catch {
        return nil
      }

      return (poseRequest.results ?? [])
        .compactMap { Self.targetingCandidate(from: $0, capturedAt: capturedAt) }
        .max(by: { $0.score < $1.score })?
        .observation
    }

    private static func targetingCandidate(
      from pose: VNHumanBodyPoseObservation,
      capturedAt: Date
    ) -> (observation: TargetingObservation, score: Double)? {
      guard let points = try? pose.recognizedPoints(.all) else { return nil }
      let usablePoints = points.values.filter { $0.confidence >= 0.2 }
      guard usablePoints.count >= 3 else { return nil }

      let bodyBounds = normalizedBounds(for: usablePoints)
      let bodyConfidence =
        usablePoints
        .map { Double($0.confidence) }
        .reduce(0, +) / Double(usablePoints.count)

      let leftShoulder = normalizedPoint(points[.leftShoulder])
      let rightShoulder = normalizedPoint(points[.rightShoulder])
      let leftHip = normalizedPoint(points[.leftHip])
      let rightHip = normalizedPoint(points[.rightHip])
      let root = normalizedPoint(points[.root])
      let neck = normalizedPoint(points[.neck])
      let facePoints = [
        points[.nose],
        points[.leftEye],
        points[.rightEye],
        points[.leftEar],
        points[.rightEar],
      ].compactMap(normalizedPoint)
      let headRegion = TargetingRegionBuilder.headRegion(
        facialPoints: facePoints,
        neck: neck,
        leftShoulder: leftShoulder,
        rightShoulder: rightShoulder
      )
      let headConfidence =
        headRegion.map { _ in
          TargetingRegionBuilder.headRegionConfidence(
            facialPoints: facePoints,
            neck: neck,
            leftShoulder: leftShoulder,
            rightShoulder: rightShoulder
          )
        } ?? nil
      let torsoRegion = TargetingRegionBuilder.torsoRegion(
        leftShoulder: leftShoulder,
        rightShoulder: rightShoulder,
        leftHip: leftHip,
        rightHip: rightHip,
        root: root
      )
      let torsoConfidence = torsoRegion.map { region in
        region.points.map(\.confidence).reduce(0, +) / Double(region.points.count)
      }

      let distanceFromCrosshair = hypot(bodyBounds.centerX - 0.5, bodyBounds.centerY - 0.5)
      let crosshairProximity = max(0, 1 - distanceFromCrosshair / 0.71)
      let score =
        bodyConfidence * 0.55
        + min(1, bodyBounds.area * 4) * 0.30
        + crosshairProximity * 0.15

      return (
        TargetingObservation(
          capturedAt: capturedAt,
          bodyConfidence: bodyConfidence,
          headConfidence: headConfidence,
          torsoConfidence: torsoConfidence,
          bodyBounds: bodyBounds,
          torsoBounds: torsoRegion?.bounds,
          headRegion: headRegion,
          torsoRegion: torsoRegion
        ),
        score
      )
    }

    private static func normalizedPoint(
      _ point: VNRecognizedPoint?
    ) -> NormalizedTargetingPoint? {
      guard let point else { return nil }
      return NormalizedTargetingPoint(
        x: point.location.x,
        y: point.location.y,
        confidence: Double(point.confidence)
      )
    }

    private static func normalizedBounds(
      for points: [VNRecognizedPoint]
    ) -> NormalizedTargetingRect {
      let xs = points.map(\.location.x)
      let ys = points.map(\.location.y)
      let minX = xs.min() ?? 0
      let maxX = xs.max() ?? minX
      let minY = ys.min() ?? 0
      let maxY = ys.max() ?? minY
      return NormalizedTargetingRect(
        minX: minX,
        minY: minY,
        width: maxX - minX,
        height: maxY - minY
      )
    }

    private static func cameraRay(
      from frame: ARFrame,
      capturedAt: Date
    ) -> TargetingCameraRay {
      let transform = frame.camera.transform
      let origin = TargetingVector3(
        x: Double(transform.columns.3.x),
        y: Double(transform.columns.3.y),
        z: Double(transform.columns.3.z)
      )
      let rawX = -Double(transform.columns.2.x)
      let rawY = -Double(transform.columns.2.y)
      let rawZ = -Double(transform.columns.2.z)
      let magnitude = max(
        Double.leastNonzeroMagnitude,
        sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ)
      )
      return TargetingCameraRay(
        origin: origin,
        direction: TargetingVector3(
          x: rawX / magnitude,
          y: rawY / magnitude,
          z: rawZ / magnitude
        ),
        capturedAt: capturedAt
      )
    }

    static func bodyObservation(
      from anchor: ARBodyAnchor,
      frame: ARFrame,
      capturedAt: Date
    ) -> TargetingObservation? {
      let requestedJoints: [(String, ARSkeleton.JointName)] = [
        ("head", .head), ("root", .root), ("leftShoulder", .leftShoulder),
        ("rightShoulder", .rightShoulder), ("leftHand", .leftHand),
        ("rightHand", .rightHand), ("leftFoot", .leftFoot), ("rightFoot", .rightFoot),
        ("neck_1_joint", ARSkeleton.JointName(rawValue: "neck_1_joint")),
        ("spine_7_joint", ARSkeleton.JointName(rawValue: "spine_7_joint")),
        ("left_forearm_joint", ARSkeleton.JointName(rawValue: "left_forearm_joint")),
        ("right_forearm_joint", ARSkeleton.JointName(rawValue: "right_forearm_joint")),
        ("left_leg_joint", ARSkeleton.JointName(rawValue: "left_leg_joint")),
        ("right_leg_joint", ARSkeleton.JointName(rawValue: "right_leg_joint")),
        ("left_upLeg_joint", ARSkeleton.JointName(rawValue: "left_upLeg_joint")),
        ("right_upLeg_joint", ARSkeleton.JointName(rawValue: "right_upLeg_joint")),
        ("left_arm_joint", ARSkeleton.JointName(rawValue: "left_arm_joint")),
        ("right_arm_joint", ARSkeleton.JointName(rawValue: "right_arm_joint")),
      ]
      var positions: [String: TargetingVector3] = [:]
      for (name, joint) in requestedJoints {
        let index = anchor.skeleton.definition.index(for: joint)
        guard anchor.skeleton.isJointTracked(index),
          let model = anchor.skeleton.modelTransform(for: joint)
        else { continue }
        let world = anchor.transform * model
        positions[name] = TargetingVector3(
          x: Double(world.columns.3.x),
          y: Double(world.columns.3.y),
          z: Double(world.columns.3.z)
        )
      }
      let ray = cameraRay(from: frame, capturedAt: capturedAt)
      return BodyTargetingGeometry.observation(
        joints: positions,
        isTracked: anchor.isTracked,
        ray: ray,
        project: { point in
          let result = frame.camera.projectPoint(
            SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z)),
            orientation: .portrait,
            viewportSize: CGSize(width: 1, height: 1)
          )
          return NormalizedTargetingPoint(
            x: min(1, max(0, Double(result.x))),
            y: min(1, max(0, Double(result.y))),
            confidence: 1
          )
        },
        capturedAt: capturedAt
      )
    }
  }

  extension ARVisionTargetingSession: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      recordDuelReferenceAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      recordDuelReferenceAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      process(frame: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
      invalidateDuelFrameSession(reason: .cameraUnavailable)
      generation += 1
      visionInFlight = false
      isSessionRunning = false
      machine.sessionBecameUnavailable(at: Date())
      publish(machine.snapshot)
    }

    func sessionWasInterrupted(_ session: ARSession) {
      invalidateDuelFrameSession(reason: .sessionInterrupted)
      generation += 1
      visionInFlight = false
      isSessionRunning = false
      machine.sessionBecameUnavailable(at: Date())
      publish(machine.snapshot)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
      guard runRequested, !isBackgrounded, !isSessionRunning else { return }
      startWorldTracking(resetTracking: false)
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
  }

  extension ARVisionTargetingSession: DuelFrameSessionDriving {
    func duelFrameObservations() -> AsyncStream<DuelFrameObservation> {
      duelFrameState.hub.stream()
    }

    func beginFrameMapping(epoch: UInt16) async throws {
      guard epoch > 0 else { throw DuelFrameFailure.invalidEpoch }
      guard ARWorldTrackingConfiguration.isSupported, ARBodyTrackingConfiguration.isSupported else {
        throw DuelFrameFailure.unsupported
      }
      try await start()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        sessionQueue.async { [self] in
          guard runRequested, !isBackgrounded else {
            continuation.resume(throwing: DuelFrameFailure.cameraUnavailable)
            return
          }
          guard duelFrameState.configuration.map({ epoch > $0.epoch }) ?? true else {
            continuation.resume(throwing: DuelFrameFailure.staleEpoch)
            return
          }
          let configuration = ARWorldTrackingConfiguration()
          configuration.worldAlignment = .gravity
          configuration.planeDetection = [.horizontal, .vertical]
          duelFrameState.reference = nil
          runDuelFrameConfiguration(configuration,
            metadata: DuelFrameSessionConfiguration(epoch: epoch, frameID: nil, phase: .mapping))
          continuation.resume()
        }
      }
    }

    func captureFrameMap(epoch: UInt16) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        sessionQueue.async { [self] in
          guard runRequested, isSessionRunning, !isBackgrounded,
            duelFrameState.configuration?.epoch == epoch,
            duelFrameState.configuration?.phase == .mapping,
            arSession.configuration is ARWorldTrackingConfiguration,
            let currentFrame = arSession.currentFrame,
            currentFrame.worldMappingStatus == .mapped,
            case .normal = currentFrame.camera.trackingState,
            duelFrameState.pendingCapture == nil
          else {
            continuation.resume(throwing: DuelFrameFailure.mapNotReady)
            return
          }
          // Each capture has a unique generation, including retries within one
          // mapping run, so an earlier timeout cannot cancel a later capture.
          duelFrameState.generation += 1
          let requestGeneration = duelFrameState.generation
          duelFrameState.pendingCapture = (requestGeneration, continuation)
          sessionQueue.asyncAfter(deadline: .now() + DuelFramePolicy.relocalizationTimeout) { [weak self] in
            guard let self, let pending = duelFrameState.pendingCapture,
              pending.generation == requestGeneration
            else { return }
            duelFrameState.pendingCapture = nil
            pending.continuation.resume(throwing: DuelFrameFailure.mapCaptureTimedOut)
          }
          arSession.getCurrentWorldMap { [weak self] map, _ in
            guard let self else { return }
            guard let map else {
              finishDuelMapCapture(.failure(.mapCaptureFailed), generation: requestGeneration)
              return
            }
            let box = DuelFrameWorldMapBox(map)
            duelFrameState.archiveQueue.async { [weak self] in
              guard let self else { return }
              let result: Result<Data, DuelFrameFailure>
              if let bytes = try? NSKeyedArchiver.archivedData(withRootObject: box.map, requiringSecureCoding: true) {
                result = bytes.count <= DuelFrameMap.maximumBytes ? .success(bytes) : .failure(.mapTooLarge)
              } else {
                result = .failure(.mapCaptureFailed)
              }
              sessionQueue.async { [weak self] in
                self?.finishDuelMapCapture(result, generation: requestGeneration)
              }
            }
          }
        }
      }
    }

    func captureFrameReference(epoch: UInt16) async throws -> DuelFrameReference {
      try await withCheckedThrowingContinuation { continuation in
        sessionQueue.async { [self] in
          guard runRequested, isSessionRunning, !isBackgrounded,
            duelFrameState.configuration?.epoch == epoch, duelFrameState.configuration?.phase == .mapping,
            duelFrameState.pendingReference == nil, duelFrameState.pendingCapture == nil else {
            continuation.resume(throwing: DuelFrameFailure.mapNotReady); return
          }
          duelFrameState.generation += 1
          let token = duelFrameState.generation
          duelFrameState.pendingReference = (token, continuation)
          duelFrameState.referenceCaptureTask = Task { [weak self] in
            guard let self else { return }
            do {
              let reference = try await buildDuelReference(epoch: epoch, token: token)
              sessionQueue.async { [self] in self.finishDuelReference(.success(reference), token: token) }
            } catch {
              let failure = error as? DuelFrameFailure ?? .referenceUnsuitable
              sessionQueue.async { [self] in self.finishDuelReference(.failure(failure), token: token) }
            }
          }
          sessionQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.finishDuelReference(.failure(.referenceCaptureTimedOut), token: token)
          }
        }
      }
    }

    private func finishDuelReference(_ result: Result<DuelFrameReference, DuelFrameFailure>, token: Int) {
      guard let pending = duelFrameState.pendingReference, pending.generation == token else { return }
      duelFrameState.pendingReference = nil
      duelFrameState.referenceCaptureTask?.cancel()
      duelFrameState.referenceCaptureTask = nil
      guard duelFrameState.generation == token, runRequested, !isBackgrounded else {
        pending.continuation.resume(throwing: DuelFrameFailure.operationSuperseded); return
      }
      switch result {
      case .success(let reference): pending.continuation.resume(returning: reference)
      case .failure(let failure): pending.continuation.resume(throwing: failure)
      }
    }

    private func buildDuelReference(epoch: UInt16, token: Int) async throws -> DuelFrameReference {
      var samples: [DuelFrameReferencePlane] = []
      var previousTimestamp = -Double.infinity
      var lastCapture: DuelFrameCaptureFrame?
      var lastRectangle: DuelFrameRectangle?
      for index in 0..<3 {
        if index > 0 { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        let capture: DuelFrameCaptureFrame = try await withCheckedThrowingContinuation { continuation in
          sessionQueue.async { [self] in
            guard duelFrameState.generation == token, duelFrameState.pendingReference?.generation == token,
              duelFrameState.configuration?.epoch == epoch, runRequested, !isBackgrounded,
              let frame = arSession.currentFrame, case .normal = frame.camera.trackingState,
              frame.worldMappingStatus == .mapped,
              frame.timestamp == duelFrameState.lastFrameTimestamp,
              let capturedAt = duelFrameState.lastFrameCapturedAt,
              DuelFramePolicy.isFresh(capturedAt, at: Date()) else {
              continuation.resume(throwing: DuelFrameFailure.mapNotReady); return
            }
            continuation.resume(returning: DuelFrameCaptureFrame(frame: frame, capturedAt: capturedAt))
          }
        }
        guard capture.frame.timestamp > previousTimestamp else { throw DuelFrameFailure.referenceUnsuitable }
        previousTimestamp = capture.frame.timestamp
        let rectangle: DuelFrameRectangle = try await withCheckedThrowingContinuation { continuation in
          visionQueue.async {
            do { continuation.resume(returning: try DuelFrameReferenceCapture.rectangle(in: capture)) }
            catch { continuation.resume(throwing: error) }
          }
        }
        let plane: DuelFrameReferencePlane = try await withCheckedThrowingContinuation { continuation in
          sessionQueue.async { [self] in
            do { continuation.resume(returning: try measureDuelReference(capture, rectangle: rectangle, epoch: epoch, token: token)) }
            catch { continuation.resume(throwing: error) }
          }
        }
        samples.append(plane); lastCapture = capture; lastRectangle = rectangle
      }
      let deviation = try DuelFrameReferenceGeometry.maximumDeviation(samples)
      guard let capture = lastCapture, let rectangle = lastRectangle, let plane = samples.last else {
        throw DuelFrameFailure.referenceUnsuitable
      }
      let image: Data = try await withCheckedThrowingContinuation { continuation in
        duelFrameState.archiveQueue.async {
          do { continuation.resume(returning: try DuelFrameReferenceCapture.image(in: capture, rectangle: rectangle, plane: plane)) }
          catch { continuation.resume(throwing: error) }
        }
      }
      let reference = try DuelFrameReference(imageData: image, widthMeters: plane.widthMeters,
        heightMeters: plane.heightMeters, mapFromImage: plane.mapFromImage,
        sampleCount: samples.count, maximumCornerDeviationMeters: deviation)
      let referenceImage = try DuelFrameReferenceCapture.referenceImage(reference)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        referenceImage.validate { error in
          if error != nil { continuation.resume(throwing: DuelFrameFailure.referenceUnsuitable) }
          else { continuation.resume() }
        }
      }
      return reference
    }

    private func measureDuelReference(_ capture: DuelFrameCaptureFrame, rectangle: DuelFrameRectangle,
      epoch: UInt16, token: Int) throws -> DuelFrameReferencePlane {
      guard duelFrameState.generation == token, duelFrameState.pendingReference?.generation == token,
        duelFrameState.configuration?.epoch == epoch, runRequested, !isBackgrounded,
        Date().timeIntervalSince(capture.capturedAt) <= 0.5,
        let current = arSession.currentFrame, current.timestamp >= capture.frame.timestamp,
        current.timestamp - capture.frame.timestamp <= 0.5,
        case .normal = current.camera.trackingState else { throw DuelFrameFailure.referenceUnsuitable }
      let frame = capture.frame, transform = frame.camera.transform
      let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
      let currentOrigin = SIMD3<Float>(current.camera.transform.columns.3.x,
        current.camera.transform.columns.3.y, current.camera.transform.columns.3.z)
      guard simd_distance(origin, currentOrigin) <= 0.025 else { throw DuelFrameFailure.referenceUnsuitable }
      let k = frame.camera.intrinsics, size = frame.camera.imageResolution
      var corners: [SIMD3<Double>] = []
      var planeID: UUID?
      for point in rectangle.corners {
        let cameraDirection = SIMD4<Float>(
          (Float(point.x * size.width) - k.columns.2.x) / k.columns.0.x,
          -(Float((1 - point.y) * size.height) - k.columns.2.y) / k.columns.1.y, -1, 0)
        let world = transform * cameraDirection
        let direction = simd_normalize(SIMD3<Float>(world.x, world.y, world.z))
        let query = ARRaycastQuery(origin: origin, direction: direction,
          allowing: .existingPlaneGeometry, alignment: .any)
        guard let result = arSession.raycast(query).first, let anchor = result.anchor,
          planeID == nil || planeID == anchor.identifier else { throw DuelFrameFailure.referenceUnsuitable }
        planeID = anchor.identifier
        let p = result.worldTransform.columns.3
        corners.append(SIMD3(Double(p.x), Double(p.y), Double(p.z)))
      }
      return try DuelFrameReferenceGeometry.plane(corners: corners,
        camera: SIMD3(Double(origin.x), Double(origin.y), Double(origin.z)))
    }

    func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws {
      guard phase != .mapping else { throw DuelFrameFailure.invalidMap }
      let requestGeneration: Int = try await withCheckedThrowingContinuation { continuation in
        sessionQueue.async { [self] in
          guard runRequested, !isBackgrounded, duelFrameState.configuration?.epoch == map.epoch else {
            continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
            return
          }
          duelFrameState.generation += 1
          duelFrameState.cancelPendingCapture()
          continuation.resume(returning: duelFrameState.generation)
        }
      }
      let decoded = try await duelFrameState.decode(map.worldMapBytes)
      let referenceImage = try map.reference.map(DuelFrameReferenceCapture.referenceImage)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        sessionQueue.async { [self] in
          guard runRequested, !isBackgrounded, duelFrameState.generation == requestGeneration,
            duelFrameState.configuration?.epoch == map.epoch
          else {
            continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
            return
          }
          let configuration: ARConfiguration
          if phase == .bodyRelocalization {
            let body = ARBodyTrackingConfiguration()
            body.worldAlignment = .gravity
            body.automaticSkeletonScaleEstimationEnabled = true
            body.initialWorldMap = decoded.map
            body.planeDetection = [.horizontal, .vertical]
            if let referenceImage {
              body.detectionImages = [referenceImage]
              body.maximumNumberOfTrackedImages = 1
            }
            configuration = body
          } else {
            let world = ARWorldTrackingConfiguration()
            world.worldAlignment = .gravity
            world.initialWorldMap = decoded.map
            world.planeDetection = [.horizontal, .vertical]
            if let referenceImage {
              world.detectionImages = [referenceImage]
              world.maximumNumberOfTrackedImages = 1
            }
            configuration = world
          }
          duelFrameState.reference = map.reference
          runDuelFrameConfiguration(configuration,
            metadata: DuelFrameSessionConfiguration(epoch: map.epoch, frameID: map.frameID, phase: phase))
          continuation.resume()
        }
      }
    }

    func endFrameMapping() async {
      await withCheckedContinuation { continuation in
        sessionQueue.async { [self] in
          invalidateDuelFrameSession(reason: .sessionStopped)
          duelFrameState.configuration = nil
          arSession.pause()
          isSessionRunning = false
          if runRequested, !isBackgrounded { startWorldTracking(resetTracking: true) }
          continuation.resume()
        }
      }
    }

    private func runDuelFrameConfiguration(_ configuration: ARConfiguration, metadata: DuelFrameSessionConfiguration) {
      duelFrameState.generation += 1
      duelFrameState.cancelPendingCapture()
      duelFrameState.minimumFrameTimestamp = arSession.currentFrame?.timestamp ?? duelFrameState.lastPublishedTimestamp
      duelFrameState.lastPublishedTimestamp = -Double.infinity
      duelFrameState.lastTracking = nil
      duelFrameState.latestReferenceObservation = nil
      duelFrameState.pendingReferenceEvent = nil
      duelFrameState.lastFrameTimestamp = -Double.infinity
      duelFrameState.lastFrameCapturedAt = nil
      duelFrameState.configuration = metadata
      generation += 1
      visionInFlight = false
      lastVisionFrameTimestamp = -Double.infinity
      machine.sessionStarted(at: Date())
      publish(machine.snapshot)
      arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
      isSessionRunning = true
    }

    private func finishDuelMapCapture(_ result: Result<Data, DuelFrameFailure>, generation requestGeneration: Int) {
      guard let pending = duelFrameState.pendingCapture, pending.generation == requestGeneration else { return }
      duelFrameState.pendingCapture = nil
      guard duelFrameState.generation == requestGeneration, runRequested, !isBackgrounded else {
        pending.continuation.resume(throwing: DuelFrameFailure.operationSuperseded)
        return
      }
      switch result {
      case .success(let bytes): pending.continuation.resume(returning: bytes)
      case .failure(let failure): pending.continuation.resume(throwing: failure)
      }
    }

    private func invalidateDuelFrameSession(reason: DuelFrameFailure) {
      duelFrameState.generation += 1
      duelFrameState.cancelPendingCapture()
      guard let configuration = duelFrameState.configuration else { return }
      duelFrameState.hub.yield(DuelFrameObservation(epoch: configuration.epoch, frameID: configuration.frameID,
        phase: configuration.phase, tracking: .unavailable, isMapped: false, pose: nil, observedAt: Date(), failure: reason))
    }

    private func publishDuelFrameObservation(frame: ARFrame, configuration: DuelFrameSessionConfiguration) {
      let tracking: DuelFrameTracking
      switch frame.camera.trackingState {
      case .normal: tracking = .normal
      case .notAvailable: tracking = .unavailable
      case .limited(.relocalizing): tracking = .relocalizing
      case .limited: tracking = .limited
      }
      guard frame.timestamp - duelFrameState.lastPublishedTimestamp >= 0.05 || tracking != duelFrameState.lastTracking else { return }
      duelFrameState.lastPublishedTimestamp = frame.timestamp
      duelFrameState.lastTracking = tracking
      let now = Date()
      let queuedFrameAge = max(0, (arSession.currentFrame?.timestamp ?? frame.timestamp) - frame.timestamp)
      let capturedAt = now.addingTimeInterval(-queuedFrameAge)
      let columns = frame.camera.transform
      let raw = [columns.columns.0, columns.columns.1, columns.columns.2, columns.columns.3]
        .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
      let pose = tracking == .normal
        ? (try? ArenaRigidTransform.rigidApproximation(columnMajor: raw)).map {
          DuelFramePose(columnMajor: $0.columnMajor, capturedAt: capturedAt, frameTimestamp: frame.timestamp)
        } : nil
      duelFrameState.hub.yield(DuelFrameObservation(epoch: configuration.epoch, frameID: configuration.frameID,
        phase: configuration.phase, tracking: tracking, isMapped: frame.worldMappingStatus == .mapped,
        pose: pose, observedAt: now, failure: nil, referenceObservation: duelFrameState.latestReferenceObservation))
    }

    private func recordDuelReferenceAnchors(_ anchors: [ARAnchor]) {
      guard runRequested, isSessionRunning, !isBackgrounded,
        let configuration = duelFrameState.configuration, configuration.phase != .mapping,
        let reference = duelFrameState.reference, let frame = arSession.currentFrame,
        frame.timestamp > duelFrameState.minimumFrameTimestamp,
        case .normal = frame.camera.trackingState else { return }
      for anchor in anchors {
        guard let image = anchor as? ARImageAnchor, image.referenceImage.name == reference.id,
          let currentImage = frame.anchors.first(where: { $0.identifier == image.identifier }) as? ARImageAnchor
        else { continue }
        // The callback anchor triggers observation, but can have waited in the
        // delegate queue. Pair the current frame's matching anchor geometry with
        // that same frame's timestamp; never tag older geometry as current.
        let raw = currentImage.transform
        let matrix = [raw.columns.0, raw.columns.1, raw.columns.2, raw.columns.3]
          .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        // A genuine ARImageAnchor didAdd/didUpdate event is required. Its camera
        // timestamp is later resolved against the matching delivered sensor
        // frame, never renewed by reading a saved anchor or stamping Date().
        duelFrameState.pendingReferenceEvent = DuelFrameReferenceSensorEvent(referenceID: reference.id,
          mapFromImage: matrix, isTracked: image.isTracked && currentImage.isTracked, frameTimestamp: frame.timestamp)
      }
    }
  }

  struct ARCameraPreview: UIViewRepresentable {
    let targeting: ARVisionTargetingSession
    let fxEngine: LaserFXEngine?

    func makeUIView(context: Context) -> ARSCNView {
      let view = ARSCNView(frame: .zero)
      view.session = targeting.arSession
      view.scene = SCNScene()
      view.automaticallyUpdatesLighting = false
      view.backgroundColor = .black
      targeting.reassertSessionDelegate()
      fxEngine?.attach(to: view)
      return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
      if view.session !== targeting.arSession {
        view.session = targeting.arSession
      }
      targeting.reassertSessionDelegate()
      fxEngine?.attach(to: view)
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Void) {
      view.session = ARSession()
    }
  }

  /// Type-erased targeting preview for feature code that only owns the
  /// `TargetingSession` existential supplied by `AppEnvironment`.
  struct TargetingCameraPreview: View {
    let session: any TargetingSession

    @ViewBuilder
    var body: some View {
      if let liveSession = session as? ARVisionTargetingSession {
        ARCameraPreview(targeting: liveSession, fxEngine: nil)
      } else {
        Color.black
      }
    }
  }

  private final class TargetingSnapshotHub: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TargetingSnapshot
    private var continuations: [UUID: AsyncStream<TargetingSnapshot>.Continuation] = [:]

    init(initialSnapshot: TargetingSnapshot) {
      current = initialSnapshot
    }

    func currentSnapshot() -> TargetingSnapshot {
      lock.lock()
      defer { lock.unlock() }
      return current
    }

    func makeStream() -> AsyncStream<TargetingSnapshot> {
      let id = UUID()
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
        guard let self else {
          continuation.finish()
          return
        }
        lock.lock()
        continuations[id] = continuation
        let initialSnapshot = current
        lock.unlock()

        continuation.yield(initialSnapshot)
        continuation.onTermination = { [weak self] _ in
          self?.removeContinuation(id)
        }
      }
    }

    func yield(_ snapshot: TargetingSnapshot) {
      lock.lock()
      current = snapshot
      let activeContinuations = Array(continuations.values)
      lock.unlock()
      for continuation in activeContinuations {
        continuation.yield(snapshot)
      }
    }

    func finish() {
      lock.lock()
      let activeContinuations = Array(continuations.values)
      continuations.removeAll()
      lock.unlock()
      for continuation in activeContinuations {
        continuation.finish()
      }
    }

    private func removeContinuation(_ id: UUID) {
      lock.lock()
      continuations[id] = nil
      lock.unlock()
    }
  }
#endif

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
