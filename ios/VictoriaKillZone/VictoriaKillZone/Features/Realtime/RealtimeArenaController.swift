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
  @Published private(set) var triggerHeld = false
  @Published private(set) var localShotSequence = 0
  @Published private(set) var message: String?
  @Published private(set) var now = Date()
  private let mapCoordinator: RealtimeMapCoordinator?
  private var subscriptions: Set<AnyCancellable> = []
  private var cameraTask: Task<Void, Never>?
  private var pumpTask: Task<Void, Never>?
  private var triggerTask: Task<Void, Never>?
  private var started = false
  private var cameraReady = false
  private var sceneActive = true
  private var generation = 0
  private var configuredEpoch: Int?
  private var authorityEpoch: Int?
  private var announcedReady: Bool?
  private var lastSubmittedPose: CombatWire.Pose?
  private var lastPoseDate: Date?
  private var poseSequence = 0
  private var lastLocalFireAtMs: Double?
  private var lastBodyDate: Date?
  private var lastBodyMatchTimeMs: Double?
  private var pendingReload: String?
  private var pendingShield: String?
  private var alignedSince: Date?

  init(session: PlayerSession, client: any GameSessionClient, targeting: any TargetingSession) {
    self.session = session; self.targeting = targeting
    let combat = RealtimeCombatSession(gameClient: client); self.combat = combat
    if let driver = targeting as? any DuelFrameSessionDriving {
      let provider = DuelFrameProvider(targeting: driver)
      frameProvider = provider
      mapCoordinator = RealtimeMapCoordinator(session: session, client: client, combat: combat, frame: provider)
    } else {frameProvider = nil; mapCoordinator = nil}
    combat.$snapshot.sink { [weak self] in self?.receiveSnapshot($0) }.store(in: &subscriptions)
    combat.$events.sink { [weak self] in self?.receiveEvents($0) }.store(in: &subscriptions)
    combat.$state.sink { [weak self] state in
      guard let self else {return}
      self.connection = state
      if state != .connected {
        self.announcedReady = nil; self.setTriggerHeld(false); self.associatedBody = nil
        self.pendingReload = nil; self.pendingShield = nil
      }
    }.store(in: &subscriptions)
    frameProvider?.$snapshot.sink { [weak self] value in
      guard let self else {return}
      let newlyAligned = value.stage == .aligned && self.frame.stage != .aligned
      self.frame = value
      if newlyAligned {self.alignedSince = Date()}
      if value.stage != .aligned {self.alignedSince = nil; self.associatedBody = nil; self.setTriggerHeld(false)}
    }.store(in: &subscriptions)
    mapCoordinator?.$state.sink { [weak self] in self?.mapState = $0 }.store(in: &subscriptions)
  }

  deinit {cameraTask?.cancel(); pumpTask?.cancel(); triggerTask?.cancel()}

  var localPlayer: CombatWire.Player? {snapshot?.players.first {$0.playerId == session.playerId}}
  var isHost: Bool {localPlayer?.role == "host"}
  var matchTimeMs: Double? {combat.matchTimeMs}
  var worldReady: Bool {sceneActive && connection == .connected && combat.clockReady && frame.permitsSpatialFire(at: Date())}
  var eligibility: RealtimeActionEligibility {
    let fresh = lastSubmittedPose.map {pose in matchTimeMs.map {$0 >= pose.capturedAtMs && $0 - pose.capturedAtMs <= 100} ?? false} ?? false
    var result = RealtimeActionEligibility.evaluate(snapshot: snapshot, localPlayerID: session.playerId, clockReady: combat.clockReady,
      frameReady: frame.permitsSpatialFire(at: Date()), sceneActive: sceneActive, canSubmit: combat.canSubmitSpatialInput,
      poseFresh: fresh, localFireAtMs: lastLocalFireAtMs, matchTimeMs: matchTimeMs)
    if pendingReload != nil || pendingShield != nil {result.fire = false; result.reload = false; result.shield = false; result.reason = "Confirming action"}
    return result
  }
  var stage: RealtimeArenaStage {
    if snapshot?.phase == .finished || connection == .finished {return .finished}
    if frameProvider == nil || message != nil {return .unavailable}
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
    return .awaitingMembers
  }

  func start() async {
    guard !started else {return}; started = true; generation += 1; let token = generation
    combat.start(session: session)
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
    guard started else {return}; started = false; cameraReady = false; generation += 1
    setTriggerHeld(false); cameraTask?.cancel(); cameraTask = nil; pumpTask?.cancel(); pumpTask = nil
    combat.stop(); configuredEpoch = nil; authorityEpoch = nil; announcedReady = nil
    associatedBody = nil; confirmedHits = []; lastSubmittedPose = nil; lastPoseDate = nil
    pendingReload = nil; pendingShield = nil; lastLocalFireAtMs = nil
    await mapCoordinator?.stop(); await targeting.stop()
  }

  func setSceneActive(_ active: Bool) {
    sceneActive = active
    if !active {setTriggerHeld(false); frameProvider?.invalidate(reason: .backgrounded); associatedBody = nil; announcedReady = nil}
    else if started, frame.stage == .lost {retryAlignment()}
  }
  func captureAndShareMap() {guard isHost else {return}; mapCoordinator?.captureAndShare()}
  func retryAlignment() {
    guard started else {return}
    if !cameraReady {
      Task { [weak self] in
        guard let self else {return}
        await self.stop(); await self.start()
      }
      return
    }
    setTriggerHeld(false); message = nil; configuredEpoch = nil; announcedReady = nil; lastSubmittedPose = nil; lastPoseDate = nil
    configureMapIfNeeded()
  }
  func recordResidual(frameID: String, epoch: UInt16, translationMeters: Double, yawDegrees: Double, observedAt: Date) throws {
    guard let frameProvider else {throw DuelFrameFailure.unsupported}
    try frameProvider.recordResidual(frameID: frameID, epoch: epoch, translationMeters: translationMeters, yawDegrees: yawDegrees, observedAt: observedAt)
  }
  func beginRound() {guard eligibility.begin else {return}; _ = combat.submit(.start)}
  func reload() {
    guard eligibility.reload else {return}; setTriggerHeld(false)
    pendingReload = combat.submit(.reload); objectWillChange.send()
  }
  func toggleShield() {
    guard eligibility.shield, let pose = lastSubmittedPose else {return}; setTriggerHeld(false)
    let active = (localPlayer?.shield.activeUntilMs ?? 0) > (matchTimeMs ?? 0)
    pendingShield = combat.submit(.shield(active: !active, poseSequence: pose.sequence)); objectWillChange.send()
  }
  func activateSlowField() {guard eligibility.slowField, let pose = lastSubmittedPose else {return}; _ = combat.submit(.slowField(poseSequence: pose.sequence))}
  func fireOnce() {
    guard eligibility.fire, let pose = lastSubmittedPose, let time = matchTimeMs else {return}
    let q = pose.orientation, x = q[0], y = q[1], z = q[2], w = q[3]
    let direction = [-2 * (x * z + w * y), -2 * (y * z - w * x), -(1 - 2 * (x * x + y * y))]
    guard combat.submit(.fire(shotId: UUID().uuidString, poseSequence: pose.sequence, origin: pose.position, direction: direction)) != nil else {return}
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
    if let authorityEpoch, authorityEpoch != value.authorityEpoch {
      configuredEpoch = nil; announcedReady = nil; lastSubmittedPose = nil; lastPoseDate = nil
      pendingReload = nil; pendingShield = nil; lastLocalFireAtMs = nil; setTriggerHeld(false)
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
    refreshAssociation(at: date)
    guard sceneActive, combat.canSubmitSpatialInput, let matchTimeMs else {return}
    let ready = frame.permitsSpatialFire(at: date)
    if announcedReady != ready {
      let residual = frame.residual
      if combat.submit(.frameReady(ready: ready, residualMeters: residual?.translationMeters ?? 0,
        residualDegrees: residual?.yawDegrees ?? 0, clockUncertaintyMs: combat.clockUncertaintyMs)) != nil {announcedReady = ready}
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
      case .commandResult(let commandID, _, let playerID, _, _):
        guard playerID == session.playerId else {continue}
        if pendingReload == commandID {pendingReload = nil}
        if pendingShield == commandID {pendingShield = nil}
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
