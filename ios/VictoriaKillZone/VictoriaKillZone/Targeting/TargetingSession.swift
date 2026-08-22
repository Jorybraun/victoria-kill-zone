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

  init(
    capturedAt: Date,
    bodyConfidence: Double,
    headConfidence: Double? = nil,
    torsoConfidence: Double?,
    bodyBounds: NormalizedTargetingRect,
    torsoBounds: NormalizedTargetingRect?,
    headRegion: NormalizedTargetingEllipse? = nil,
    torsoRegion: NormalizedTargetingPolygon? = nil
  ) {
    self.capturedAt = capturedAt
    self.bodyConfidence = bodyConfidence
    self.headConfidence = headConfidence
    self.torsoConfidence = torsoConfidence
    self.bodyBounds = bodyBounds
    self.torsoBounds = torsoBounds
    self.headRegion = headRegion
    self.torsoRegion = torsoRegion
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

  /// Compatibility/readability conveniences for HUD and fire-path callers.
  var hitZone: TargetingHitZone? { aimClaim?.zone }
  var hitConfidence: Double { aimClaim?.confidence ?? 0 }

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
    poseStaleAfter: TimeInterval
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
      poseStaleAfter: TargetingThresholds.phaseZero.poseStaleAfter
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
    let reportsTorso = reportsBody && observation?.torsoRegion != nil
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
      poseStaleAfter: thresholds.poseStaleAfter
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

    override init() {
      let now = Date()
      let initialSnapshot = TargetingSnapshot.unavailable(at: now)
      let supported = ARWorldTrackingConfiguration.isSupported

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
    }

    func snapshots() -> AsyncStream<TargetingSnapshot> {
      snapshotHub.makeStream()
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
      generation += 1
      visionInFlight = false
      lastVisionFrameTimestamp = -Double.infinity
      machine.sessionStarted(at: Date())
      publish(machine.snapshot)

      let configuration = ARWorldTrackingConfiguration()
      configuration.worldAlignment = .gravity
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
      let now = Date()
      machine.cameraBecameReady(at: now)
      machine.updateCameraRay(Self.cameraRay(from: frame, capturedAt: now), at: now)
      machine.tick(at: now)
      publish(machine.snapshot)

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
  }

  extension ARVisionTargetingSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      process(frame: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
      generation += 1
      visionInFlight = false
      isSessionRunning = false
      machine.sessionBecameUnavailable(at: Date())
      publish(machine.snapshot)
    }

    func sessionWasInterrupted(_ session: ARSession) {
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
  }

  struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession
    let fxEngine: LaserFXEngine?

    func makeUIView(context: Context) -> ARSCNView {
      let view = ARSCNView(frame: .zero)
      view.session = session
      view.scene = SCNScene()
      view.automaticallyUpdatesLighting = false
      view.backgroundColor = .black
      fxEngine?.attach(to: view)
      return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
      if view.session !== session {
        view.session = session
      }
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
        ARCameraPreview(session: liveSession.arSession, fxEngine: nil)
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
