import SwiftUI
import Combine

enum LobbySyncStatus: Equatable, Sendable {
  case shell
  case connecting
  case connected
  case stale
  case restored
}

enum TargetingBlocker: Equatable, Sendable {
  case cameraDenied
  case unsupportedDevice

  var title: String {
    switch self {
    case .cameraDenied: "CAMERA ACCESS REQUIRED"
    case .unsupportedDevice: "TARGETING UNAVAILABLE ON THIS DEVICE"
    }
  }

  var message: String {
    switch self {
    case .cameraDenied:
      "Pew Pew needs the rear camera to aim at the other player. Allow camera access in Settings to fire markerless shots."
    case .unsupportedDevice:
      "This device cannot run the augmented-reality targeting used for aiming. You can still watch the duel, but markerless shots are disabled."
    }
  }

  var offersSettings: Bool { self == .cameraDenied }
}

enum LobbyNetworkOperation: Equatable, Sendable {
  case creating
  case joining
  case settingReady
  case starting
  case leaving
}

@MainActor
final class LobbyStore: ObservableObject {
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
  @Published private(set) var targetingSnapshot: TargetingSnapshot {
    didSet { duel.updateTargeting(targetingSnapshot) }
  }
  @Published private(set) var targetingBlocker: TargetingBlocker?
  @Published private(set) var realtimeArena: RealtimeArenaController?

  let environment: AppEnvironment
  let duel: DuelSession
  private let now: @Sendable () -> Date

  private var stateMachine: LobbyStateMachine
  private var session: PlayerSession?
  private var latestSnapshot: MatchSnapshot?
  private var actionTask: Task<Void, Never>?
  private var snapshotTask: Task<Void, Never>?
  private var snapshotRetryTask: Task<Void, Never>?
  private var connectionTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var targetingTask: Task<Void, Never>?
  private var latestAppliedServerNow: Double?
  private var transportState = GameSessionConnectionState.connecting
  private var duelCancellable: AnyCancellable?

  init(
    environment: AppEnvironment = .phaseZeroShell,
    now: @escaping @Sendable () -> Date = { Date() },
    makeShotId: @escaping @Sendable () -> String = { UUID().uuidString },
    makePeerLink: @escaping @MainActor (_ serviceName: String) -> (any DuelPeerLink)? =
      DuelSession.defaultPeerLink
  ) {
    self.environment = environment
    self.now = now
    duel = DuelSession(
      gameSessionClient: environment.gameSessionClient,
      now: now,
      makeShotId: makeShotId,
      makePeerLink: makePeerLink
    )
    let stateMachine = LobbyStateMachine()
    self.stateMachine = stateMachine
    route = stateMachine.route
    syncStatus = environment.gameSessionClient.availability == .available ? .connecting : .shell
    targetingSnapshot = environment.targetingSession.currentSnapshot
    duel.gates = .init(
      isLiveNetworking: { [unowned self] in self.isLiveNetworking },
      isInputLocked: { [unowned self] in self.isMatchInputLocked },
      isBusy: { [unowned self] in self.operation != nil }
    )
    duel.onErrorMessage = { [weak self] in self?.errorMessage = $0 }
    duelCancellable = duel.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    duel.updateTargeting(targetingSnapshot)
    startConnectionMonitoring()
  }

  deinit {
    actionTask?.cancel()
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    connectionTask?.cancel()
    recoveryTask?.cancel()
    targetingTask?.cancel()
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

  func showJoin() {
    guard !isBusy else { return }
    transition(.showJoin)
  }

  func openInviteLink(_ url: URL) {
    guard let code = DuelInviteLink.code(from: url) else {
      errorMessage = "INVITE LINK NOT RECOGNIZED"
      return
    }

    switch route {
    case .home:
      guard !isBusy else { return }
      joinCode = code
      transition(.showJoin)
    case .join:
      guard !isBusy else { return }
      joinCode = code
    case .waiting, .active:
      return
    }
  }

  func cancelJoin() {
    guard !isBusy else { return }
    transition(.cancelJoin)
  }

  func createDuel() {
    schedule { store in await store.performCreateDuel() }
  }

  func createRealtimeArena() {
    schedule { store in await store.performCreateDuel(combatMode: .durableObject) }
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

  func startTargeting() async {
    targetingBlocker = nil
    guard environment.targetingSession.availability == .available else {
      targetingSnapshot = .unavailable()
      targetingBlocker = .unsupportedDevice
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
      targetingBlocker = .cameraDenied
    } catch {
      targetingBlocker = .unsupportedDevice
    }
  }

  func stopTargeting() async {
    targetingBlocker = nil
    targetingTask?.cancel()
    targetingTask = nil
    await environment.targetingSession.stop()
    targetingSnapshot = environment.targetingSession.currentSnapshot
  }

  func leave() {
    guard operation != .leaving else { return }
    if let realtimeArena {
      actionTask?.cancel()
      snapshotTask?.cancel()
      snapshotRetryTask?.cancel()
      recoveryTask?.cancel()
      operation = .leaving
      // The shared ARSession must finish stopping before a new lobby can use it.
      actionTask = Task { [weak self] in
        await realtimeArena.stop()
        guard let self else { return }
        self.realtimeArena = nil
        self.resetLobby()
      }
      return
    }
    resetLobby()
  }

  private func resetLobby() {
    targetingBlocker = nil
    actionTask?.cancel()
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    recoveryTask?.cancel()
    targetingTask?.cancel()
    targetingTask = nil
    let targetingSession = environment.targetingSession
    Task { await targetingSession.stop() }
    session = nil
    latestSnapshot = nil
    duel.reset()
    operation = nil
    latestAppliedServerNow = nil
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

  func performCreateDuel(combatMode: CombatMode? = nil) async {
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
        CreateDuelRequest(displayName: name, arenaRadiusMeters: 30,
          combatMode: combatMode, maxPlayers: combatMode == .durableObject ? 4 : nil)
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
    let isRealtime = snapshot.match.combatMode == .durableObject
    let capacity = isRealtime ? (snapshot.match.maxPlayers ?? 4) : 2
    guard (2...capacity).contains(snapshot.players.count), snapshot.players.allSatisfy({ $0.ready }) else {
      errorMessage = isRealtime ? "AT LEAST TWO PLAYERS, ALL READY" : "BOTH PLAYERS MUST BE READY"
      return
    }
    guard snapshot.players.allSatisfy({ $0.connected }) else {
      errorMessage = isRealtime ? "ALL PLAYERS MUST BE CONNECTED" : "BOTH PLAYERS MUST BE CONNECTED"
      return
    }
    guard snapshot.players.first(where: { $0.id == session.playerId })?.role == .host else {
      errorMessage = "SOMETHING WENT WRONG"
      return
    }

    operation = .starting
    errorMessage = nil
    do {
      if isRealtime {
        try await environment.gameSessionClient.prepareRealtimeCombat(session: session)
      } else {
        try await environment.gameSessionClient.startDuel(session: session)
      }
      guard !Task.isCancelled else { return }
      operation = nil
    } catch {
      guard !Task.isCancelled else { return }
      operation = nil
      present(error)
    }
  }

  private func beginSession(_ newSession: PlayerSession) {
    snapshotTask?.cancel()
    snapshotRetryTask?.cancel()
    recoveryTask?.cancel()
    session = newSession
    latestSnapshot = nil
    lastSyncAt = nil
    duel.attach(session: newSession)
    latestAppliedServerNow = nil
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
      snapshot.players.count <= (snapshot.match.combatMode == .durableObject ? 4 : 2),
      snapshot.match.maxPlayers.map({ (2...4).contains($0) && snapshot.players.count <= $0 }) ?? true,
      Set(snapshot.players.map(\.id)).count == snapshot.players.count,
      snapshot.players.filter({ $0.role == .host }).count == 1
    else {
      operation = nil
      syncStatus = latestSnapshot == nil ? .connecting : .stale
      present(GameSessionClientError.invalidSnapshot)
      return
    }

    // Reordered delivery must never move authoritative state backwards. Equal
    // server timestamps are applied: the backend stamps snapshots with
    // millisecond `Date.now()`, so two snapshots can share a timestamp.
    if let appliedServerNow = latestAppliedServerNow, snapshot.serverNow < appliedServerNow {
      gameLoopTrace(
        "receive outcome=ignored reason=staleServerNow serverNow=\(snapshot.serverNow) "
          + "latestAppliedServerNow=\(appliedServerNow)"
      )
      return
    }

    let receivedAt = now()
    let previousSnapshot = latestSnapshot
    let previousSyncStatus = syncStatus
    let wasStale = syncStatus == .stale
    snapshotRetryTask?.cancel()
    snapshotRetryTask = nil
    latestSnapshot = snapshot
    latestAppliedServerNow = snapshot.serverNow
    lastSyncAt = receivedAt
    route = Self.route(for: snapshot, receivedAt: receivedAt)
    if snapshot.match.combatMode == .durableObject {
      if snapshot.match.phase != .lobby, realtimeArena == nil {
        duel.reset()
        realtimeArena = RealtimeArenaController(session: expectedSession,
          client: environment.gameSessionClient, targeting: environment.targetingSession)
      }
    } else {
      duel.receive(snapshot)
    }
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

  private func gameLoopTrace(_ message: @autoclosure () -> String) {
    GameLoopTrace.trace(message())
  }

#if DEBUG
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
          players: players,
          combatMode: snapshot.match.combatMode,
          maxPlayers: snapshot.match.maxPlayers ?? (snapshot.match.combatMode == .durableObject ? 4 : 2)
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

  nonisolated static func normalizedJoinCode(_ value: String) -> String {
    String(
      value.uppercased().unicodeScalars.filter { scalar in
        ("A"..."Z").contains(Character(String(scalar)))
          || ("0"..."9").contains(Character(String(scalar)))
      }.prefix(6)
    )
  }
}
