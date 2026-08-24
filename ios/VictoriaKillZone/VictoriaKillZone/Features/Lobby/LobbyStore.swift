import SwiftUI

#if DEBUG
import os
#endif

enum LobbySyncStatus: Equatable, Sendable {
  case shell
  case connecting
  case connected
  case stale
  case restored
}

enum LobbyNetworkOperation: Equatable, Sendable {
  case creating
  case joining
  case settingReady
  case starting
}

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

@MainActor
final class LobbyStore: ObservableObject {
  private static let pendingShotConfirmationBudget: TimeInterval = 2.5

  @Published private(set) var route: LobbyRoute
  @Published var displayName = "Player"
  @Published var joinCode = "" {
    didSet {
      let normalized = Self.normalizedJoinCode(joinCode)
      if joinCode != normalized { joinCode = normalized }
    }
  }
  @Published private(set) var errorMessage: String?
  @Published private(set) var operation: LobbyNetworkOperation?
  @Published private(set) var syncStatus: LobbySyncStatus
  @Published private(set) var lastSyncAt: Date?
  @Published private(set) var debugShotState = DebugShotState.idle
  @Published private(set) var markerlessShotState = MarkerlessShotState.idle
  @Published private(set) var targetingSnapshot: TargetingSnapshot
  @Published private(set) var killBanner: KillBanner?

  let environment: AppEnvironment

  private var stateMachine: LobbyStateMachine
  private var session: PlayerSession?
  private var latestSnapshot: MatchSnapshot?
  private var pendingShotId: String?
  private var pendingShotResult: DebugFireResult?
  private var pendingShotDispatchedAt: Date?
  private var pendingShotAutomaticReplayStarted = false
  private var pendingMarkerlessRequest: FireShotRequest?
  private var actionTask: Task<Void, Never>?
  private var snapshotTask: Task<Void, Never>?
  private var snapshotRetryTask: Task<Void, Never>?
  private var connectionTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var targetingTask: Task<Void, Never>?
  private var killBannerTask: Task<Void, Never>?
  private var pendingShotReplayTask: Task<Void, Never>?
  private var seenKillEventIDs = Set<String>()
  private var snapshotSubscriptionStartedAt: Double?
  private var transportState = GameSessionConnectionState.connecting
  private let now: @Sendable () -> Date
  private let makeShotId: @Sendable () -> String

  init(
    environment: AppEnvironment = .phaseZeroShell,
    now: @escaping @Sendable () -> Date = { Date() },
    makeShotId: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.environment = environment
    self.now = now
    self.makeShotId = makeShotId
    let stateMachine = LobbyStateMachine()
    self.stateMachine = stateMachine
    route = stateMachine.route
    syncStatus = environment.gameSessionClient.availability == .available ? .connecting : .shell
    targetingSnapshot = environment.targetingSession.currentSnapshot
    startConnectionMonitoring()
  }

  deinit {
    actionTask?.cancel()
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    connectionTask?.cancel()
    recoveryTask?.cancel()
    targetingTask?.cancel()
    killBannerTask?.cancel()
    pendingShotReplayTask?.cancel()
  }

  var networkingStatus: String {
    switch syncStatus {
    case .shell: "NETWORK SHELL"
    case .connecting: "CONNECTING"
    case .connected: "CONNECTED"
    case .stale: "RECONNECTING — INPUT LOCKED"
    case .restored: "SYNC RESTORED"
    }
  }

  var targetingStatus: String {
    targetingSnapshot.state.displayText
  }

  var isLiveNetworking: Bool {
    environment.gameSessionClient.availability == .available
  }

  var isBusy: Bool {
    operation != nil
  }

  var isMatchInputLocked: Bool {
    guard isLiveNetworking, session != nil else { return false }
    return syncStatus == .connecting || syncStatus == .stale
  }

  var createButtonLabel: String {
    operation == .creating ? "CREATING DUEL…" : "CREATE DUEL"
  }

  var joinButtonLabel: String {
    operation == .joining ? "JOINING DUEL…" : "JOIN ARENA"
  }

  var canDebugFire: Bool {
    guard isLiveNetworking, !isMatchInputLocked, operation == nil,
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
    guard isLiveNetworking, !isMatchInputLocked, operation == nil,
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

  var markerlessAimZone: HitZone? {
    guard targetingSnapshot.isPoseFresh(at: now()),
      let zone = targetingSnapshot.hitZone
    else {
      return nil
    }
    return HitZone(rawValue: zone.rawValue)
  }

  func showJoin() {
    guard !isBusy else { return }
    transition(.showJoin)
  }

  func cancelJoin() {
    guard !isBusy else { return }
    transition(.cancelJoin)
  }

  func createDuel() {
    schedule { store in await store.performCreateDuel() }
  }

  func joinDuel() {
    schedule { store in await store.performJoinDuel() }
  }

  func simulateOpponentJoined() {
    guard !isLiveNetworking else { return }
    transition(.opponentJoined(displayName: "Rival"))
  }

  func toggleReady(for playerID: String, currentValue: Bool) {
    guard !isBusy else { return }
    if !isLiveNetworking {
      transition(.readinessChanged(playerID: playerID, isReady: !currentValue))
      return
    }
    schedule { store in await store.performSetReady(isReady: !currentValue) }
  }

  func startDuel(as role: LobbyRole) {
    guard !isBusy else { return }
    if !isLiveNetworking {
      transition(role == .host ? .startRequested : .matchStarted)
      return
    }
    schedule { store in await store.performStartDuel() }
  }

  func debugFire() {
    schedule { store in await store.performDebugFire() }
  }

  func fireMarkerless() {
    schedule { store in await store.performMarkerlessFire() }
  }

  func startTargeting() async {
    guard environment.targetingSession.availability == .available else {
      targetingSnapshot = .unavailable()
      return
    }
    guard targetingTask == nil else { return }

    let targetingSession = environment.targetingSession
    targetingTask = Task { [weak self] in
      for await snapshot in targetingSession.snapshots() {
        guard !Task.isCancelled else { return }
        self?.targetingSnapshot = snapshot
      }
    }

    do {
      try await targetingSession.start()
    } catch TargetingSessionError.cameraPermissionDenied {
      errorMessage = "CAMERA ACCESS IS REQUIRED"
    } catch {
      errorMessage = "TARGETING UNAVAILABLE"
    }
  }

  func stopTargeting() async {
    targetingTask?.cancel()
    targetingTask = nil
    await environment.targetingSession.stop()
    targetingSnapshot = environment.targetingSession.currentSnapshot
  }

  func leave() {
    actionTask?.cancel()
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    recoveryTask?.cancel()
    targetingTask?.cancel()
    killBannerTask?.cancel()
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    targetingTask = nil
    let targetingSession = environment.targetingSession
    Task { await targetingSession.stop() }
    session = nil
    latestSnapshot = nil
    pendingShotId = nil
    pendingShotResult = nil
    pendingShotDispatchedAt = nil
    pendingShotAutomaticReplayStarted = false
    pendingMarkerlessRequest = nil
    operation = nil
    setDebugShotState(.idle)
    setMarkerlessShotState(.idle)
    seenKillEventIDs.removeAll()
    snapshotSubscriptionStartedAt = nil
    killBanner = nil
    targetingSnapshot = .unavailable()
    lastSyncAt = nil
    syncStatus =
      isLiveNetworking
      ? (transportState == .connected ? .connected : .connecting)
      : .shell
    stateMachine = LobbyStateMachine()
    route = .home
    joinCode = ""
    errorMessage = nil
  }

  func dismissError() {
    errorMessage = nil
  }

  func performCreateDuel() async {
    guard operation == nil else { return }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      errorMessage = "ENTER A CALLSIGN"
      return
    }

    guard isLiveNetworking else {
      transition(.create(displayName: name, code: "VKZ001"))
      return
    }

    operation = .creating
    errorMessage = nil
    do {
      let newSession = try await environment.gameSessionClient.createDuel(
        CreateDuelRequest(displayName: name, arenaRadiusMeters: 30)
      )
      guard !Task.isCancelled else { return }
      beginSession(newSession)
    } catch {
      guard !Task.isCancelled else { return }
      operation = nil
      present(error)
    }
  }

  func performJoinDuel() async {
    guard operation == nil else { return }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      errorMessage = "ENTER A CALLSIGN"
      return
    }
    let code = Self.normalizedJoinCode(joinCode)
    guard code.utf8.count == 6 else {
      errorMessage = "DUEL CODE NOT FOUND"
      return
    }

    guard isLiveNetworking else {
      transition(.join(displayName: name, code: code))
      return
    }

    operation = .joining
    errorMessage = nil
    do {
      let newSession = try await environment.gameSessionClient.joinDuel(
        JoinDuelRequest(displayName: name, code: code)
      )
      guard !Task.isCancelled else { return }
      beginSession(newSession)
    } catch {
      guard !Task.isCancelled else { return }
      operation = nil
      present(error)
    }
  }

  func performSetReady(isReady: Bool) async {
    guard operation == nil, let session else { return }
    guard !isMatchInputLocked else {
      errorMessage = "RECONNECTING — INPUT LOCKED"
      return
    }
    operation = .settingReady
    errorMessage = nil
    do {
      try await environment.gameSessionClient.setReady(session: session, isReady: isReady)
      guard !Task.isCancelled else { return }
      operation = nil
    } catch {
      guard !Task.isCancelled else { return }
      operation = nil
      present(error)
    }
  }

  func performStartDuel() async {
    guard operation == nil, let session, let snapshot = latestSnapshot else { return }
    guard !isMatchInputLocked else {
      errorMessage = "RECONNECTING — INPUT LOCKED"
      return
    }
    guard snapshot.players.count == 2, snapshot.players.allSatisfy({ $0.ready }) else {
      errorMessage = "BOTH PLAYERS MUST BE READY"
      return
    }
    guard snapshot.players.allSatisfy({ $0.connected }) else {
      errorMessage = "BOTH PLAYERS MUST BE CONNECTED"
      return
    }
    guard snapshot.players.first(where: { $0.id == session.playerId })?.role == .host else {
      errorMessage = "SOMETHING WENT WRONG"
      return
    }

    operation = .starting
    errorMessage = nil
    do {
      try await environment.gameSessionClient.startDuel(session: session)
      guard !Task.isCancelled else { return }
      operation = nil
    } catch {
      guard !Task.isCancelled else { return }
      operation = nil
      present(error)
    }
  }

  func performDebugFire() async {
    guard isLiveNetworking, let session, let snapshot = latestSnapshot else { return }
    guard !isMatchInputLocked else {
      errorMessage = "SHOT LOCKED WHILE RECONNECTING"
      return
    }
    guard snapshot.match.phase == .running else {
      errorMessage = "SHOT LOCKED UNTIL DUEL STARTS"
      return
    }
    guard snapshot.players.first(where: { $0.id == session.playerId })?.role == .host else {
      errorMessage = "SOMETHING WENT WRONG"
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
    errorMessage = nil
    do {
      let result = try await environment.gameSessionClient.debugFire(
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
    guard isLiveNetworking, let session, let snapshot = latestSnapshot else { return }
    guard !isMatchInputLocked else {
      errorMessage = "SHOT LOCKED WHILE RECONNECTING"
      return
    }
    guard snapshot.match.phase == .running,
      let opponent = snapshot.players.first(where: { $0.id != session.playerId }),
      opponent.lifeState == .alive
    else {
      errorMessage = "PUT THE CROSSHAIR ON YOUR OPPONENT"
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
        firedAtClient: now().timeIntervalSince1970 * 1_000
      )
      pendingMarkerlessRequest = request
    }
    setMarkerlessShotState(.pending(zone: zone))
    errorMessage = nil

    do {
      let result = try await environment.gameSessionClient.fire(session: session, request: request)
      guard !Task.isCancelled else { return }
      guard result.clientShotId == request.clientShotId else {
        throw GameSessionClientError.invalidSnapshot
      }
      guard result.accepted, result.outcome != .rejected else {
        pendingMarkerlessRequest = nil
        setMarkerlessShotState(.failed(reason: result.rejectReason))
        errorMessage = Self.message(for: result.rejectReason)
        return
      }

      pendingMarkerlessRequest = nil
      setMarkerlessShotState(.confirmed(
        outcome: result.outcome,
        zone: zone,
        damage: result.damage
      ))
    } catch {
      guard !Task.isCancelled else { return }
      setMarkerlessShotState(.failed(reason: nil))
      present(error)
    }
  }

  private func beginSession(_ newSession: PlayerSession) {
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    recoveryTask?.cancel()
    killBannerTask?.cancel()
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = nil
    session = newSession
    latestSnapshot = nil
    lastSyncAt = nil
    pendingShotId = nil
    pendingShotResult = nil
    pendingShotDispatchedAt = nil
    pendingShotAutomaticReplayStarted = false
    pendingMarkerlessRequest = nil
    setDebugShotState(.idle)
    setMarkerlessShotState(.idle)
    seenKillEventIDs.removeAll()
    killBanner = nil
    snapshotSubscriptionStartedAt = nil
    syncStatus = .connecting

    startSnapshotSubscription(for: newSession)
  }

  private func startSnapshotSubscription(for expectedSession: PlayerSession) {
    let client = environment.gameSessionClient
    snapshotTask = Task { [weak self] in
      do {
        for try await snapshot in client.snapshots(for: expectedSession) {
          guard !Task.isCancelled else { return }
          self?.receive(snapshot, for: expectedSession)
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.subscriptionFailed(error, for: expectedSession)
      }
    }
  }

  private func receive(_ snapshot: MatchSnapshot, for expectedSession: PlayerSession) {
    guard session == expectedSession else { return }
    guard snapshot.match.id == expectedSession.matchId,
      snapshot.match.code == expectedSession.code,
      snapshot.localPlayerId == expectedSession.playerId,
      snapshot.players.contains(where: { $0.id == expectedSession.playerId }),
      snapshot.players.count <= 2,
      Set(snapshot.players.map(\.id)).count == snapshot.players.count,
      snapshot.players.filter({ $0.role == .host }).count == 1
    else {
      operation = nil
      syncStatus = latestSnapshot == nil ? .connecting : .stale
      present(GameSessionClientError.invalidSnapshot)
      return
    }

    let receivedAt = now()
    let previousSnapshot = latestSnapshot
    let previousSyncStatus = syncStatus
    let wasStale = syncStatus == .stale
    snapshotRetryTask?.cancel()
    snapshotRetryTask = nil
    if snapshotSubscriptionStartedAt == nil {
      snapshotSubscriptionStartedAt = snapshot.serverNow
    }
    latestSnapshot = snapshot
    lastSyncAt = receivedAt
    route = Self.route(for: snapshot, receivedAt: receivedAt)
    updateKillBanner(from: snapshot)
    let nextSyncStatus: LobbySyncStatus = wasStale ? .restored : .connected
    gameLoopTrace(
      "receive phase=\(snapshot.match.phase.rawValue) players=\(snapshot.players.count) "
        + "events=\(snapshot.events.count) serverNow=\(snapshot.serverNow) "
        + "syncStatus \(String(describing: previousSyncStatus))->\(String(describing: nextSyncStatus)) "
        + "players=\(gameLoopPlayerSummary(snapshot.players, previous: previousSnapshot))"
    )
    syncStatus = nextSyncStatus
    recoveryTask?.cancel()
    if wasStale {
      recoveryTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, self?.session == expectedSession,
          self?.syncStatus == .restored
        else {
          return
        }
        self?.syncStatus = .connected
      }
    }
    operation = nil
    errorMessage = nil
    reconcilePendingShot()
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

  private func subscriptionFailed(_ error: Error, for expectedSession: PlayerSession) {
    guard session == expectedSession else { return }
    gameLoopTrace(
      "subscriptionFailed errorType=\(String(describing: type(of: error))) "
        + "snapshotExisted=\(latestSnapshot != nil)"
    )
    operation = nil
    if latestSnapshot == nil {
      present(error)
    } else {
      syncStatus = .stale
    }
    snapshotRetryTask?.cancel()
    snapshotRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled, let self, self.session == expectedSession else {
        return
      }
      self.snapshotRetryTask = nil
      gameLoopTrace("subscriptionFailed retryResubscribe=start")
      self.startSnapshotSubscription(for: expectedSession)
    }
  }

  private func reconcilePendingShot() {
    guard let result = pendingShotResult else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noPending")
      return
    }

    guard let session, let shotId = pendingShotId else {
      gameLoopTrace("reconcilePendingShot outcome=awaiting reason=noSession")
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
    clearPendingShot()
  }

  private func schedulePendingShotDeadline(for expectedSession: PlayerSession, shotId: String) {
    pendingShotReplayTask?.cancel()
    pendingShotReplayTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(2_500))
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
      let result = try await environment.gameSessionClient.debugFire(
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

      gameLoopTrace("reconcilePendingShot reason=eventAgedOut outcome=replayConfirmed")
      clearPendingShot()
      setDebugShotState(.confirmed(damage: result.damage))
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

  private func startConnectionMonitoring() {
    guard environment.gameSessionClient.availability == .available else { return }
    let client = environment.gameSessionClient
    connectionTask = Task { [weak self] in
      for await state in client.connectionStates() {
        guard !Task.isCancelled else { return }
        self?.receiveConnection(state)
      }
    }
  }

  private func receiveConnection(_ state: GameSessionConnectionState) {
    transportState = state
    switch state {
    case .connecting:
      syncStatus = latestSnapshot == nil ? .connecting : .stale
    case .connected:
      // Transport recovery alone is not enough to unlock mutation input. A fresh
      // authoritative snapshot must arrive for this session first.
      if session == nil {
        syncStatus = .connected
      } else if latestSnapshot == nil {
        syncStatus = .connecting
      }
    }
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

#if DEBUG
  private static let gameLoopLogger = Logger(
    subsystem: "com.victoriakillzone.lobby",
    category: "GameLoop"
  )

  private func gameLoopTrace(_ message: @autoclosure () -> String) {
    let renderedMessage = message()
    Self.gameLoopLogger.debug("\(renderedMessage, privacy: .public)")
  }

  private func gameLoopPlayerSummary(
    _ players: [PlayerSnapshot],
    previous: MatchSnapshot?
  ) -> String {
    players.map { player in
      let oldPlayer = previous?.players.first(where: { $0.role == player.role })
      return "\(player.role.rawValue)"
        + " health=\(player.health)(Δ\(gameLoopDelta(player.health, oldPlayer?.health)))"
        + " ammo=\(player.ammo)(Δ\(gameLoopDelta(player.ammo, oldPlayer?.ammo)))"
        + " lifeState=\(player.lifeState.rawValue)(\(gameLoopStateDelta(player.lifeState, oldPlayer?.lifeState)))"
        + " kills=\(player.kills)(Δ\(gameLoopDelta(player.kills, oldPlayer?.kills)))"
        + " deaths=\(player.deaths)(Δ\(gameLoopDelta(player.deaths, oldPlayer?.deaths)))"
    }.joined(separator: " ")
  }

  private func gameLoopDelta(_ current: Int, _ previous: Int?) -> String {
    guard let previous else { return "n/a" }
    return String(current - previous)
  }

  private func gameLoopStateDelta(
    _ current: PlayerLifeState,
    _ previous: PlayerLifeState?
  ) -> String {
    guard let previous else { return "n/a" }
    return current == previous ? "same" : "from-\(previous.rawValue)"
  }
#else
  @inline(__always)
  private func gameLoopTrace(_ message: @autoclosure () -> String) {}

  @inline(__always)
  private func gameLoopPlayerSummary(
    _ players: [PlayerSnapshot],
    previous: MatchSnapshot?
  ) -> String {
    ""
  }
#endif

  private func schedule(_ work: @escaping @MainActor (LobbyStore) async -> Void) {
    guard actionTask == nil || actionTask?.isCancelled == true || operation == nil else { return }
    actionTask = Task { [weak self] in
      guard let self else { return }
      await work(self)
    }
  }

  private func transition(_ action: LobbyAction) {
    do {
      var next = stateMachine
      try next.send(action)
      stateMachine = next
      route = next.route
      errorMessage = nil
    } catch {
      present(error)
    }
  }

  private func present(_ error: Error) {
    if let safeError = error as? GameSessionClientError {
      errorMessage = safeError.localizedDescription
    } else if let transitionError = error as? LobbyTransitionError {
      errorMessage = transitionError.localizedDescription
    } else {
      errorMessage = "SOMETHING WENT WRONG"
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

  private static func route(for snapshot: MatchSnapshot, receivedAt: Date) -> LobbyRoute {
    let players = snapshot.players.map(LobbyPlayer.init(snapshot:))
    let hostPlayerID = snapshot.players.first(where: { $0.role == .host })?.id ?? ""

    switch snapshot.match.phase {
    case .lobby:
      return .waiting(
        WaitingRoom(
          matchID: snapshot.match.id,
          code: snapshot.match.code,
          arenaRadiusMeters: 0,
          localPlayerID: snapshot.localPlayerId,
          hostPlayerID: hostPlayerID,
          players: players
        )
      )
    case .countdown, .running, .finished, .cancelled:
      return .active(
        ActiveDuel(
          matchID: snapshot.match.id,
          code: snapshot.match.code,
          localPlayerID: snapshot.localPlayerId,
          players: players,
          phase: snapshot.match.phase,
          durationMilliseconds: snapshot.match.durationMs,
          startsAt: snapshot.match.startsAt,
          endsAt: snapshot.match.endsAt,
          serverNow: snapshot.serverNow,
          syncedAt: receivedAt,
          events: snapshot.events
        )
      )
    }
  }

  private static func normalizedJoinCode(_ value: String) -> String {
    String(
      value.uppercased().unicodeScalars.filter { scalar in
        ("A"..."Z").contains(Character(String(scalar)))
          || ("0"..."9").contains(Character(String(scalar)))
      }.prefix(6)
    )
  }
}
