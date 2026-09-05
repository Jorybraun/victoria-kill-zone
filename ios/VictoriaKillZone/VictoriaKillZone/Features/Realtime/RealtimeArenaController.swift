import Combine
import Foundation

struct RealtimeAssociatedBody: Equatable {
  let association: RealtimeBodyAssociation
  let skeleton: TargetingSkeleton
}
struct RealtimeHitFeedback: Identifiable {
  let id: Int
  let targetPlayerID: String?
  let zone: TargetingHitZone?
  let damage: Int
  let incoming: Bool
  let skeleton: TargetingSkeleton?
}

@MainActor
final class RealtimeArenaController: ObservableObject {
  let session: PlayerSession
  let targeting: any TargetingSession
  let combat: RealtimeCombatSession
  let frameProvider: DuelFrameProvider?
  @Published private(set) var snapshot: CombatWire.Snapshot?
  @Published private(set) var frame = DuelFrameSnapshot()
  @Published private(set) var targetingSnapshot = TargetingSnapshot.unavailable()
  @Published private(set) var associatedBody: RealtimeAssociatedBody?
  @Published private(set) var confirmedHits: [RealtimeHitFeedback] = []
  @Published private(set) var connection: RealtimeConnectionState = .disconnected
  @Published private(set) var mapState: RealtimeMapState = .idle
  @Published private(set) var referenceState: DuelFrameReferenceState = .unavailable
  @Published private(set) var referenceImageData: Data?
  @Published private(set) var triggerHeld = false
  @Published private(set) var localShotSequence = 0
  @Published private(set) var message: String?
  @Published private(set) var actionFeedback: String?
  @Published private(set) var connectionIssue: String?
  @Published private(set) var now = Date()
  private let mapCoordinator: RealtimeMapCoordinator?
  private var subscriptions: Set<AnyCancellable> = []
  private var cameraTask: Task<Void, Never>?
  private var pumpTask: Task<Void, Never>?
  private var triggerTask: Task<Void, Never>?
  private var referenceTask: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var started = false
  private var cameraReady = false
  private var sceneActive = true
  private var generation = 0
  private var configuredEpoch: Int?
  private var authorityEpoch: Int?
  private var reconciledSnapshotRevision: Int?
  private var readiness = RealtimeReadinessState()
  private var commands = RealtimeCommandState()
  private var lastSubmittedPose: CombatWire.Pose?
  private var lastPoseDate: Date?
  private var poseSequence = 0
  private var lastLocalFireAtMs: Double?
  private var lastBodyDate: Date?
  private var lastBodyMatchTimeMs: Double?
  private var alignedSince: Date?

  init(session: PlayerSession, client: any GameSessionClient, targeting: any TargetingSession) {
    self.session = session; self.targeting = targeting
    let combat = RealtimeCombatSession(gameClient: client); self.combat = combat
    if let driver = targeting as? any DuelFrameSessionDriving {
      let provider = DuelFrameProvider(targeting: driver)
      frameProvider = provider
      mapCoordinator = RealtimeMapCoordinator(session: session, client: client, combat: combat, frame: provider)
    } else {frameProvider = nil; mapCoordinator = nil}
    combat.$connectionIssue.sink { [weak self] in self?.connectionIssue = $0 }.store(in: &subscriptions)
    combat.$snapshot.sink { [weak self] in self?.receiveSnapshot($0) }.store(in: &subscriptions)
    combat.$events.sink { [weak self] in self?.receiveEvents($0) }.store(in: &subscriptions)
    combat.$state.sink { [weak self] state in
      guard let self else {return}
      self.connection = state
      if state != .connected {
        self.readiness = RealtimeReadinessState(); self.setTriggerHeld(false); self.associatedBody = nil
      }
    }.store(in: &subscriptions)
    frameProvider?.$snapshot.sink { [weak self] value in
      guard let self else {return}
      let newlyAligned = value.stage == .aligned && self.frame.stage != .aligned
      self.frame = value
      if newlyAligned {self.alignedSince = Date()}
      if value.stage != .aligned {self.alignedSince = nil; self.associatedBody = nil; self.setTriggerHeld(false)}
    }.store(in: &subscriptions)
    frameProvider?.$referenceState.sink { [weak self] value in
      guard let self else {return}
      self.referenceState = value
      self.referenceImageData = self.frameProvider?.referenceImageData
    }.store(in: &subscriptions)
    mapCoordinator?.$state.sink { [weak self] in self?.mapState = $0 }.store(in: &subscriptions)
  }

  deinit {cameraTask?.cancel(); pumpTask?.cancel(); triggerTask?.cancel(); referenceTask?.cancel()}

  var startPending: Bool {commands.contains(.start)}
  var displayAmmo: Int {commands.availableAmmo(localPlayer?.ammo ?? 0)}
  var canOpenCameraSettings: Bool {message != nil && !cameraReady}
  var localPlayer: CombatWire.Player? {snapshot?.players.first {$0.playerId == session.playerId}}
  var isHost: Bool {localPlayer?.role == "host"}
  var matchTimeMs: Double? {combat.matchTimeMs}
  var worldReady: Bool {sceneActive && connection == .connected && combat.clockReady && frame.permitsSpatialFire(at: Date())}
  var eligibility: RealtimeActionEligibility {
    let fresh = lastSubmittedPose.map {pose in matchTimeMs.map {$0 >= pose.capturedAtMs && $0 - pose.capturedAtMs <= 100} ?? false} ?? false
    var result = RealtimeActionEligibility.evaluate(snapshot: snapshot, localPlayerID: session.playerId, clockReady: combat.clockReady,
      frameReady: frame.permitsSpatialFire(at: Date()), sceneActive: sceneActive, canSubmit: combat.canSubmitSpatialInput,
      poseFresh: fresh, localFireAtMs: lastLocalFireAtMs, matchTimeMs: matchTimeMs)
    if commands.contains(.reload) || commands.contains(.shield) {
      result.fire = false; result.reload = false; result.shield = false; result.reason = "Confirming action"
    }
    if commands.contains(.slowField) {result.slowField = false}
    if startPending {result.begin = false; result.reason = "Starting match"}
    if displayAmmo == 0 {
      result.fire = false
      if (localPlayer?.ammo ?? 0) > 0 {result.reason = "Confirming shots"}
    }
    return result
  }
  var stage: RealtimeArenaStage {
    if snapshot?.phase == .finished || connection == .finished {return .finished}
    if frameProvider == nil || message != nil || (connectionIssue != nil && connection == .disconnected) {return .unavailable}
    if connection == .retrying {return .reconnecting}
    if connection != .connected {return .connecting}
    switch mapState {
    case .waitingForHost: return .waitingForMap
    case .transferring: return .transferringMap
    case .failed: return .unavailable
    default: break
    }
    switch frame.stage {
    case .unaligned, .mapping: return .mapping
    case .mapReady: return .mapReady
    case .relocalizingWorld, .relocalizingBody: return .relocalizing
    case .awaitingResidual: return .measuringReference
    case .degraded, .lost: return .paused
    case .aligned: break
    }
    if !combat.clockReady || !sceneActive {return .paused}
    if localPlayer?.health == 0 {return .respawning}
    if snapshot?.phase == .running {return .running}
    return snapshot?.phase == .paused ? .paused : .awaitingMembers
  }

  func start() async {
    if let stopTask {await stopTask.value}
    if started {await startTask?.value; return}
    started = true; message = nil; generation += 1; let token = generation
    let task = Task { [weak self] in
      guard let self else {return}
      await self.performStart(token: token)
    }
    // Give each caller the same start completion, including a stop arriving while
    // the camera permission/session operation is suspended.
    startTask = task
    await task.value
    if generation == token {startTask = nil}
  }

  private func performStart(token: Int) async {
    guard started, generation == token else {return}
    combat.start(session: session)
    if !sceneActive {combat.suspendConnection()}
    let stream = targeting.snapshots()
    cameraTask = Task { [weak self] in
      for await value in stream {
        guard !Task.isCancelled else {return}
        self?.targetingSnapshot = value
        self?.refreshAssociation(at: Date())
      }
    }
    do {try await targeting.start()} catch {
      guard token == generation else {return}
      message = "Camera access is required. Allow the camera in Settings, then retry."; return
    }
    guard token == generation else {return}
    cameraReady = true
    configureMapIfNeeded()
    pumpTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.tick()
        do {try await Task.sleep(for: .milliseconds(50))} catch {return}
      }
    }
  }

  func stop() async {
    if let stopTask {await stopTask.value; return}
    guard started else {return}; started = false; cameraReady = false; generation += 1
    setTriggerHeld(false); cameraTask?.cancel(); cameraTask = nil; pumpTask?.cancel(); pumpTask = nil
    referenceTask?.cancel(); referenceTask = nil
    combat.stop(); configuredEpoch = nil; authorityEpoch = nil; readiness = RealtimeReadinessState()
    associatedBody = nil; confirmedHits = []; lastSubmittedPose = nil; lastPoseDate = nil
    commands = RealtimeCommandState(); actionFeedback = nil; lastLocalFireAtMs = nil
    let pendingStart = startTask
    let teardown = Task { [self] in
      // An AR start may ignore cancellation while awaiting camera permission.
      // Wait for it, then stop; otherwise it can turn the camera on after leave.
      await pendingStart?.value
      await mapCoordinator?.stop(); await targeting.stop()
      startTask = nil; stopTask = nil
    }
    stopTask = teardown
    await teardown.value
  }

  func setSceneActive(_ active: Bool) {
    sceneActive = active
    if !active {
      setTriggerHeld(false); frameProvider?.invalidate(reason: .backgrounded)
      associatedBody = nil; readiness = RealtimeReadinessState()
      combat.suspendConnection()
    } else if started {
      if combat.connectionSuspended {combat.retryConnection()}
      if frame.stage == .lost {retryAlignment()}
    }
  }
  func captureReference() {
    guard isHost, frame.stage == .mapReady, referenceTask == nil, let frameProvider else {return}
    let token = generation
    referenceTask = Task { [weak self] in
      do {_ = try await frameProvider.captureReference()} catch {
        // The provider publishes a typed, recoverable capture failure beside
        // the capture control; it does not make the whole match unavailable.
      }
      if self?.generation == token {self?.referenceTask = nil}
    }
  }
  func captureAndShareMap() {
    guard isHost, case .captured = referenceState else {return}
    mapCoordinator?.captureAndShare()
  }
  func retryAlignment() {
    guard started else {return}
    if !cameraReady {
      Task { [weak self] in
        guard let self else {return}
        await self.stop(); await self.start()
      }
      return
    }
    setTriggerHeld(false); message = nil; configuredEpoch = nil; readiness = RealtimeReadinessState(); lastSubmittedPose = nil; lastPoseDate = nil
    configureMapIfNeeded()
  }
  func recordResidual(frameID: String, epoch: UInt16, translationMeters: Double, yawDegrees: Double, observedAt: Date) throws {
    guard let frameProvider else {throw DuelFrameFailure.unsupported}
    try frameProvider.recordResidual(frameID: frameID, epoch: epoch, translationMeters: translationMeters, yawDegrees: yawDegrees, observedAt: observedAt)
  }
  func retryConnection() {setTriggerHeld(false); combat.retryConnection()}
  func beginRound() {
    guard eligibility.begin, let id = combat.submit(.start) else {return}
    commands.queued(.start, id: id); objectWillChange.send()
  }
  func reload() {
    guard eligibility.reload else {return}; setTriggerHeld(false)
    if let id = combat.submit(.reload) {commands.queued(.reload, id: id); objectWillChange.send()}
  }
  func toggleShield() {
    guard eligibility.shield, let pose = lastSubmittedPose else {return}; setTriggerHeld(false)
    let active = (localPlayer?.shield.activeUntilMs ?? 0) > (matchTimeMs ?? 0)
    if let id = combat.submit(.shield(active: !active, poseSequence: pose.sequence)) {commands.queued(.shield, id: id); objectWillChange.send()}
  }
  func activateSlowField() {
    guard eligibility.slowField, let pose = lastSubmittedPose,
      let id = combat.submit(.slowField(poseSequence: pose.sequence)) else {return}
    commands.queued(.slowField, id: id); objectWillChange.send()
  }
  func fireOnce() {
    guard eligibility.fire, let pose = lastSubmittedPose, let time = matchTimeMs else {return}
    let q = pose.orientation, x = q[0], y = q[1], z = q[2], w = q[3]
    let direction = [-2 * (x * z + w * y), -2 * (y * z - w * x), -(1 - 2 * (x * x + y * y))]
    let shotID = UUID().uuidString
    guard let id = combat.submit(.fire(shotId: shotID, poseSequence: pose.sequence, origin: pose.position, direction: direction)) else {return}
    commands.queued(.fire, id: id, shotID: shotID)
    lastLocalFireAtMs = time; localShotSequence += 1
  }
  func setTriggerHeld(_ held: Bool) {
    if !held {triggerHeld = false; triggerTask?.cancel(); triggerTask = nil; return}
    guard triggerTask == nil, eligibility.fire else {return}
    triggerHeld = true; fireOnce()
    triggerTask = Task { [weak self] in
      while !Task.isCancelled {
        do {try await Task.sleep(for: .milliseconds(25))} catch {return}
        guard let self, self.triggerHeld else {return}
        if !self.worldReady || self.snapshot?.phase != .running || (self.localPlayer?.health ?? 0) <= 0 || (self.localPlayer?.ammo ?? 0) <= 0 {
          self.setTriggerHeld(false); return
        }
        self.fireOnce()
      }
    }
  }

  private func receiveSnapshot(_ value: CombatWire.Snapshot?) {
    snapshot = value
    guard let value else {return}
    if reconciledSnapshotRevision != combat.snapshotRevision {
      commands.reconcile(pendingIDs: combat.pendingCommandIDs)
      reconciledSnapshotRevision = combat.snapshotRevision
    }
    if let authorityEpoch, authorityEpoch != value.authorityEpoch {
      configuredEpoch = nil; readiness = RealtimeReadinessState(); lastSubmittedPose = nil; lastPoseDate = nil
      commands = RealtimeCommandState(); actionFeedback = nil; lastLocalFireAtMs = nil; setTriggerHeld(false)
      frameProvider?.invalidate(reason: .sessionInterrupted)
    }
    authorityEpoch = value.authorityEpoch
    configureMapIfNeeded()
  }
  private func configureMapIfNeeded() {
    guard started, cameraReady, sceneActive, let snapshot, configuredEpoch != snapshot.frameEpoch, let epoch = UInt16(exactly: snapshot.frameEpoch), epoch > 0 else {return}
    configuredEpoch = snapshot.frameEpoch
    mapCoordinator?.configure(epoch: epoch, isHost: isHost)
  }
  private func tick() {
    guard started else {return}
    let date = Date(); now = date
    commands.tick(at: date); actionFeedback = commands.notice
    refreshAssociation(at: date)
    guard sceneActive, combat.canSubmitSpatialInput, let matchTimeMs else {return}
    let ready = frame.permitsSpatialFire(at: date)
    if readiness.shouldSubmit(ready: ready, authoritative: localPlayer?.frameReady ?? false, at: date) {
      let residual = frame.residual
      if let id = combat.submit(.frameReady(ready: ready, residualMeters: residual?.translationMeters ?? 0,
        residualDegrees: residual?.yawDegrees ?? 0, clockUncertaintyMs: combat.clockUncertaintyMs)) {
        readiness.queued(id: id, ready: ready, at: date)
      }
    }
    guard let sample = frame.localPose, sample.capturedAt != lastPoseDate,
      let pose = RealtimePoseBuilder.pose(sample, sequence: poseSequence + 1, matchTimeMs: matchTimeMs, now: date) else {return}
    var observations: [CombatWire.Observation] = []
    if let body = associatedBody, let residual = frame.residual {
      let uncertainty = residual.translationMeters + 0.05
      if uncertainty <= 0.1 {
        if lastBodyDate != body.skeleton.capturedAt {
          lastBodyDate = body.skeleton.capturedAt
          lastBodyMatchTimeMs = matchTimeMs - date.timeIntervalSince(body.skeleton.capturedAt) * 1000
        }
        let colliders = RealtimeAssociationPolicy.colliders(body.skeleton)
        if let captured = lastBodyMatchTimeMs, captured >= 0, matchTimeMs - captured <= 100, !colliders.isEmpty {
          observations = [.init(targetPlayerId: body.association.playerID, capturedAtMs: captured,
            associationConfidence: body.association.confidence, uncertaintyMeters: uncertainty, colliders: colliders)]
        }
      }
    }
    if combat.submit(.pose(pose, observations: observations)) != nil {
      poseSequence = pose.sequence; lastSubmittedPose = pose; lastPoseDate = sample.capturedAt
    }
  }
  private func refreshAssociation(at date: Date) {
    guard let snapshot, let time = matchTimeMs, let skeleton = targetingSnapshot.skeleton,
      let alignedSince, skeleton.capturedAt >= alignedSince,
      let association = RealtimeAssociationPolicy.associate(skeleton: skeleton, observationConfidence: targetingSnapshot.confidence,
        phonePoses: snapshot.phonePoses, players: snapshot.players, localPlayerID: session.playerId,
        matchTimeMs: time, now: date, frameReady: worldReady) else {associatedBody = nil; return}
    associatedBody = .init(association: association, skeleton: skeleton)
  }
  private func receiveEvents(_ values: [CombatWire.ServerEvent]) {
    var hits: [RealtimeHitFeedback] = []
    for wrapped in values {
      switch wrapped.event {
      case .projectileSpawn(let projectile):
        if projectile.shooterId == session.playerId {
          commands.projectileSpawned(shotID: projectile.shotId, atMs: projectile.spawnedAtMs)
        }
      case .playerChanged(let player):
        if player.playerId == session.playerId {commands.playerChanged(lastFireAtMs: player.lastFireAtMs)}
      case .commandResult(let commandID, _, let playerID, let accepted, let reason):
        guard playerID == session.playerId else {continue}
        readiness.resolve(id: commandID)
        commands.resolve(id: commandID, accepted: accepted, reason: reason, at: Date())
        actionFeedback = commands.notice
        objectWillChange.send()
      case .projectileTerminal(let terminal):
        guard terminal.reason == "bodyHit", terminal.damage > 0, sceneActive, connection == .connected else {continue}
        let incoming = terminal.targetPlayerId == session.playerId
        guard incoming || terminal.shooterId == session.playerId else {continue}
        refreshAssociation(at: Date())
        let skeleton = incoming ? nil : RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: terminal.targetPlayerId,
          association: associatedBody?.association, skeleton: associatedBody?.skeleton, now: Date())
        hits.append(.init(id: wrapped.eventSequence, targetPlayerID: terminal.targetPlayerId,
          zone: terminal.zone.flatMap {TargetingHitZone(rawValue: $0.rawValue)}, damage: terminal.damage, incoming: incoming, skeleton: skeleton))
      default: break
      }
    }
    if !hits.isEmpty {confirmedHits = hits}
  }
}
