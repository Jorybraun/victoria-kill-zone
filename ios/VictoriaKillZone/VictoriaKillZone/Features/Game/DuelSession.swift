import SwiftUI

enum DebugShotState: Equatable, Sendable {
  case idle
  case pending
  case failed
  case confirmed(damage: Int)
}

enum MarkerlessShotState: Equatable, Sendable {
  case idle
  case pending(zone: HitZone?)
  case confirmed(outcome: FireShotOutcome, zone: HitZone?, damage: Int)
  case failed(reason: FireRejectReason?)
}

struct KillBanner: Equatable, Sendable {
  let eventID: String
  let text: String
  let timestamp: Double
  let isLocalKill: Bool
}

struct IncomingShot: Equatable, Sendable {
  let eventID: String
  let hit: Bool
  let zone: String?
  let timestamp: Double
  let source: Source
  /// An authoritative hit still presents damage when its peer tracer was shown.
  let renderTracer: Bool

  init(
    eventID: String,
    hit: Bool,
    zone: String?,
    timestamp: Double,
    source: Source,
    renderTracer: Bool = true
  ) {
    self.eventID = eventID
    self.hit = hit
    self.zone = zone
    self.timestamp = timestamp
    self.source = source
    self.renderTracer = renderTracer
  }

  enum Source: Equatable, Sendable {
    case convex
    case peer
  }
}

struct OutgoingShot: Equatable, Sendable {
  let id: String
  let ray: TargetingCameraRay?
}

@MainActor
final class DuelSession: ObservableObject {
  struct Gates {
    var isLiveNetworking: @MainActor () -> Bool = { true }
    var isInputLocked: @MainActor () -> Bool = { false }
    var isBusy: @MainActor () -> Bool = { false }
  }

  // Combat tuning in design/slices/004; enforced independently by the authority.
  static let fireCooldown: TimeInterval = 0.15
  static let pendingShotConfirmationBudget: TimeInterval = 2.5
  static let incomingShotDedupCapacity = 256

  @Published private(set) var debugShotState = DebugShotState.idle
  @Published private(set) var markerlessShotState = MarkerlessShotState.idle
  @Published private(set) var lastAcceptedShotAt: Date?
  @Published private(set) var killBanner: KillBanner?
  @Published private(set) var incomingShot: IncomingShot?
  @Published private(set) var incomingShots: [IncomingShot] = []
  @Published private(set) var outgoingShot: OutgoingShot?
  @Published private(set) var isTriggerHeld = false
  @Published private(set) var isReloadRequestPending = false
  @Published private(set) var reloadAcknowledgedUntil: Double?
  @Published private(set) var presenceReady = true

  var gates = Gates()
  var onErrorMessage: ((String?) -> Void)?

  private(set) var session: PlayerSession?
  private(set) var latestSnapshot: MatchSnapshot?
  private(set) var targetingSnapshot: TargetingSnapshot = .unavailable()

  private var pendingShotId: String?
  private var pendingShotResult: DebugFireResult?
  private var pendingShotDispatchedAt: Date?
  private var pendingShotAutomaticReplayStarted = false
  private var pendingMarkerlessRequest: FireShotRequest?
  private var killBannerTask: Task<Void, Never>?
  private var pendingShotReplayTask: Task<Void, Never>?
  private var seenKillEventIDs = Set<String>()
  private var seenIncomingShotEventIDs = Set<String>()
  private var seenIncomingShotEventOrder: [String] = []
  private struct TracerIdentity: Hashable {
    let shooterID: String
    let shotID: String
  }
  private var renderedTracerIDs = Set<TracerIdentity>()
  private var renderedTracerOrder: [TracerIdentity] = []
  private var snapshotSubscriptionStartedAt: Double?
  private var duelPeerLink: (any DuelPeerLink)?
  private let now: @Sendable () -> Date
  private let makeShotId: @Sendable () -> String
  private let gameSessionClient: any GameSessionClient
  private let makePeerLink: @MainActor (_ serviceName: String) -> (any DuelPeerLink)?
  private var fireTask: Task<Void, Never>?
  private var repeatFireTask: Task<Void, Never>?
  private var reloadTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var lastDispatchedAt: Date?

  var seenIncomingShotEventCount: Int {
    seenIncomingShotEventIDs.count
  }

  var renderedIncomingTracerCount: Int {
    renderedTracerIDs.count
  }

  init(
    gameSessionClient: any GameSessionClient,
    now: @escaping @Sendable () -> Date = { Date() },
    makeShotId: @escaping @Sendable () -> String = { UUID().uuidString },
    makePeerLink: @escaping @MainActor (_ serviceName: String) -> (any DuelPeerLink)? =
      DuelSession.defaultPeerLink
  ) {
    self.gameSessionClient = gameSessionClient
    self.now = now
    self.makeShotId = makeShotId
    self.makePeerLink = makePeerLink
  }

  static func defaultPeerLink(serviceName: String) -> (any DuelPeerLink)? {
    #if canImport(Network)
      return ArenaPeerLink(serviceName: serviceName)
    #else
      return nil
    #endif
  }

  func attach(session: PlayerSession) {
    fireTask?.cancel()
    stopRepeatingFire()
    reloadTask?.cancel()
    heartbeatTask?.cancel()
    heartbeatTask = nil
    isReloadRequestPending = false
    reloadAcknowledgedUntil = nil
    outgoingShot = nil
    lastDispatchedAt = nil
    presenceReady = true
    killBannerTask?.cancel()
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    duelPeerLink?.stop()
    duelPeerLink = nil
    self.session = session
    latestSnapshot = nil
    pendingShotId = nil
    pendingShotResult = nil
    pendingShotDispatchedAt = nil
    pendingShotAutomaticReplayStarted = false
    pendingMarkerlessRequest = nil
    lastAcceptedShotAt = nil
    setDebugShotState(.idle)
    setMarkerlessShotState(.idle)
    seenKillEventIDs.removeAll()
    seenIncomingShotEventIDs.removeAll()
    seenIncomingShotEventOrder.removeAll()
    renderedTracerIDs.removeAll()
    renderedTracerOrder.removeAll()
    incomingShot = nil
    incomingShots = []
    killBanner = nil
    snapshotSubscriptionStartedAt = nil
    startHeartbeat()
  }

  func receive(_ snapshot: MatchSnapshot) {
    let previousSnapshot = latestSnapshot
    if snapshotSubscriptionStartedAt == nil {
      snapshotSubscriptionStartedAt = snapshot.serverNow
    }
    latestSnapshot = snapshot
    if let local = snapshot.players.first(where: { $0.id == snapshot.localPlayerId }),
      local.reloadEndsAt != nil || local.ammo == 8 || local.lifeState != .alive
        || snapshot.serverNow >= (reloadAcknowledgedUntil ?? .greatestFiniteMagnitude)
    {
      reloadAcknowledgedUntil = nil
    }
    if snapshot.match.phase != .running || localPlayer?.lifeState != .alive {
      stopRepeatingFire()
    }
    updateKillBanner(from: snapshot)
    updateIncomingShot(from: snapshot)
    updateDuelPeerLink(for: snapshot, previous: previousSnapshot)
    reconcilePendingShot()
  }

  func updateTargeting(_ snapshot: TargetingSnapshot) {
    targetingSnapshot = snapshot
  }

  func reset() {
    stopRepeatingFire()
    reloadTask?.cancel()
    heartbeatTask?.cancel()
    heartbeatTask = nil
    isReloadRequestPending = false
    reloadAcknowledgedUntil = nil
    outgoingShot = nil
    lastDispatchedAt = nil
    fireTask?.cancel()
    fireTask = nil
    killBannerTask?.cancel()
    killBannerTask = nil
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    duelPeerLink?.stop()
    duelPeerLink = nil
    session = nil
    latestSnapshot = nil
    pendingShotId = nil
    pendingShotResult = nil
    pendingShotDispatchedAt = nil
    pendingShotAutomaticReplayStarted = false
    pendingMarkerlessRequest = nil
    lastAcceptedShotAt = nil
    seenKillEventIDs.removeAll()
    seenIncomingShotEventIDs.removeAll()
    seenIncomingShotEventOrder.removeAll()
    renderedTracerIDs.removeAll()
    renderedTracerOrder.removeAll()
    snapshotSubscriptionStartedAt = nil
    setDebugShotState(.idle)
    setMarkerlessShotState(.idle)
    killBanner = nil
    incomingShot = nil
    incomingShots = []
    targetingSnapshot = .unavailable()
  }

  var canDebugFire: Bool {
    guard gates.isLiveNetworking(), !gates.isInputLocked(), !gates.isBusy(),
      let session, let snapshot = latestSnapshot,
      snapshot.match.phase == .running,
      snapshot.localPlayerId == session.playerId,
      snapshot.players.first(where: { $0.id == session.playerId })?.role == .host
    else {
      return false
    }
    switch debugShotState {
    case .idle, .failed, .confirmed: return true
    case .pending: return false
    }
  }

  var canFireMarkerless: Bool {
    guard gates.isLiveNetworking(), presenceReady, !gates.isInputLocked(), !gates.isBusy(),
      let session, let snapshot = latestSnapshot,
      snapshot.localPlayerId == session.playerId,
      let localPlayer = snapshot.players.first(where: { $0.id == session.playerId })
    else {
      return false
    }

    if case .pending = markerlessShotState { return false }
    if hasPendingMarkerlessReplay {
      // The last round may already have committed, or the shooter may have died
      // before its reply arrived. Replaying that exact ID cannot fire a new round.
      return [.running, .finished, .cancelled].contains(snapshot.match.phase)
    }
    guard snapshot.match.phase == .running, localPlayer.lifeState == .alive,
      localPlayer.ammo > 0, !isReloading
    else { return false }

    // A fresh camera without a candidate can still fire an authoritative miss.
    guard let ray = targetingSnapshot.cameraRay else { return false }
    let age = now().timeIntervalSince(ray.capturedAt)
    return age >= 0 && age <= targetingSnapshot.poseStaleAfter
  }

  private var hasPendingMarkerlessReplay: Bool {
    if case .failed(reason: nil) = markerlessShotState {
      return pendingMarkerlessRequest != nil
    }
    return false
  }

  func fireCooldownRemaining(at date: Date) -> TimeInterval {
    guard let lastShotAt = lastDispatchedAt ?? lastAcceptedShotAt else { return 0 }
    return max(0, Self.fireCooldown - date.timeIntervalSince(lastShotAt))
  }

  func fireCooldownProgress(at date: Date) -> Double {
    guard Self.fireCooldown > 0 else { return 1 }
    return min(1, max(0, 1 - fireCooldownRemaining(at: date) / Self.fireCooldown))
  }

  var markerlessAimZone: HitZone? {
    guard targetingSnapshot.isPoseFresh(at: now()),
      let zone = targetingSnapshot.hitZone
    else {
      return nil
    }
    return HitZone(rawValue: zone.rawValue)
  }

  func debugFire() {
    fireTask = Task { [weak self] in await self?.performDebugFire() }
  }

  func fireMarkerless() {
    fireTask = Task { [weak self] in await self?.performMarkerlessFire() }
  }

  var localPlayer: PlayerSnapshot? {
    latestSnapshot?.players.first { $0.id == session?.playerId }
  }

  var isReloading: Bool {
    isReloadRequestPending || localPlayer?.reloadEndsAt != nil || reloadAcknowledgedUntil != nil
  }

  var canReload: Bool {
    guard presenceReady, !gates.isInputLocked(), !gates.isBusy(),
      latestSnapshot?.match.phase == .running, let localPlayer,
      localPlayer.lifeState == .alive, localPlayer.ammo < 8, !isReloading,
      pendingMarkerlessRequest == nil
    else { return false }
    return true
  }

  func reload() {
    stopRepeatingFire()
    reloadTask = Task { [weak self] in await self?.performReload() }
  }

  func performReload() async {
    guard canReload, let session else { return }
    isReloadRequestPending = true
    defer { if self.session == session { isReloadRequestPending = false } }
    do {
      let result = try await gameSessionClient.startReload(session: session)
      guard !Task.isCancelled, self.session == session else { return }
      if latestSnapshot?.match.phase == .running, localPlayer?.lifeState == .alive,
        localPlayer?.reloadEndsAt == nil, localPlayer?.ammo != 8,
        (latestSnapshot?.serverNow ?? 0) < result.reloadEndsAt
      {
        reloadAcknowledgedUntil = result.reloadEndsAt
      }
      onErrorMessage?(nil)
    } catch {
      guard !Task.isCancelled, self.session == session else { return }
      present(error)
    }
  }

  func startRepeatingFire() {
    guard repeatFireTask == nil, canFireMarkerless else { return }
    isTriggerHeld = true
    repeatFireTask = Task { [weak self] in
      var attemptedShot = false
      while !Task.isCancelled {
        guard let self, self.isTriggerHeld, self.presenceReady,
          !self.gates.isInputLocked(), self.latestSnapshot?.match.phase == .running,
          (self.localPlayer?.lifeState == .alive || self.hasPendingMarkerlessReplay),
          (!self.isReloading || self.hasPendingMarkerlessReplay)
        else { break }
        if case .pending = self.markerlessShotState {
          // Releasing the trigger must not cancel an already dispatched mutation.
        } else if self.canFireMarkerless {
          // A new press can recover a previous failure. A failure during this
          // press stops repetition, preventing an unattended retry loop.
          if case .failed = self.markerlessShotState, attemptedShot { break }
          if self.hasPendingMarkerlessReplay || self.fireCooldownRemaining(at: self.now()) == 0 {
            attemptedShot = true
            self.fireMarkerless()
          }
        } else {
          break
        }
        try? await Task.sleep(for: .milliseconds(16))
      }
      guard !Task.isCancelled else { return }
      self?.isTriggerHeld = false
      self?.repeatFireTask = nil
    }
  }

  func stopRepeatingFire() {
    isTriggerHeld = false
    repeatFireTask?.cancel()
    repeatFireTask = nil
  }

  func setSceneActive(_ active: Bool) {
    if active { startHeartbeat() }
    else {
      stopRepeatingFire()
      presenceReady = false
      heartbeatTask?.cancel()
      heartbeatTask = nil
    }
  }

  private func startHeartbeat() {
    guard heartbeatTask == nil, let expectedSession = session else { return }
    let client = gameSessionClient
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled, self?.session == expectedSession {
        do {
          try await client.heartbeat(session: expectedSession)
          guard !Task.isCancelled, let self, self.session == expectedSession else { return }
          self.presenceReady = true
        } catch {
          guard !Task.isCancelled, let self, self.session == expectedSession else { return }
          self.presenceReady = false
          self.stopRepeatingFire()
        }
        try? await Task.sleep(for: .seconds(5))
      }
    }
  }

  func performDebugFire() async {
    guard gates.isLiveNetworking(), let session, let snapshot = latestSnapshot else { return }
    guard !gates.isInputLocked() else {
      onErrorMessage?("SHOT LOCKED WHILE RECONNECTING")
      return
    }
    guard snapshot.match.phase == .running else {
      onErrorMessage?("SHOT LOCKED UNTIL DUEL STARTS")
      return
    }
    guard snapshot.players.first(where: { $0.id == session.playerId })?.role == .host else {
      onErrorMessage?("SOMETHING WENT WRONG")
      return
    }
    switch debugShotState {
    case .idle, .failed, .confirmed:
      break
    case .pending:
      return
    }

    let shotId = pendingShotId ?? makeShotId()
    pendingShotId = shotId
    pendingShotDispatchedAt = now()
    pendingShotAutomaticReplayStarted = false
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    setDebugShotState(.pending)
    onErrorMessage?(nil)
    do {
      let result = try await gameSessionClient.debugFire(
        session: session,
        clientShotId: shotId
      )
      guard !Task.isCancelled else { return }
      guard result.clientShotId == shotId else {
        throw GameSessionClientError.invalidSnapshot
      }
      guard result.accepted, result.outcome == .hit else {
        pendingShotId = nil
        pendingShotResult = nil
        pendingShotDispatchedAt = nil
        pendingShotAutomaticReplayStarted = false
        setDebugShotState(.failed)
        if let reason = result.rejectReason {
          present(GameSessionClientError.backend(reason))
        } else {
          present(GameSessionClientError.unknown)
        }
        return
      }
      pendingShotResult = result
      schedulePendingShotDeadline(for: session, shotId: shotId)
      reconcilePendingShot()
    } catch {
      guard !Task.isCancelled else { return }
      setDebugShotState(.failed)
      present(error)
    }
  }

  func performMarkerlessFire() async {
    guard gates.isLiveNetworking(), let session, let snapshot = latestSnapshot else { return }
    guard !gates.isInputLocked() else {
      onErrorMessage?("SHOT LOCKED WHILE RECONNECTING")
      return
    }
    guard snapshot.match.phase == .running || hasPendingMarkerlessReplay
    else {
      onErrorMessage?("PUT THE CROSSHAIR ON YOUR OPPONENT")
      return
    }
    guard canFireMarkerless else { return }
    guard hasPendingMarkerlessReplay || fireCooldownRemaining(at: now()) == 0 else { return }

    let request: FireShotRequest
    let zone: HitZone?
    let dispatchedAt = now()
    if let retryRequest = pendingMarkerlessRequest,
      case .failed(reason: nil) = markerlessShotState
    {
      request = retryRequest
      zone = retryRequest.zone
    } else {
      let opponent = snapshot.players.first(where: { $0.id != session.playerId && $0.lifeState == .alive })
      let aimedZone = markerlessAimZone
      let minimumConfidence = aimedZone == .head ? 0.60 : 0.45
      zone = opponent != nil && targetingSnapshot.hitConfidence >= minimumConfidence ? aimedZone : nil
      let ray = targetingSnapshot.cameraRay
      request = FireShotRequest(
        clientShotId: makeShotId(),
        targetId: zone == nil ? nil : opponent?.id,
        zone: zone,
        poseConfidence: targetingSnapshot.hitConfidence,
        origin: ray.map { [$0.origin.x, $0.origin.y, $0.origin.z] },
        direction: ray.map { [$0.direction.x, $0.direction.y, $0.direction.z] },
        impact: impactPoint(for: zone, ray: ray),
        firedAtClient: now().timeIntervalSince1970 * 1_000
      )
      pendingMarkerlessRequest = request
    }
    setMarkerlessShotState(.pending(zone: zone))
    lastDispatchedAt = dispatchedAt
    onErrorMessage?(nil)
    if outgoingShot?.id != request.clientShotId {
      outgoingShot = OutgoingShot(id: request.clientShotId, ray: targetingSnapshot.cameraRay)
      sendPeerTracer(for: request)
    }

    do {
      let result = try await gameSessionClient.fire(session: session, request: request)
      guard !Task.isCancelled, self.session == session else { return }
      guard result.clientShotId == request.clientShotId else {
        throw GameSessionClientError.invalidSnapshot
      }
      guard result.accepted, result.outcome != .rejected else {
        pendingMarkerlessRequest = nil
        setMarkerlessShotState(.failed(reason: result.rejectReason))
        if result.rejectReason == .fireCooldown {
          lastDispatchedAt = now()
        } else {
          onErrorMessage?(Self.message(for: result.rejectReason))
        }
        return
      }

      pendingMarkerlessRequest = nil
      setMarkerlessShotState(.confirmed(
        outcome: result.outcome,
        zone: zone,
        damage: result.damage
      ))
      lastAcceptedShotAt = dispatchedAt
    } catch {
      guard !Task.isCancelled, self.session == session else { return }
      setMarkerlessShotState(.failed(reason: nil))
      present(error)
    }
  }

  private func updateKillBanner(from snapshot: MatchSnapshot) {
    let newEvents = snapshot.events.filter { event in
      guard event.type == .eliminated, !seenKillEventIDs.contains(event.id) else {
        return false
      }
      seenKillEventIDs.insert(event.id)
      return true
    }
    let chosenEvent = snapshotSubscriptionStartedAt.flatMap { startedAt in
      newEvents
        .filter({ $0.createdAt >= startedAt })
        .max(by: { $0.createdAt < $1.createdAt })
    }
    gameLoopTrace(
      "updateKillBanner newEliminatedEventCount=\(newEvents.count) "
        + "chosenEventCreatedAt=\(chosenEvent.map { String($0.createdAt) } ?? "none")"
    )
    guard let event = chosenEvent,
      let banner = makeKillBanner(for: event, in: snapshot)
    else {
      return
    }

    killBannerTask?.cancel()
    killBanner = banner
    killBannerTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, let self, self.killBanner?.eventID == banner.eventID else {
        return
      }
      self.killBanner = nil
      self.killBannerTask = nil
    }
  }

  private func updateIncomingShot(from snapshot: MatchSnapshot) {
    guard let opponentID = snapshot.players.first(where: { $0.id != snapshot.localPlayerId })?.id,
      let startedAt = snapshotSubscriptionStartedAt
    else {
      publishIncomingShots([])
      return
    }
    var batch: [IncomingShot] = []
    for event in snapshot.events.sorted(by: {
      ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
    }) {
      guard [.shot, .hit, .eliminated].contains(event.type),
        event.actorPlayerId == opponentID,
        !seenIncomingShotEventIDs.contains(event.id)
      else { continue }
      seenIncomingShotEventIDs.insert(event.id)
      seenIncomingShotEventOrder.append(event.id)
      if seenIncomingShotEventOrder.count > Self.incomingShotDedupCapacity {
        let evicted = seenIncomingShotEventOrder.removeFirst()
        seenIncomingShotEventIDs.remove(evicted)
      }
      guard event.createdAt >= startedAt else { continue }
      let renderTracer = rememberIncomingTracer(shooterID: opponentID, shotID: event.clientShotId)
      let hit = event.type != .shot
      // A matching peer frame replaces only the cosmetic tracer. Health and
      // damage feedback always come from the distinct authoritative event.
      guard renderTracer || hit else { continue }
      batch.append(IncomingShot(
        eventID: event.id,
        hit: hit,
        zone: event.zone,
        timestamp: event.createdAt,
        source: .convex,
        renderTracer: renderTracer
      ))
    }
    publishIncomingShots(batch)
  }

  /// Legacy events without a shot ID cannot safely match an earlier peer frame.
  private func rememberIncomingTracer(shooterID: String, shotID: String?) -> Bool {
    guard let shotID, !shotID.isEmpty else { return true }
    let identity = TracerIdentity(shooterID: shooterID, shotID: shotID)
    guard renderedTracerIDs.insert(identity).inserted else { return false }
    renderedTracerOrder.append(identity)
    if renderedTracerOrder.count > Self.incomingShotDedupCapacity {
      renderedTracerIDs.remove(renderedTracerOrder.removeFirst())
    }
    return true
  }

  private func publishIncomingShots(_ batch: [IncomingShot]) {
    if let last = batch.last { incomingShot = last }
    incomingShots = batch
  }

  private func impactPoint(
    for zone: HitZone?,
    ray: TargetingCameraRay?
  ) -> [Double]? {
    if let zone, let skeleton = targetingSnapshot.skeleton {
      let jointName = zone == .head ? "head" : "root"
      if let point = skeleton.position(of: jointName) {
        return [point.x, point.y, point.z]
      }
    }
    guard let ray else { return nil }
    let point = ray.origin + ray.direction * 25
    return [point.x, point.y, point.z]
  }

  private func sendPeerTracer(for request: FireShotRequest) {
    guard let link = duelPeerLink,
      let origin = request.origin, origin.count == 3,
      let direction = request.direction, direction.count == 3,
      let ray = try? ArenaShotRay(
        origin: ArenaVector3(x: origin[0], y: origin[1], z: origin[2]),
        direction: ArenaVector3(x: direction[0], y: direction[1], z: direction[2]),
        firedAtMs: ArenaClock.nowMs()
      )
    else { return }
    link.send(.shotTracer(ArenaShotTracer(
      shotId: request.clientShotId,
      shooterPlayerId: session?.playerId ?? "",
      ray: ray
    )))
  }

  private func updateDuelPeerLink(for snapshot: MatchSnapshot, previous: MatchSnapshot?) {
    if snapshot.match.phase == .running, duelPeerLink == nil,
      let role = snapshot.players.first(where: { $0.id == snapshot.localPlayerId })?.role,
      let link = makePeerLink(Self.peerServiceName(forMatchID: snapshot.match.id))
    {
      let expectedMatchID = snapshot.match.id
      link.onMessage = { [weak self] message, _ in
        guard case .shotTracer(let tracer) = message else { return }
        Task { @MainActor [weak self] in
          guard let self,
            let latestSnapshot = self.latestSnapshot,
            latestSnapshot.match.id == expectedMatchID,
            latestSnapshot.match.phase == .running,
            let opponentID = latestSnapshot.players
              .first(where: { $0.id != latestSnapshot.localPlayerId })?.id,
            tracer.shooterPlayerId == opponentID,
            !tracer.shotId.isEmpty,
            self.rememberIncomingTracer(shooterID: opponentID, shotID: tracer.shotId)
          else { return }
          self.publishIncomingShots([IncomingShot(
            eventID: "peer:" + tracer.shotId,
            hit: false,
            zone: nil,
            timestamp: self.now().timeIntervalSince1970 * 1_000,
            source: .peer
          )])
        }
      }
      duelPeerLink = link
      link.start(role: role == .host ? .host : .guest)
    } else if snapshot.match.phase != .running, previous?.match.phase == .running {
      duelPeerLink?.stop()
      duelPeerLink = nil
    }
  }

  static func peerServiceName(forMatchID matchID: String) -> String {
    "vkz-" + String(matchID.prefix(48))
  }

  private func makeKillBanner(for event: EventSnapshot, in snapshot: MatchSnapshot)
    -> KillBanner?
  {
    let playersByID = Dictionary(uniqueKeysWithValues: snapshot.players.map { ($0.id, $0) })
    if event.actorPlayerId == snapshot.localPlayerId {
      let text = playerName(
        for: event.targetPlayerId,
        in: playersByID
      ).map { "YOU ELIMINATED \($0)" } ?? event.message
      return KillBanner(
        eventID: event.id,
        text: text,
        timestamp: event.createdAt,
        isLocalKill: true
      )
    }
    guard event.targetPlayerId == snapshot.localPlayerId else { return nil }
    let text = playerName(
      for: event.actorPlayerId,
      in: playersByID
    ).map { "ELIMINATED BY \($0)" } ?? event.message
    return KillBanner(
      eventID: event.id,
      text: text,
      timestamp: event.createdAt,
      isLocalKill: false
    )
  }

  private func playerName(
    for playerID: String?,
    in playersByID: [String: PlayerSnapshot]
  ) -> String? {
    guard let playerID, let name = playersByID[playerID]?.displayName,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return name
  }

  private func reconcilePendingShot() {
    guard let result = pendingShotResult else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noPending")
      return
    }

    guard let session else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noSession")
      return
    }
    guard let shotId = pendingShotId else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noPendingShotId")
      return
    }

    guard let snapshot = latestSnapshot,
      let shooter = snapshot.players.first(where: { $0.id == session.playerId }),
      let target = snapshot.players.first(where: { $0.id != session.playerId })
    else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noSnapshot")
      startPendingShotReplayIfBudgetElapsed(for: session, shotId: shotId)
      return
    }

    let confirmed: Bool
    if let eventId = result.eventId {
      confirmed = snapshot.events.contains(where: { $0.id == eventId })
      if !confirmed {
        gameLoopTrace("reconcilePendingShot outcome=awaiting reason=eventMissing")
      }
    } else {
      confirmed = shooter.ammo == result.shooterAmmo && target.health == result.targetHealth
      if !confirmed {
        gameLoopTrace("reconcilePendingShot outcome=awaiting reason=stateMismatch")
      }
    }

    guard confirmed else {
      startPendingShotReplayIfBudgetElapsed(for: session, shotId: shotId)
      return
    }

    gameLoopTrace("reconcilePendingShot outcome=confirmed")
    setDebugShotState(.confirmed(damage: result.damage))
    lastAcceptedShotAt = now()
    clearPendingShot()
  }

  private func schedulePendingShotDeadline(for expectedSession: PlayerSession, shotId: String) {
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = Task { [weak self] in
      try? await Task.sleep(
        for: .milliseconds(Int(Self.pendingShotConfirmationBudget * 1_000))
      )
      guard !Task.isCancelled, let self,
        self.session == expectedSession,
        self.pendingShotId == shotId
      else {
        return
      }
      self.pendingShotReplayTask = nil
      self.reconcilePendingShot()
    }
  }

  private func startPendingShotReplayIfBudgetElapsed(
    for expectedSession: PlayerSession,
    shotId: String
  ) {
    guard let dispatchedAt = pendingShotDispatchedAt,
      now().timeIntervalSince(dispatchedAt) >= Self.pendingShotConfirmationBudget,
      !pendingShotAutomaticReplayStarted,
      pendingShotId == shotId,
      session == expectedSession
    else {
      return
    }

    pendingShotAutomaticReplayStarted = true
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = Task { [weak self] in
      guard let self else { return }
      await self.performPendingShotReplay(
        for: expectedSession,
        shotId: shotId
      )
    }
  }

  private func performPendingShotReplay(
    for expectedSession: PlayerSession,
    shotId: String
  ) async {
    guard session == expectedSession, pendingShotId == shotId else {
      pendingShotReplayTask = nil
      return
    }

    do {
      let result = try await gameSessionClient.debugFire(
        session: expectedSession,
        clientShotId: shotId
      )
      guard !Task.isCancelled, session == expectedSession, pendingShotId == shotId else {
        return
      }
      guard result.clientShotId == shotId else {
        throw GameSessionClientError.invalidSnapshot
      }
      guard result.accepted, result.outcome == .hit else {
        gameLoopTrace("reconcilePendingShot reason=eventAgedOut outcome=replayRejected")
        clearPendingShot()
        setDebugShotState(.failed)
        if let reason = result.rejectReason {
          present(GameSessionClientError.backend(reason))
        } else {
          present(GameSessionClientError.unknown)
        }
        return
      }
      guard result.replayed else {
        gameLoopTrace("reconcilePendingShot reason=eventAgedOut outcome=replayNotIdempotent")
        pendingShotReplayTask = nil
        setDebugShotState(.failed)
        present(GameSessionClientError.invalidSnapshot)
        return
      }

      gameLoopTrace("reconcilePendingShot reason=eventAgedOut outcome=replayConfirmed")
      clearPendingShot()
      setDebugShotState(.confirmed(damage: result.damage))
      lastAcceptedShotAt = now()
    } catch {
      guard !Task.isCancelled, session == expectedSession, pendingShotId == shotId else {
        return
      }
      gameLoopTrace("reconcilePendingShot reason=eventAgedOut outcome=replayFailed")
      pendingShotReplayTask = nil
      setDebugShotState(.failed)
      present(error)
    }
  }

  private func clearPendingShot() {
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    pendingShotResult = nil
    pendingShotId = nil
    pendingShotDispatchedAt = nil
    pendingShotAutomaticReplayStarted = false
  }

  private func setDebugShotState(_ state: DebugShotState) {
    gameLoopTrace(
      "debugShotState \(String(describing: debugShotState)) -> \(String(describing: state))"
    )
    debugShotState = state
  }

  private func setMarkerlessShotState(_ state: MarkerlessShotState) {
    gameLoopTrace(
      "markerlessShotState \(String(describing: markerlessShotState)) -> \(String(describing: state))"
    )
    markerlessShotState = state
  }

  private func gameLoopTrace(_ message: @autoclosure () -> String) {
    GameLoopTrace.trace(message())
  }

  private func present(_ error: Error) {
    if let safeError = error as? GameSessionClientError {
      onErrorMessage?(safeError.localizedDescription)
    } else {
      onErrorMessage?("SOMETHING WENT WRONG")
    }
  }

  private static func message(for reason: FireRejectReason?) -> String {
    switch reason {
    case .matchNotRunning: "SHOT LOCKED UNTIL DUEL STARTS"
    case .connectionStale: "SHOT LOCKED WHILE RECONNECTING"
    case .shooterNotAlive: "WAITING TO RESPAWN"
    case .reloading: "RELOADING"
    case .outOfArena: "RETURN TO THE ARENA"
    case .locationStale: "LOCATION IS NOT READY"
    case .outOfAmmo: "OUT OF AMMO"
    case .fireCooldown: "STEADY — FIRE AGAIN"
    case .idempotencyConflict: "SHOT COULD NOT BE VERIFIED"
    case .invalidTarget: "TARGET LOST"
    case .targetNotAlive: "OPPONENT IS RESPAWNING"
    case nil: "SHOT REJECTED"
    }
  }
}
