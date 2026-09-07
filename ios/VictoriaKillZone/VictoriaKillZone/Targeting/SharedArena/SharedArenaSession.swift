#if DEBUG
import Foundation

struct SharedArenaSnapshot: Equatable, Sendable {
  let role: ArenaRole
  var phase: SharedOriginPhase = .idle
  var linkState: ArenaPeerLinkState = .idle
  var localTracking: ArenaLocalTracking = .notAvailable
  var originObserved = false
  var localArenaPosition: ArenaVector3?
  var peerReceiptAgeMs: Double?
  var peerSourceAgeMs: Double?
  var interPhoneDistanceMeters: Double?
  var elapsedMs: Int64 = 0
  var bytesIn = 0
  var bytesOut = 0
  var errorMessage: String?

  var instruction: String {
    if let errorMessage {return errorMessage}
    switch phase {
    case .idle: return "Starting the measurement experiment"
    case .interrupted: return "Experiment interrupted. Stop both phones and start with a new code."
    case .timedOut:
      return linkState == .connected
        ? "No shared measurements within 30 seconds. Try a scene with more detail."
        : "The other phone did not connect within 30 seconds. Check the code and network on both phones."
    case .stopped: return "Experiment stopped"
    case .searching, .observing: break
    }
    guard linkState == .connected else {return "Start the other phone with the same experiment code."}
    guard localTracking == .normal else {return "Move slowly and keep nearby detail in view."}
    guard originObserved else {return "Stand near each other and look at the same fixed scene."}
    return interPhoneDistanceMeters == nil ? "Shared origin observed. Waiting for fresh phone measurements."
      : "Phone measurements visible. Check them against physical measurements."
  }
}

#if os(iOS) && canImport(ARKit)
import ARKit
import AVFoundation
import Combine

/// DEBUG world-tracking adapter for a temporary shared-origin measurement.
/// One ARSession, no body configuration, production readiness, shots or game client.
final class SharedArenaSession: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
  @Published private(set) var snapshot: SharedArenaSnapshot
  let arSession = ARSession()
  let role: ArenaRole
  private let credentials: SharedOriginCredentials
  private let link: any ArenaPeerLinking
  private let queue = DispatchQueue(label: "com.victoriakillzone.shared-origin", qos: .userInteractive)
  private let lock = NSLock()
  private var state: SharedArenaSnapshot
  private var policy: SharedOriginPolicy
  private var running = false
  private var generation: UInt64 = 0
  private var peerSessionID: UUID?
  private var originAnchor: ARAnchor?
  private var pendingCollaboration: [Data] = []
  private var pendingCollaborationBytes = 0
  private var sequence: UInt64 = 0
  private var lastPoseSentMs: Double = 0
  private var lastFrameTimestamp = -Double.infinity
  private var startedAtMs: Double = 0
  private var timer: DispatchSourceTimer?
  private var renderTransform: ArenaRigidTransform?
  private var renderExpiresAtMs: Double = 0
  private var renderOriginID: UUID?
  private var log = SharedOriginMeasurementLog()

  init(role: ArenaRole, credentials: SharedOriginCredentials, link: (any ArenaPeerLinking)? = nil) {
    self.role = role; self.credentials = credentials
    self.link = link ?? ArenaPeerLinkFactory.make(matchId: credentials.runID.uuidString,
      playerId: UUID().uuidString, joinSecret: credentials.joinSecret)
    policy = SharedOriginPolicy(runID: credentials.runID)
    state = SharedArenaSnapshot(role: role); snapshot = state
    super.init()
    reassertSessionDelegate()
    self.link.onStateChange = { [weak self] in self?.receiveLinkState($0) }
    self.link.onMessage = { [weak self] message, arrival in
      guard let self else {return}
      queue.async {self.handle(message, receivedAtMs: Double(arrival))}
    }
  }

  deinit {timer?.cancel(); link.stop(); arSession.pause()}

  /// Renderer reads local coordinates, already converted exactly once from the arena.
  var peerMarkerTransform: ArenaRigidTransform? {
    lock.withLock {Self.nowMs <= renderExpiresAtMs ? renderTransform : nil}
  }
  var originAnchorID: UUID? {lock.withLock {renderOriginID}}

  func reassertSessionDelegate() {arSession.delegate = self; arSession.delegateQueue = queue}

  func start() async {
    let token: UInt64? = await withCheckedContinuation {continuation in
      queue.async { [self] in
        guard generation == 0 else {continuation.resume(returning: nil); return}
        generation += 1; running = true
        continuation.resume(returning: generation)
      }
    }
    guard let token else {return}
    let permitted = await AVCaptureDevice.requestAccess(for: .video)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        defer {continuation.resume()}
        guard running, generation == token else {return}
        guard permitted, ARWorldTrackingConfiguration.isSupported else {
          fail(permitted ? "World tracking is unavailable on this phone." : "Allow camera access in Settings, then start a new experiment.")
          return
        }
        startedAtMs = Self.nowMs
        do {try policy.begin(epoch: 1, nowMs: startedAtMs)} catch {fail("Start a new experiment."); return}
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isCollaborationEnabled = true
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        link.start(role: role)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
        publish()
      }
    }
  }

  func stop() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        let shouldPause = running
        generation += 1; running = false
        timer?.cancel(); timer = nil
        policy.invalidate(.stopped); peerSessionID = nil; originAnchor = nil
        pendingCollaboration.removeAll(); pendingCollaborationBytes = 0
        if shouldPause {arSession.pause()}
        link.stop(); publish()
        continuation.resume()
      }
    }
  }

  func exportLog() throws -> URL {
    let captured = lock.withLock {log}
    return try captured.export()
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running, session === arSession else {return}
    state.localTracking = Self.tracking(frame.camera.trackingState)
    if state.localTracking != .normal {revokeLocalRendering()}
    guard frame.timestamp > lastFrameTimestamp else {return}
    let now = Self.nowMs
    lastFrameTimestamp = frame.timestamp
    guard let captured = SharedOriginSensorTime.capturedUptimeMs(frameTimestamp: frame.timestamp, nowMs: now) else {
      revokeLocalRendering(); return
    }
    if let originID = policy.originID {
      let anchor = frame.anchors.first {$0.identifier == originID}
      let localFromArena = anchor.flatMap {try? ArenaRigidTransform.rigidApproximation(columnMajor: $0.transform.columnMajor)}
      let camera = try? ArenaRigidTransform.rigidApproximation(columnMajor: frame.camera.transform.columnMajor)
      let accepted = policy.observeLocal(runID: credentials.runID, epoch: policy.epoch, originID: originID,
        localFromArena: localFromArena, localFromPhone: camera, trackingNormal: state.localTracking == .normal,
        frameTimestamp: frame.timestamp, capturedUptimeMs: captured, nowMs: now)
      if !accepted {revokeLocalRendering()}
    }
    if now - lastPoseSentMs >= 50, let originID = policy.originID,
      let local = policy.localMeasurement(at: now), peerSessionID != nil {
      lastPoseSentMs = now; sequence += 1
      send(.pose(originID: originID, sequence: sequence, capturedUptimeMs: local.capturedUptimeMs,
        sourceAgeMs: now - local.capturedUptimeMs, trackingNormal: true, arenaFromPhone: local.arenaFromPhone.columnMajor))
    }
  }

  func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
    guard running, session === arSession, policy.phase == .searching || policy.phase == .observing,
      let archived = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true),
      archived.count <= DuelFrameMap.maximumBytes else {return}
    guard state.linkState == .connected, peerSessionID != nil else {
      // Critical pre-link map updates must arrive in order; optional updates can wait.
      guard data.priority == .critical else {return}
      guard pendingCollaboration.count < 32, pendingCollaborationBytes + archived.count <= DuelFrameMap.maximumBytes else {
        fail("Start both phones closer together with a new code."); return
      }
      pendingCollaboration.append(archived); pendingCollaborationBytes += archived.count
      return
    }
    link.send(.collaboration(archived))
  }

  func session(_ session: ARSession, didFailWithError error: Error) {fail("Camera tracking failed. Stop both phones and start a new experiment.")}
  func sessionWasInterrupted(_ session: ARSession) {fail("Camera interrupted. Stop both phones and start with a new code.")}
  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {false}

  private func receiveLinkState(_ value: ArenaPeerLinkState) {
    queue.async { [self] in
      guard running else {return}
      // Remote error text is not exported or displayed.
      if case .failed = value {state.linkState = .failed("Link unavailable")} else {state.linkState = value}
      if value == .connected {
        send(.hello(sessionID: arSession.identifier, role: role))
      } else if peerSessionID != nil {
        fail("Connection interrupted. Stop both phones and start with a new code.")
      }
      publish()
    }
  }

  private func handle(_ message: ArenaLinkMessage, receivedAtMs: Double) {
    guard running, policy.phase == .searching || policy.phase == .observing else {return}
    switch message {
    case .experiment(let bytes):
      guard let message = try? SharedOriginWireMessage.decode(bytes),
        message.runID == credentials.runID, message.epoch == policy.epoch else {return}
      switch message.body {
      case .hello(let sessionID, let peerRole):
        guard peerRole != role, sessionID != arSession.identifier,
          peerSessionID == nil || peerSessionID == sessionID else {
          fail("The other phone belongs to a different experiment. Start both phones again."); return
        }
        peerSessionID = sessionID
        for archived in pendingCollaboration {link.send(.collaboration(archived))}
        pendingCollaboration.removeAll(); pendingCollaborationBytes = 0
        if role == .host, originAnchor == nil {
          let anchor = ARAnchor(name: "shared-origin-\(UUID().uuidString)", transform: matrix_identity_float4x4)
          originAnchor = anchor
          policy.adoptOrigin(runID: credentials.runID, epoch: policy.epoch, originID: anchor.identifier)
          arSession.add(anchor: anchor)
        }
        if let originAnchor {send(.origin(originID: originAnchor.identifier))}
      case .origin(let originID):
        guard role == .guest, peerSessionID != nil else {return}
        if !policy.adoptOrigin(runID: message.runID, epoch: message.epoch, originID: originID) {
          fail("The shared origin changed. Start both phones again.")
        }
      case .pose:
        guard peerSessionID != nil else {return}
        _ = policy.receivePose(message, at: receivedAtMs, evaluatedAt: Self.nowMs)
      }
    case .collaboration(let bytes):
      guard peerSessionID != nil, !bytes.isEmpty, bytes.count <= DuelFrameMap.maximumBytes,
        let collaboration = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from: bytes) else {return}
      arSession.update(with: collaboration)
    default: break // Legacy hello, raw poses, maps and all shots are outside this experiment.
    }
  }

  private func send(_ body: SharedOriginWireMessage.Body) {
    guard let bytes = try? SharedOriginWireMessage(runID: credentials.runID, epoch: policy.epoch, body: body).encoded() else {return}
    link.send(.experiment(bytes))
  }

  private func tick() {
    guard running else {return}
    policy.tick(nowMs: Self.nowMs)
    if policy.phase == .timedOut {arSession.pause(); link.stop(); running = false; timer?.cancel(); timer = nil}
    publish()
  }

  private func revokeLocalRendering() {
    policy.revokeLocalMeasurement()
    lock.withLock {renderTransform = nil; renderExpiresAtMs = 0}
  }

  private func fail(_ message: String) {
    guard running else {return}
    running = false; generation += 1
    policy.invalidate(); state.errorMessage = message
    pendingCollaboration.removeAll(); pendingCollaborationBytes = 0
    timer?.cancel(); timer = nil; arSession.pause(); link.stop(); publish()
  }

  private func publish() {
    let now = Self.nowMs
    state.phase = policy.phase
    state.originObserved = policy.localMeasurement(at: now) != nil
    state.localArenaPosition = policy.localMeasurement(at: now)?.arenaFromPhone.translation
    state.peerReceiptAgeMs = policy.peerReceiptAge(at: now)
    state.peerSourceAgeMs = state.peerReceiptAgeMs == nil ? nil : policy.peerSourceAgeMs
    let peer = policy.localFromPeer(at: now)
    if let local = policy.localMeasurement(at: now), let remote = policy.peerArenaFromPhone, peer != nil {
      state.interPhoneDistanceMeters = (remote.translation - local.arenaFromPhone.translation).length
    } else {state.interPhoneDistanceMeters = nil}
    state.elapsedMs = startedAtMs > 0 ? Int64(max(0, now - startedAtMs)) : 0
    state.bytesIn = link.stats.bytesIn; state.bytesOut = link.stats.bytesOut
    let value = state
    lock.withLock {
      renderTransform = peer; renderOriginID = policy.originID
      renderExpiresAtMs = min((policy.measurement?.capturedUptimeMs ?? 0) + SharedOriginPolicy.maximumSampleAgeMs,
        (policy.peerReceivedAtMs ?? 0) + SharedOriginPolicy.maximumSampleAgeMs)
      log.append(value)
    }
    DispatchQueue.main.async { [weak self] in self?.snapshot = value }
  }

  private static var nowMs: Double {ProcessInfo.processInfo.systemUptime * 1_000}
  private static func tracking(_ state: ARCamera.TrackingState) -> ArenaLocalTracking {
    switch state {
    case .normal: .normal
    case .notAvailable: .notAvailable
    case .limited(let reason):
      switch reason {
      case .initializing: .limited(.initializing)
      case .excessiveMotion: .limited(.excessiveMotion)
      case .insufficientFeatures: .limited(.insufficientFeatures)
      case .relocalizing: .limited(.relocalizing)
      @unknown default: .notAvailable
      }
    }
  }
}

extension simd_float4x4 {
  var columnMajor: [Double] {
    [columns.0, columns.1, columns.2, columns.3].flatMap {[Double($0.x), Double($0.y), Double($0.z), Double($0.w)]}
  }
}
#endif
#endif
