import SwiftUI

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
  @Published private(set) var debugShotState = DebugShotState.idle

  let environment: AppEnvironment

  private var stateMachine: LobbyStateMachine
  private var session: PlayerSession?
  private var latestSnapshot: MatchSnapshot?
  private var pendingShotId: String?
  private var pendingShotResult: DebugFireResult?
  private var actionTask: Task<Void, Never>?
  private var snapshotTask: Task<Void, Never>?
  private var connectionTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
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
    startConnectionMonitoring()
  }

  deinit {
    actionTask?.cancel()
    snapshotTask?.cancel()
    connectionTask?.cancel()
    recoveryTask?.cancel()
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
    switch environment.targetingSession.availability {
    case .available: "BODY LOCK"
    case .notConfigured: "TARGETING SHELL"
    }
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

  func isNetworkFresh(at date: Date) -> Bool {
    guard let lastSyncAt, date >= lastSyncAt else { return false }
    return !isMatchInputLocked && (syncStatus == .connected || syncStatus == .restored)
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

  func leave() {
    actionTask?.cancel()
    snapshotTask?.cancel()
    recoveryTask?.cancel()
    session = nil
    latestSnapshot = nil
    pendingShotId = nil
    pendingShotResult = nil
    operation = nil
    debugShotState = .idle
    lastSyncAt = nil
    syncStatus = isLiveNetworking
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
    debugShotState = .pending
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
        debugShotState = .failed
        if let reason = result.rejectReason {
          present(GameSessionClientError.backend(reason))
        } else {
          present(GameSessionClientError.unknown)
        }
        return
      }
      pendingShotResult = result
      reconcilePendingShot()
    } catch {
      guard !Task.isCancelled else { return }
      debugShotState = .failed
      present(error)
    }
  }

  private func beginSession(_ newSession: PlayerSession) {
    snapshotTask?.cancel()
    recoveryTask?.cancel()
    session = newSession
    latestSnapshot = nil
    lastSyncAt = nil
    pendingShotId = nil
    pendingShotResult = nil
    debugShotState = .idle
    syncStatus = .connecting

    let client = environment.gameSessionClient
    snapshotTask = Task { [weak self] in
      do {
        for try await snapshot in client.snapshots(for: newSession) {
          guard !Task.isCancelled else { return }
          self?.receive(snapshot, for: newSession)
        }
      } catch {
        guard !Task.isCancelled else { return }
        self?.subscriptionFailed(error, for: newSession)
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
    let wasStale = syncStatus == .stale
    latestSnapshot = snapshot
    lastSyncAt = receivedAt
    route = Self.route(for: snapshot, receivedAt: receivedAt)
    syncStatus = wasStale ? .restored : .connected
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

  private func subscriptionFailed(_ error: Error, for expectedSession: PlayerSession) {
    guard session == expectedSession else { return }
    operation = nil
    if latestSnapshot == nil {
      present(error)
    } else {
      syncStatus = .stale
    }
  }

  private func reconcilePendingShot() {
    guard let result = pendingShotResult, let session, let snapshot = latestSnapshot,
      let shooter = snapshot.players.first(where: { $0.id == session.playerId }),
      let target = snapshot.players.first(where: { $0.id != session.playerId }),
      shooter.ammo == result.shooterAmmo, target.health == result.targetHealth
    else {
      return
    }

    if let eventId = result.eventId,
      !snapshot.events.contains(where: { $0.id == eventId })
    {
      return
    }

    debugShotState = .confirmed(damage: result.damage)
    pendingShotResult = nil
    pendingShotId = nil
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
