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
  @Published private(set) var snapshot: CombatWire.Snapshot?
  @Published private(set) var targetingSnapshot = TargetingSnapshot.unavailable()
  @Published private(set) var associatedBody: RealtimeAssociatedBody?
  @Published private(set) var confirmedHits: [RealtimeHitFeedback] = []
  @Published private(set) var connection: RealtimeConnectionState = .disconnected
  @Published private(set) var triggerHeld = false
  @Published private(set) var localShotSequence = 0
  @Published private(set) var message: String?
  /// Set when the authority's rules contradict the lobby's chosen mode; the
  /// match cannot continue and no retry control may reopen it.
  @Published private(set) var incompatibleRules = false
  @Published private(set) var actionFeedback: String?
  @Published private(set) var connectionIssue: String?
  @Published private(set) var now = Date()
  private var subscriptions: Set<AnyCancellable> = []
  private var cameraTask: Task<Void, Never>?
  private var pumpTask: Task<Void, Never>?
  private var triggerTask: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var started = false
  private var cameraReady = false
  private var sceneActive = true
  private var generation = 0
  private var authorityEpoch: Int?
  private var reconciledSnapshotRevision: Int?
  private var commands = RealtimeCommandState()
  private var lastSubmittedPose: CombatWire.Pose?
  private var lastPoseDate: Date?
  private var poseSequence = 0
  private var lastLocalFireAtMs: Double?
  private var diagnostics = MatchDiagnostics(startedAt: Date())
  private var lastDiagnosticStage: RealtimeArenaStage?

  init(session: PlayerSession, client: any GameSessionClient, targeting: any TargetingSession,
       makeTransport: @escaping @MainActor () -> any CombatSocketConnecting = {CombatSocketTransport()},
       localNow: @escaping @Sendable () -> Double = {ProcessInfo.processInfo.systemUptime * 1000}) {
    self.session = session; self.targeting = targeting
    let combat = RealtimeCombatSession(gameClient: client, makeTransport: makeTransport, localNow: localNow)
    self.combat = combat
    combat.$connectionIssue.sink { [weak self] in self?.connectionIssue = $0 }.store(in: &subscriptions)
    combat.$snapshot.sink { [weak self] in self?.receiveSnapshot($0) }.store(in: &subscriptions)
    combat.$events.sink { [weak self] in self?.receiveEvents($0) }.store(in: &subscriptions)
    combat.$state.sink { [weak self] state in
      guard let self else {return}
      let previous = self.connection
      self.connection = state
      if previous != state {
        self.diagnostics.record("connection",
          "\(Self.connectionName(previous)) -> \(Self.connectionName(state))", at: Date())
      }
      self.recordStageTransition()
      if state != .connected {
        self.setTriggerHeld(false); self.associatedBody = nil
      }
    }.store(in: &subscriptions)
  }

  deinit {cameraTask?.cancel(); pumpTask?.cancel(); triggerTask?.cancel()}

  var startPending: Bool {commands.contains(.start)}
  var displayAmmo: Int {commands.availableAmmo(localPlayer?.ammo ?? 0)}
  var canOpenCameraSettings: Bool {message != nil && !cameraReady}
  var localPlayer: CombatWire.Player? {snapshot?.players.first {$0.playerId == session.playerId}}
  var isHost: Bool {localPlayer?.role == "host"}
  var matchTimeMs: Double? {combat.matchTimeMs}
  var worldReady: Bool {sceneActive && connection == .connected && combat.clockReady}
  var eligibility: RealtimeActionEligibility {
    let fresh = lastSubmittedPose.map {pose in matchTimeMs.map {$0 >= pose.capturedAtMs && $0 - pose.capturedAtMs <= 100} ?? false} ?? false
    var result = RealtimeActionEligibility.evaluate(snapshot: snapshot, localPlayerID: session.playerId, clockReady: combat.clockReady,
      sceneActive: sceneActive, canSubmit: combat.canSubmitSpatialInput, poseFresh: fresh,
      localFireAtMs: lastLocalFireAtMs, matchTimeMs: matchTimeMs)
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
    if incompatibleRules {return .unavailable}
    if snapshot?.phase == .finished || connection == .finished {return .finished}
    if message != nil || (connectionIssue != nil && connection == .disconnected) {return .unavailable}
    if connection == .retrying {return .reconnecting}
    if connection != .connected {return .connecting}
    if !combat.clockReady || !sceneActive {return .paused}
    if localPlayer?.health == 0 {return .respawning}
    if snapshot?.phase == .running {return .running}
    return snapshot?.phase == .paused ? .paused : .awaitingMembers
  }

  func start() async {
    if let stopTask {await stopTask.value}
    if started {await startTask?.value; return}
    started = true; message = nil; incompatibleRules = false; generation += 1; let token = generation
    diagnostics.reset(at: Date()); lastDiagnosticStage = nil
    recordStageTransition()
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
      diagnostics.record("camera", "start=failed reason=\(Self.cameraFailureReason(error))", at: Date())
      message = "Camera access is required. Allow the camera in Settings, then retry."
      recordStageTransition()
      return
    }
    guard token == generation else {return}
    cameraReady = true
    diagnostics.record("camera", "start=ok", at: Date())
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
    combat.stop(); authorityEpoch = nil
    associatedBody = nil; confirmedHits = []; lastSubmittedPose = nil; lastPoseDate = nil
    commands = RealtimeCommandState(); actionFeedback = nil; lastLocalFireAtMs = nil
    let pendingStart = startTask
    let teardown = Task { [self] in
      // An AR start may ignore cancellation while awaiting camera permission.
      // Wait for it, then stop; otherwise it can turn the camera on after leave.
      await pendingStart?.value
      await targeting.stop()
      startTask = nil; stopTask = nil
    }
    stopTask = teardown
    await teardown.value
  }

  func setSceneActive(_ active: Bool) {
    sceneActive = active
    recordStageTransition()
    if !active {
      setTriggerHeld(false); associatedBody = nil
      combat.suspendConnection()
    } else if started {
      if combat.connectionSuspended {combat.retryConnection()}
    }
  }
  func retryCamera() {
    guard started, !cameraReady, !incompatibleRules else {return}
    Task { [weak self] in
      guard let self else {return}
      await self.stop(); await self.start()
    }
  }
  func retryConnection() {setTriggerHeld(false); combat.retryConnection()}
  func diagnosticEvents() -> [MatchDiagnosticEvent] {
    let surfaces = targeting as? any LocalSurfaceDiagnosticsProviding
    let surfaceEvents = surfaces?.localSurfaceDiagnosticEvents() ?? []
    var events = diagnostics.events + surfaceEvents
    if let csv = surfaces?.localSurfaceTelemetryCSV() {
      events.append(MatchDiagnosticEvent(
        elapsedMs: surfaceEvents.last?.elapsedMs ?? 0, kind: "telemetryCsv", detail: csv))
    }
    return events
  }
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
    let shotID = UUID().uuidString
    guard let ray = targetingSnapshot.cameraRay, RealtimeAssociationPolicy.fresh(ray.capturedAt, at: Date()) else {return}
    let origin = [ray.origin.x, ray.origin.y, ray.origin.z]
    let direction = [ray.direction.x, ray.direction.y, ray.direction.z]
    var observation: CombatWire.Observation?
    if let body = associatedBody {
      let colliders = RealtimeAssociationPolicy.colliders(body.skeleton)
      let captured = time - Date().timeIntervalSince(body.skeleton.capturedAt) * 1000
      if !colliders.isEmpty, captured >= 0 {
        observation = .init(targetPlayerId: body.association.playerID, capturedAtMs: captured,
          associationConfidence: body.association.confidence, uncertaintyMeters: 0.08, colliders: colliders)
      }
    }
    guard let id = combat.submit(.fire(shotId: shotID, poseSequence: pose.sequence, origin: origin, direction: direction,
      observation: observation)) else {return}
    diagnostics.record("fire", "observation=\(observation != nil)", at: Date())
    commands.queued(.fire, id: id, shotID: shotID)
    (targeting as? any LocalSurfaceDiagnosticsProviding)?.recordSightingFire(ray: ray, skeleton: associatedBody?.skeleton)
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
    guard let value else {
      recordStageTransition()
      return
    }
    if value.rules.geometry != "sighting" {
      if !incompatibleRules {
        diagnostics.record("rules", "incompatible geometry=\(Self.geometryName(value.rules.geometry))", at: Date())
      }
      incompatibleRules = true
      message = RealtimeArenaPresentation.Sighting.incompatibleServerMessage
      recordStageTransition()
      combat.stop()
      return
    }
    if reconciledSnapshotRevision != combat.snapshotRevision {
      commands.reconcile(pendingIDs: combat.pendingCommandIDs)
      reconciledSnapshotRevision = combat.snapshotRevision
    }
    if let authorityEpoch, authorityEpoch != value.authorityEpoch {
      lastSubmittedPose = nil; lastPoseDate = nil
      commands = RealtimeCommandState(); actionFeedback = nil; lastLocalFireAtMs = nil; setTriggerHeld(false)
      associatedBody = nil
    }
    authorityEpoch = value.authorityEpoch
    recordStageTransition()
  }
  /// ADR 0013 zero-step Quick Duel: the host starts the round the moment the
  /// sighting gate opens — no second tap after the lobby start. `eligibility`
  /// already gates on host role, every member connected, an unstarted round,
  /// and no pending start command, so a pause/reconnect cannot re-fire once
  /// `roundStartedAtMs` is set.
  private var lastAutoBegin: Date?
  private func autoBeginIfReady() {
    guard eligibility.begin else {return}
    if let last = lastAutoBegin, now.timeIntervalSince(last) < 2 {return}
    lastAutoBegin = now
    beginRound()
  }
  private func tick() {
    guard started else {return}
    let date = Date(); now = date
    recordStageTransition(at: date)
    commands.tick(at: date); actionFeedback = commands.notice
    refreshAssociation(at: date)
    autoBeginIfReady()
    guard sceneActive, combat.canSubmitSpatialInput, let matchTimeMs else {return}
    guard let ray = targetingSnapshot.cameraRay, ray.capturedAt != lastPoseDate,
      let pose = RealtimePoseBuilder.pose(ray: ray, sequence: poseSequence + 1, matchTimeMs: matchTimeMs, now: date),
      combat.submit(.pose(pose, observations: [])) != nil else {return}
    poseSequence = pose.sequence; lastSubmittedPose = pose; lastPoseDate = ray.capturedAt
  }
  private func refreshAssociation(at date: Date) {
    if let snapshot, let skeleton = targetingSnapshot.skeleton,
      let association = RealtimeAssociationPolicy.associateSighting(skeleton: skeleton,
        observationConfidence: targetingSnapshot.confidence, players: snapshot.players,
        localPlayerID: session.playerId, now: date) {
      associatedBody = .init(association: association, skeleton: skeleton)
      return
    }
    associatedBody = nil
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
        if !accepted {
          diagnostics.record("command", "refused reason=\(Self.commandRefusalReason(reason))", at: Date())
        }
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

  private func recordStageTransition(at date: Date = Date()) {
    let next = stage
    guard next != lastDiagnosticStage else {return}
    let previous = lastDiagnosticStage.map {String(describing: $0)} ?? "initial"
    diagnostics.record("stage", "\(previous) -> \(String(describing: next))", at: date)
    lastDiagnosticStage = next
  }

  private static func connectionName(_ state: RealtimeConnectionState) -> String {
    switch state {
    case .disconnected: "disconnected"
    case .connecting: "connecting"
    case .synchronizing: "synchronizing"
    case .connected: "connected"
    case .retrying: "retrying"
    case .finished: "finished"
    }
  }

  private static func cameraFailureReason(_ error: Error) -> String {
    switch error as? TargetingSessionError {
    case .cameraPermissionDenied: "permissionDenied"
    case .notConfigured: "notConfigured"
    case nil: "other"
    }
  }

  private static func geometryName(_ geometry: String) -> String {
    switch geometry {
    case "sighting", "trackedBody", "phoneProxy": geometry
    default: "other"
    }
  }

  private static func commandRefusalReason(_ reason: String?) -> String {
    switch reason {
    case "notReady", "trackingLost", "poseStale", "poseMismatch", "notAlive", "protected",
      "cooldown", "reloading", "outOfAmmo", "shieldActive", "abilityCooldown", "projectileLimit",
      "tooLate", "futureInput", "noSighting", "ambiguousTarget", "notHost", "notRunning":
      reason ?? "other"
    default:
      "other"
    }
  }
}
