import Foundation

// MARK: - Shared-arena session snapshot (KIL-20)
//
// Everything the harness HUD renders, published from the session adapter. Kept
// platform-neutral so the view layer and future tests can read it without ARKit.

struct SharedArenaPeerStatus: Equatable, Sendable {
  let playerId: String
  let sequence: Int64
  let tracking: ArenaTrackingQuality
  let ageMs: Int64
  let arenaFromPhone: ArenaRigidTransform
}

/// Tracer counters and the last fire outcome for the HUD.
struct SharedArenaTracerStatus: Equatable, Sendable {
  var predictedDrawn = 0
  var incomingDrawn = 0
  var duplicatesIgnored = 0
  var droppedWhileUnlocked = 0
  var lastRefusal: ArenaFireRefusal?
  var lastEvent: String?
  var lastEventAtMs: Int64?
}

struct SharedArenaSnapshot: Equatable, Sendable {
  var role: ArenaRole
  var method: ArenaFrameMethod
  var linkState: ArenaPeerLinkState = .idle
  var localTracking: ArenaLocalTracking = .notAvailable
  var mappingStatus: ArenaMappingStatus = .notAvailable
  var lockState: ArenaLockState = .aligning(.awaitingPeer)
  var mergeObserved = false
  var peer: SharedArenaPeerStatus?
  var residual: ArenaAlignmentResidual?
  var interPhoneDistanceMeters: Double?
  var localAnchorNames: [String] = []
  var sharedAnchorNames: [String] = []
  var worldMapBytesSent: Int?
  var worldMapBytesReceived: Int?
  var metrics: ArenaMetricsSummary = .empty
  var linkStats = ArenaPeerLinkStats()
  var thermalState = "nominal"
  var errorMessage: String?
  var elapsedMs: Int64 = 0
  var tracers = SharedArenaTracerStatus()

  /// Calibration ritual copy from the research §6.2; pending design freeze.
  var ritualStep: String {
    if let errorMessage { return "STOPPED — \(errorMessage)" }
    switch linkState {
    case .idle: return "START THE LINK ON BOTH PHONES"
    case .advertising, .browsing, .connecting: return "WAITING FOR THE OTHER PHONE"
    case .failed: return "LINK FAILED — RESTART BOTH PHONES"
    case .connected: break
    }
    if localTracking != .normal { return "HOLD STILL — CAMERA TRACKING LIMITED" }
    if mappingStatus.rank < ArenaMappingStatus.mapped.rank, !lockState.isLocked {
      return "HUDDLE — STAND SIDE BY SIDE, PAN SLOWLY ACROSS THE SAME STRUCTURE"
    }
    if !mergeObserved {
      return method == .collaborative
        ? "HUDDLE — KEEP BOTH CAMERAS ON THE SAME SCENE UNTIL MERGE"
        : (role == .host ? "SHARE THE MAP, THEN HOLD STILL" : "WAITING FOR HOST MAP — HOLD STILL")
    }
    switch lockState {
    case .lockReady: return "SPATIAL LOCK READY — WALK TO THE 3 M MARKS"
    case .aligning: return "FACE-OFF — 3 M APART, AIM AT EACH OTHER, HOLD 3 S"
    case .trackingLost: return "TRACKING LOST — FIRE LOCKED — RE-AIM TO RE-LOCK"
    }
  }
}

#if os(iOS) && canImport(ARKit)
  import ARKit
  import Combine

  /// ARKit adapter for the two-phone Shared Arena Frame proof.
  ///
  /// Owns one `ARSession`, one `ArenaPeerLinking`, the peer pose history, the
  /// lock policy, and the measurement log. Runs either method behind the same
  /// surface:
  /// - `.collaborative`: `isCollaborationEnabled`; collaboration data relayed
  ///   over the link; `ARParticipantAnchor` proves the merge and gives the
  ///   observed-vs-reported residual.
  /// - `.worldMap`: host captures `ARWorldMap` once mapped and sends it; guest
  ///   relocalizes with `initialWorldMap`. No residual signal exists here — the
  ///   tape measure is the residual.
  ///
  /// Spatial firing stays disabled; nothing here touches Convex or gameplay.
  final class SharedArenaSession: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
    static let poseSendIntervalMs: Int64 = 50
    static let logIntervalMs: Int64 = 100
    static let peerHistoryCapacity = 64
    static let anchorNames = ["arena-anchor-0", "arena-anchor-1", "arena-anchor-2"]
    static let maxLogLines = 20_000

    @Published private(set) var snapshot: SharedArenaSnapshot

    let arSession = ARSession()
    let playerId: String
    let role: ArenaRole
    let method: ArenaFrameMethod

    /// Latest peer pose for the renderer, in this phone's arena frame. Read from
    /// the SceneKit render thread, so it is a lock-guarded copy, not `state`.
    var peerProxyTransform: ArenaRigidTransform? {
      lock.withLock { renderPeerTransform }
    }

    /// Live tracer segments for the renderer; lock-guarded copy like the proxy.
    var activeTracers: [ArenaTracerSegment] {
      lock.withLock { renderTracers }
    }

    private let link: any ArenaPeerLinking
    private let sessionQueue = DispatchQueue(
      label: "com.victoriakillzone.arena.session",
      qos: .userInteractive
    )
    private let lock = NSLock()
    private var state: SharedArenaSnapshot
    private var policy = SharedArenaLockPolicy()
    private var metrics = ArenaFrameMetrics()
    private var peerHistory = ArenaPoseHistory(capacity: SharedArenaSession.peerHistoryCapacity)
    private var latestPeer: ArenaPeerSample?
    private var latestPeerArrivalMs: Int64?
    private var renderPeerTransform: ArenaRigidTransform?
    private var renderTracers: [ArenaTracerSegment] = []
    private var fireGate = ArenaTracerFireGate()
    private var tracerLedger = ArenaTracerLedger()
    private var participantTransform: ArenaRigidTransform?
    private var localCameraTransform: ArenaRigidTransform?
    private var ownSequence: Int64 = 0
    private var lastPoseSentMs: Int64 = 0
    private var lastLogMs: Int64 = 0
    private var startedAtMs: Int64 = 0
    private var logLines: [String] = [ArenaLogRecord.csvHeader]
    private var mapShared = false
    private var awaitingRelocalization = false
    private var isRunning = false

    init(role: ArenaRole, method: ArenaFrameMethod, link: any ArenaPeerLinking = ArenaPeerLink()) {
      self.role = role
      self.method = method
      self.link = link
      playerId = "\(role.rawValue)-\(UUID().uuidString.prefix(6).lowercased())"
      state = SharedArenaSnapshot(role: role, method: method)
      snapshot = state
      super.init()

      arSession.delegate = self
      arSession.delegateQueue = sessionQueue
      link.onStateChange = { [weak self] linkState in
        self?.sessionQueue.async { self?.handleLinkState(linkState) }
      }
      link.onMessage = { [weak self] message, arrivalMs in
        self?.sessionQueue.async { self?.handle(message, arrivalMs: arrivalMs) }
      }
    }

    deinit {
      link.stop()
      arSession.pause()
    }

    /// `ARSCNView` replaces the session delegate when handed the session.
    func reassertSessionDelegate() {
      arSession.delegate = self
      arSession.delegateQueue = sessionQueue
    }

    func start() {
      sessionQueue.async { [self] in
        guard !isRunning else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
          state.errorMessage = "WORLD TRACKING UNSUPPORTED"
          publish()
          return
        }
        isRunning = true
        startedAtMs = ArenaClock.nowMs()
        run(initialWorldMap: nil, resetTracking: true)
        link.start(role: role)
        publish()
      }
    }

    func stop() {
      sessionQueue.async { [self] in
        isRunning = false
        link.stop()
        arSession.pause()
        state.linkState = .idle
        publish()
      }
    }

    /// World-map method, host only. Automatic on first `.mapped`; the button
    /// lets the operator re-share after moving to a new spot.
    func shareWorldMap() {
      sessionQueue.async { [self] in
        guard role == .host, method == .worldMap, isRunning else { return }
        arSession.getCurrentWorldMap { [weak self] map, error in
          guard let self else { return }
          sessionQueue.async {
            guard let map else {
              self.state.errorMessage = "MAP CAPTURE FAILED: \(error?.localizedDescription ?? "unknown")"
              self.publish()
              return
            }
            do {
              let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
              self.link.send(.worldMap(data))
              self.link.send(.anchorSet(self.namedAnchors()))
              self.mapShared = true
              self.state.worldMapBytesSent = data.count
              self.publish()
            } catch {
              self.state.errorMessage = "MAP ARCHIVE FAILED"
              self.publish()
            }
          }
        }
      }
    }

    /// Trigger press. Fires whenever local tracking is normal and off cooldown
    /// (a lock is not permission to fire — requirements §3A.1); draws the
    /// shooter's predicted tracer and broadcasts one `shotTracer` so every other
    /// member draws exactly one incoming tracer. No verdict, damage, or ammo.
    func fire() {
      sessionQueue.async { [self] in
        let nowMs = ArenaClock.nowMs()
        if let refusal = fireGate.refusal(
          localTracking: state.localTracking,
          hasLocalPose: localCameraTransform != nil,
          nowMs: nowMs
        ) {
          state.tracers.lastRefusal = refusal
          state.tracers.lastEvent = "FIRE LOCKED — \(refusal.rawValue)"
          state.tracers.lastEventAtMs = nowMs
          publish()
          return
        }
        guard let camera = localCameraTransform,
          let ray = try? ArenaShotRay(
            origin: camera.translation,
            direction: camera.applying(toDirection: ArenaVector3(x: 0, y: 0, z: -1)),
            firedAtMs: max(1, nowMs)
          )
        else { return }
        let sequence = fireGate.recordFire(nowMs: nowMs)
        let tracer = ArenaShotTracer(
          shotId: ArenaTracerFireGate.shotId(shooterPlayerId: playerId, sequence: sequence),
          shooterPlayerId: playerId,
          ray: ray
        )
        tracerLedger.present(own: tracer, nowMs: nowMs)
        link.send(.shotTracer(tracer))
        state.tracers.lastRefusal = nil
        state.tracers.lastEvent = "SHOT PREDICTED"
        state.tracers.lastEventAtMs = nowMs
        publish()
      }
    }

    /// Writes the measurement log to a temporary CSV and returns its URL.
    func exportLog() throws -> URL {
      let lines = lock.withLock { logLines }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kil20-\(role.rawValue)-\(method.rawValue)-\(Int(Date().timeIntervalSince1970)).csv")
      try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
      return url
    }

    // MARK: ARSession lifecycle

    private func run(initialWorldMap: ARWorldMap?, resetTracking: Bool) {
      let configuration = ARWorldTrackingConfiguration()
      configuration.worldAlignment = .gravity
      configuration.isCollaborationEnabled = method == .collaborative
      configuration.initialWorldMap = initialWorldMap
      var options: ARSession.RunOptions = []
      if resetTracking { options.formUnion([.resetTracking, .removeExistingAnchors]) }
      arSession.run(configuration, options: options)
      if role == .host, resetTracking {
        placeArenaAnchors()
      }
    }

    /// Three non-collinear anchors 1.5 m in front of the host at start. They
    /// travel to the guest through collaboration data or inside the world map;
    /// the explicit `anchorSet` message lets the guest verify the same IDs.
    private func placeArenaAnchors() {
      let offsets: [SIMD3<Float>] = [
        SIMD3(0, 0, -1.5),
        SIMD3(1.0, 0, -1.5),
        SIMD3(0.5, 0, -2.5),
      ]
      for (name, offset) in zip(Self.anchorNames, offsets) {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(offset.x, offset.y, offset.z, 1)
        arSession.add(anchor: ARAnchor(name: name, transform: transform))
      }
    }

    private func namedAnchors() -> [ArenaNamedAnchor] {
      (arSession.currentFrame?.anchors ?? []).compactMap { anchor in
        guard let name = anchor.name, Self.anchorNames.contains(name),
          let transform = try? ArenaRigidTransform.rigidApproximation(columnMajor: anchor.transform.columnMajor)
        else { return nil }
        return ArenaNamedAnchor(name: name, transform: transform)
      }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
      let nowMs = ArenaClock.nowMs()
      let previousTracking = state.localTracking
      state.localTracking = Self.tracking(from: frame.camera.trackingState)
      state.mappingStatus = Self.mapping(from: frame.worldMappingStatus)
      state.localAnchorNames = frame.anchors.compactMap(\.name).filter(Self.anchorNames.contains).sorted()
      localCameraTransform = try? ArenaRigidTransform.rigidApproximation(
        columnMajor: frame.camera.transform.columnMajor
      )

      if awaitingRelocalization, previousTracking != .normal, state.localTracking == .normal {
        awaitingRelocalization = false
        state.mergeObserved = true
      }
      if role == .host, method == .worldMap, !mapShared, state.mappingStatus == .mapped,
        state.linkState == .connected
      {
        shareWorldMap()
      }

      if nowMs - lastPoseSentMs >= Self.poseSendIntervalMs {
        lastPoseSentMs = nowMs
        sendOwnPose(nowMs: nowMs)
        evaluateLock(nowMs: nowMs)
      }
      if nowMs - lastLogMs >= Self.logIntervalMs {
        lastLogMs = nowMs
        appendLog(nowMs: nowMs)
        publish()
      }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
      noteAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
      noteAnchors(anchors)
    }

    func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
      guard method == .collaborative, state.linkState == .connected else { return }
      guard let archived = try? NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
      else { return }
      link.send(.collaboration(archived))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
      state.errorMessage = "AR SESSION FAILED: \(error.localizedDescription)"
      publish()
    }

    func sessionWasInterrupted(_ session: ARSession) {
      state.localTracking = .notAvailable
      evaluateLock(nowMs: ArenaClock.nowMs())
      publish()
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    private func noteAnchors(_ anchors: [ARAnchor]) {
      for anchor in anchors {
        guard let participant = anchor as? ARParticipantAnchor else { continue }
        participantTransform = try? ArenaRigidTransform.rigidApproximation(
          columnMajor: participant.transform.columnMajor
        )
        if !state.mergeObserved {
          state.mergeObserved = true
          publish()
        }
      }
    }

    // MARK: Peer channel

    private func handleLinkState(_ linkState: ArenaPeerLinkState) {
      state.linkState = linkState
      if linkState == .connected {
        link.send(.hello(playerId: playerId, role: role, method: method))
        if role == .host {
          link.send(.anchorSet(namedAnchors()))
          if method == .worldMap { mapShared = false }
        }
        if method == .worldMap, role == .host { state.mergeObserved = true }
      } else {
        // Any link change invalidates the peer: fail closed and restart continuity.
        latestPeer = nil
        latestPeerArrivalMs = nil
        peerHistory = ArenaPoseHistory(capacity: Self.peerHistoryCapacity)
        metrics.resetPeerSequence()
        if method == .collaborative { state.mergeObserved = false }
        state.peer = nil
        state.residual = nil
        state.interPhoneDistanceMeters = nil
      }
      evaluateLock(nowMs: ArenaClock.nowMs())
      publish()
    }

    private func handle(_ message: ArenaLinkMessage, arrivalMs: Int64) {
      switch message {
      case .hello(_, let peerRole, let peerMethod):
        if peerRole == role || peerMethod != method {
          state.errorMessage = "PEER MISMATCH: \(peerRole.rawValue)/\(peerMethod.rawValue)"
          link.stop()
          publish()
        }

      case .poseSample(let sample):
        guard metrics.recordPeerSample(sequence: sample.sequence, arrivalMs: arrivalMs) else { return }
        latestPeer = sample
        latestPeerArrivalMs = arrivalMs
        do {
          try peerHistory.append(sample.poseSample)
        } catch ArenaPrototypeError.trackingLost {
          // History already cleared by the append; the policy sees peerTracking.
        } catch {
          // Sequence already advanced past metrics' gate, so only a peer whose
          // clock went backwards lands here. Drop the sample; keep the history.
        }

      case .collaboration(let data):
        guard method == .collaborative,
          let collaboration = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARSession.CollaborationData.self, from: data
          )
        else { return }
        arSession.update(with: collaboration)

      case .worldMap(let data):
        guard method == .worldMap, role == .guest else { return }
        guard let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
          state.errorMessage = "WORLD MAP UNARCHIVE FAILED"
          publish()
          return
        }
        state.worldMapBytesReceived = data.count
        state.mergeObserved = false
        awaitingRelocalization = true
        run(initialWorldMap: map, resetTracking: true)

      case .anchorSet(let anchors):
        state.sharedAnchorNames = anchors.map(\.name).sorted()

      case .shotTracer(let tracer):
        guard tracer.shooterPlayerId != playerId else { return }
        let before = tracerLedger.incomingDrawn
        tracerLedger.present(incoming: tracer, lockState: state.lockState, nowMs: arrivalMs)
        if tracerLedger.incomingDrawn > before {
          state.tracers.lastEvent = "INCOMING SHOT"
          state.tracers.lastEventAtMs = arrivalMs
        }
        publish()
      }
    }

    private func sendOwnPose(nowMs: Int64) {
      guard state.linkState == .connected else { return }
      let transform = localCameraTransform ?? .identity
      ownSequence += 1
      let sample = ArenaPeerSample(
        playerId: playerId,
        sequence: ownSequence,
        timestampMs: max(1, nowMs),
        tracking: state.localTracking.quality,
        arenaFromPhone: transform
      )
      link.send(.poseSample(sample))
    }

    // MARK: Lock evaluation and logging

    private func evaluateLock(nowMs: Int64) {
      var peerObservation: ArenaPeerObservation?
      if let latestPeer, let latestPeerArrivalMs {
        let ageMs = max(0, nowMs - latestPeerArrivalMs)
        var residual: ArenaAlignmentResidual?
        if method == .collaborative, let participantTransform {
          residual = ArenaRigidTransform.residual(reported: latestPeer.arenaFromPhone, observed: participantTransform)
        }
        peerObservation = ArenaPeerObservation(tracking: latestPeer.tracking, ageMs: ageMs, residual: residual)
        state.peer = SharedArenaPeerStatus(
          playerId: latestPeer.playerId,
          sequence: latestPeer.sequence,
          tracking: latestPeer.tracking,
          ageMs: ageMs,
          arenaFromPhone: latestPeer.arenaFromPhone
        )
        state.residual = residual
        if let localCameraTransform {
          state.interPhoneDistanceMeters =
            (latestPeer.arenaFromPhone.translation - localCameraTransform.translation).length
        }
      }

      let decision = policy.evaluate(
        ArenaLockObservation(
          localTracking: state.localTracking,
          mappingStatus: state.mappingStatus,
          mergeObserved: state.mergeObserved,
          peer: peerObservation
        ),
        nowMs: nowMs
      )
      if decision.clearsHistory {
        peerHistory = ArenaPoseHistory(capacity: Self.peerHistoryCapacity)
        metrics.recordLockLoss()
      }
      if let recoveryMs = decision.recoveryMs {
        metrics.recordRecovery(ms: recoveryMs)
      }
      state.lockState = decision.state
    }

    private func appendLog(nowMs: Int64) {
      state.elapsedMs = nowMs - startedAtMs
      state.metrics = metrics.summary(nowMs: nowMs)
      state.linkStats = link.stats
      state.thermalState = Self.thermalLabel(ProcessInfo.processInfo.thermalState)
      let record = ArenaLogRecord(
        elapsedMs: state.elapsedMs,
        role: role,
        method: method,
        localTracking: state.localTracking,
        mappingStatus: state.mappingStatus,
        lockState: state.lockState,
        peerSequence: state.peer?.sequence,
        peerAgeMs: state.peer?.ageMs,
        interPhoneDistanceMeters: state.interPhoneDistanceMeters,
        residual: state.residual,
        bytesIn: state.linkStats.bytesIn,
        bytesOut: state.linkStats.bytesOut,
        thermalState: state.thermalState
      )
      lock.withLock {
        if logLines.count < Self.maxLogLines { logLines.append(record.csvLine) }
      }
    }

    private func publish() {
      let nowMs = ArenaClock.nowMs()
      tracerLedger.expire(nowMs: nowMs)
      state.tracers.predictedDrawn = tracerLedger.predictedDrawn
      state.tracers.incomingDrawn = tracerLedger.incomingDrawn
      state.tracers.duplicatesIgnored = tracerLedger.duplicatesIgnored
      state.tracers.droppedWhileUnlocked = tracerLedger.droppedWhileUnlocked
      let value = state
      let renderTransform = state.lockState.isLocked ? latestPeer?.arenaFromPhone : nil
      let tracers = tracerLedger.active
      lock.withLock {
        renderPeerTransform = renderTransform
        renderTracers = tracers
      }
      DispatchQueue.main.async { [weak self] in
        self?.snapshot = value
      }
    }

    // MARK: ARKit → vocabulary

    private static func tracking(from trackingState: ARCamera.TrackingState) -> ArenaLocalTracking {
      switch trackingState {
      case .normal: .normal
      case .notAvailable: .notAvailable
      case .limited(let reason):
        switch reason {
        case .initializing: .limited(.initializing)
        case .excessiveMotion: .limited(.excessiveMotion)
        case .insufficientFeatures: .limited(.insufficientFeatures)
        case .relocalizing: .limited(.relocalizing)
        @unknown default: .limited(.initializing)
        }
      }
    }

    private static func mapping(from status: ARFrame.WorldMappingStatus) -> ArenaMappingStatus {
      switch status {
      case .notAvailable: .notAvailable
      case .limited: .limited
      case .extending: .extending
      case .mapped: .mapped
      @unknown default: .notAvailable
      }
    }

    private static func thermalLabel(_ thermal: ProcessInfo.ThermalState) -> String {
      switch thermal {
      case .nominal: "nominal"
      case .fair: "fair"
      case .serious: "serious"
      case .critical: "critical"
      @unknown default: "unknown"
      }
    }
  }

  extension simd_float4x4 {
    var columnMajor: [Double] {
      [columns.0, columns.1, columns.2, columns.3].flatMap { column in
        [Double(column.x), Double(column.y), Double(column.z), Double(column.w)]
      }
    }
  }
#endif
