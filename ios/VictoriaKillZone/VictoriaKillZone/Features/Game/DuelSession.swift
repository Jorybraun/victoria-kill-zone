import SwiftUI

enum DebugShotState: Equatable, Sendable {
  case idle
  case pending
  case failed
  case confirmed(damage: Int)
}

enum MarkerlessShotState: Equatable, Sendable {
  case idle
  case pending(zone: HitZone)
  case confirmed(outcome: FireShotOutcome, zone: HitZone, damage: Int)
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

  enum Source: Equatable, Sendable {
    case convex
    case peer
  }
}

@MainActor
final class DuelSession: ObservableObject {
  struct Gates {
    var isLiveNetworking: @MainActor () -> Bool = { true }
    var isInputLocked: @MainActor () -> Bool = { false }
    var isBusy: @MainActor () -> Bool = { false }
  }

  // Mirrors FIRE_COOLDOWN_MS = 350 in Convex.
  static let fireCooldown: TimeInterval = 0.35
  static let pendingShotConfirmationBudget: TimeInterval = 2.5
  static let incomingShotDedupCapacity = 256
  static let peerTracerSuppressionWindow: TimeInterval = 2

  @Published private(set) var debugShotState = DebugShotState.idle
  @Published private(set) var markerlessShotState = MarkerlessShotState.idle
  @Published private(set) var lastAcceptedShotAt: Date?
  @Published private(set) var killBanner: KillBanner?
  @Published private(set) var incomingShot: IncomingShot?

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
  private var lastPeerShotAt: Date?
  private var snapshotSubscriptionStartedAt: Double?
  private var duelPeerLink: (any DuelPeerLink)?
  private let now: @Sendable () -> Date
  private let makeShotId: @Sendable () -> String
  private let gameSessionClient: any GameSessionClient
  private let makePeerLink: (@MainActor (_ serviceName: String) -> (any DuelPeerLink)?)?
  private var fireTask: Task<Void, Never>?

  var seenIncomingShotEventCount: Int {
    seenIncomingShotEventIDs.count
  }

  init(
    gameSessionClient: any GameSessionClient,
    now: @escaping @Sendable () -> Date = { Date() },
    makeShotId: @escaping @Sendable () -> String = { UUID().uuidString },
    makePeerLink: (@escaping @MainActor (_ serviceName: String) -> (any DuelPeerLink)?)? = nil
  ) {
    self.gameSessionClient = gameSessionClient
    self.now = now
    self.makeShotId = makeShotId
    self.makePeerLink = makePeerLink
  }

  static func defaultPeerLink(
    matchId: String, playerId: String, joinSecret: String
  ) -> any DuelPeerLink {
    ArenaPeerLinkFactory.make(matchId: matchId, playerId: playerId, joinSecret: joinSecret)
  }

  func attach(session: PlayerSession) {
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
    lastPeerShotAt = nil
    incomingShot = nil
    killBanner = nil
    snapshotSubscriptionStartedAt = nil
  }

  func receive(_ snapshot: MatchSnapshot) {
    let previousSnapshot = latestSnapshot
    if snapshotSubscriptionStartedAt == nil {
      snapshotSubscriptionStartedAt = snapshot.serverNow
    }
    latestSnapshot = snapshot
    updateKillBanner(from: snapshot)
    updateIncomingShot(from: snapshot)
    updateDuelPeerLink(for: snapshot, previous: previousSnapshot)
    reconcilePendingShot()
  }

  func updateTargeting(_ snapshot: TargetingSnapshot) {
    targetingSnapshot = snapshot
  }

  func reset() {
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
    lastPeerShotAt = nil
    snapshotSubscriptionStartedAt = nil
    setDebugShotState(.idle)
    setMarkerlessShotState(.idle)
    killBanner = nil
    incomingShot = nil
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
    guard gates.isLiveNetworking(), !gates.isInputLocked(), !gates.isBusy(),
      let session, let snapshot = latestSnapshot,
      snapshot.match.phase == .running,
      snapshot.localPlayerId == session.playerId,
      let localPlayer = snapshot.players.first(where: { $0.id == session.playerId }),
      let opponent = snapshot.players.first(where: { $0.id != session.playerId }),
      localPlayer.lifeState == .alive, localPlayer.ammo > 0,
      opponent.lifeState == .alive
    else {
      return false
    }

    if case .pending = markerlessShotState { return false }
    if case .failed(reason: nil) = markerlessShotState,
      pendingMarkerlessRequest != nil
    {
      return true
    }

    guard let targetZone = targetingSnapshot.hitZone,
      targetingSnapshot.isPoseFresh(at: now())
    else {
      return false
    }
    let minimumConfidence = targetZone == .head ? 0.60 : 0.45
    guard targetingSnapshot.hitConfidence >= minimumConfidence else { return false }
    return true
  }

  func fireCooldownRemaining(at date: Date) -> TimeInterval {
    guard let lastAcceptedShotAt else { return 0 }
    return max(0, Self.fireCooldown - date.timeIntervalSince(lastAcceptedShotAt))
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
    guard snapshot.match.phase == .running,
      let opponent = snapshot.players.first(where: { $0.id != session.playerId }),
      opponent.lifeState == .alive
    else {
      onErrorMessage?("PUT THE CROSSHAIR ON YOUR OPPONENT")
      return
    }
    guard canFireMarkerless else { return }

    let request: FireShotRequest
    let zone: HitZone
    if let retryRequest = pendingMarkerlessRequest,
      case .failed(reason: nil) = markerlessShotState,
      let retryZone = retryRequest.zone
    {
      request = retryRequest
      zone = retryZone
    } else {
      guard let freshZone = markerlessAimZone else { return }
      zone = freshZone
      let ray = targetingSnapshot.cameraRay
      request = FireShotRequest(
        clientShotId: makeShotId(),
        targetId: opponent.id,
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
    onErrorMessage?(nil)
    sendPeerTracer(for: request)

    do {
      let result = try await gameSessionClient.fire(session: session, request: request)
      guard !Task.isCancelled else { return }
      guard result.clientShotId == request.clientShotId else {
        throw GameSessionClientError.invalidSnapshot
      }
      guard result.accepted, result.outcome != .rejected else {
        pendingMarkerlessRequest = nil
        setMarkerlessShotState(.failed(reason: result.rejectReason))
        if result.rejectReason == .fireCooldown {
          if lastAcceptedShotAt == nil {
            lastAcceptedShotAt = now()
          }
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
      lastAcceptedShotAt = now()
    } catch {
      guard !Task.isCancelled else { return }
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
    let opponentID = snapshot.players.first(where: { $0.id != snapshot.localPlayerId })?.id
    let newEvents = snapshot.events.filter { event in
      guard [.shot, .hit, .eliminated].contains(event.type),
        event.actorPlayerId == opponentID,
        !seenIncomingShotEventIDs.contains(event.id)
      else { return false }
      seenIncomingShotEventIDs.insert(event.id)
      seenIncomingShotEventOrder.append(event.id)
      if seenIncomingShotEventOrder.count > Self.incomingShotDedupCapacity {
        let evicted = seenIncomingShotEventOrder.removeFirst()
        seenIncomingShotEventIDs.remove(evicted)
      }
      return true
    }
    guard let startedAt = snapshotSubscriptionStartedAt,
      let event = newEvents
        .filter({ $0.createdAt >= startedAt })
        .max(by: { $0.createdAt < $1.createdAt })
    else { return }
    let peerAlreadyRendered =
      lastPeerShotAt.map { now().timeIntervalSince($0) < Self.peerTracerSuppressionWindow } == true
    if peerAlreadyRendered && event.type == .shot { return }
    incomingShot = IncomingShot(
      eventID: event.id,
      hit: event.type != .shot,
      zone: event.zone,
      timestamp: event.createdAt,
      source: .convex
    )
  }

  private func impactPoint(
    for zone: HitZone,
    ray: TargetingCameraRay?
  ) -> [Double]? {
    if let skeleton = targetingSnapshot.skeleton {
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
      let link = makePeerLink(for: snapshot)
    {
      link.onMessage = { [weak self] message, _ in
        guard case .shotTracer(let tracer) = message else { return }
        Task { @MainActor [weak self] in
          guard let self,
            let latestSnapshot = self.latestSnapshot,
            let opponentID = latestSnapshot.players
              .first(where: { $0.id != latestSnapshot.localPlayerId })?.id,
            tracer.shooterPlayerId == opponentID
          else { return }
          self.lastPeerShotAt = self.now()
          self.incomingShot = IncomingShot(
            eventID: "peer:" + tracer.shotId,
            hit: false,
            zone: nil,
            timestamp: self.now().timeIntervalSince1970 * 1_000,
            source: .peer
          )
        }
      }
      duelPeerLink = link
      link.start(role: role == .host ? .host : .guest)
    } else if snapshot.match.phase != .running, previous?.match.phase == .running {
      duelPeerLink?.stop()
      duelPeerLink = nil
    }
  }

  private func makePeerLink(for snapshot: MatchSnapshot) -> (any DuelPeerLink)? {
    if let makePeerLink {
      return makePeerLink(Self.peerServiceName(forMatchID: snapshot.match.id))
    }
    return Self.defaultPeerLink(
      matchId: snapshot.match.id,
      playerId: snapshot.localPlayerId,
      joinSecret: session?.code ?? ""
    )
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
