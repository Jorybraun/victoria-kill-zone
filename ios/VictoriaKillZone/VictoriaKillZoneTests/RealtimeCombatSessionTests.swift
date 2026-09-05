import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class RealtimeCombatSessionTests: XCTestCase {
  func testClockHandshakeAndBoundedExactCommandWindow() async throws {
    let socket=ScriptedCombatSocket()
    let game=RealtimeCombatSession(gameClient:TicketOnlyClient(),makeTransport:{socket},localNow:{1000})
    defer {game.stop()}
    game.start(session:Self.playerSession())
    try await until {game.clockReady}
    XCTAssertEqual(game.state,.connected)
    for _ in 0..<32 {XCTAssertNotNil(game.submit(.reload))}
    XCTAssertNil(game.submit(.reload))
    try await until {socket.commands.count == 32}
    XCTAssertEqual(socket.commands.map(\.clientSequence),Array(1...32))
    let first=try XCTUnwrap(socket.commands.first)
    socket.output?.yield(.ack(commandId:first.commandId,clientSequence:first.clientSequence,replayed:false,eventSequence:0))
    try await until {game.hasCommandCapacity}
    XCTAssertNotNil(game.submit(.reload))
  }

  func testLostAcknowledgementReplaysExactIdentityAfterReconnect() async throws {
    let socket=ScriptedCombatSocket()
    let game=RealtimeCombatSession(gameClient:TicketOnlyClient(),makeTransport:{socket},localNow:{1000})
    defer {game.stop()}
    game.start(session:Self.playerSession()); try await until {game.clockReady}
    let id=try XCTUnwrap(game.submit(.reload)); try await until {socket.commands.count == 1}
    socket.output?.finish()
    try await until(timeout:3) {socket.commands.count >= 2}
    XCTAssertEqual(socket.commands.map(\.commandId),[id,id])
    XCTAssertEqual(socket.commands.map(\.clientSequence),[1,1])
  }

  func testNewAuthorityCancelsUnconfirmedOldEpochCommands() async throws {
    let socket=ScriptedCombatSocket()
    let game=RealtimeCombatSession(gameClient:TicketOnlyClient(),makeTransport:{socket},localNow:{1000})
    defer {game.stop()}
    game.start(session:Self.playerSession()); try await until {game.clockReady}
    _ = game.submit(.reload); try await until {socket.commands.count == 1}
    var recovered=RealtimeCombatTests.snapshot(); recovered.authorityEpoch=2; recovered.phase = .paused
    socket.output?.yield(.snapshot(recovered,eventSequence:4,clientSequence:0))
    try await until {game.snapshot?.authorityEpoch == 2}
    XCTAssertFalse(game.clockReady)
    XCTAssertNil(game.submit(.reload))
    XCTAssertEqual(socket.commands.count,1)
  }

  func testMapTransferPathNeverCarriesCredentialsAndRejectsWrongEpoch() throws {
    let ticket=try TicketOnlyClient.access()
    let request=try CombatMapClient.request(ticket:ticket,epoch:1)
    XCTAssertEqual(request.url?.path,"/v1/matches/match/frames/1/map")
    XCTAssertNil(request.url?.query)
    XCTAssertThrowsError(try CombatMapClient.request(ticket:ticket,epoch:2))
  }

  func testClockDiscontinuityClosesAuthorityConnectionBeforeFurtherInput() async throws {
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: TicketOnlyClient(), makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession())
    try await until {game.clockReady}
    socket.serverTime = 1000
    try await until {socket.closeCount > 0}
    XCTAssertFalse(game.clockReady)
    XCTAssertNil(game.submit(.reload))
  }

  func testPermanentTicketFailureStopsAutomaticRetryAndExplicitRetryRefreshesAccess() async throws {
    let client = ControlledTicketClient(errors: [.backend(.invalidSession)])
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: client, makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession())
    try await until {game.connectionIssue != nil}
    XCTAssertEqual(game.state, .disconnected)
    XCTAssertFalse(game.clockReady)
    XCTAssertNil(game.submit(.reload))
    try await Task.sleep(for: .milliseconds(1300))
    let callsBeforeRetry = await client.calls
    XCTAssertEqual(callsBeforeRetry, 1, "Permanent admission must not spin")
    game.retryConnection()
    try await until {game.clockReady}
    let callsAfterRetry = await client.calls
    XCTAssertEqual(callsAfterRetry, 2)
    XCTAssertNil(game.connectionIssue)
    XCTAssertEqual(game.state, .connected)
  }

  func testConfigurationAndMissingMatchErrorsProduceActionableTerminalStates() async throws {
    for error in [GameSessionClientError.notConfigured, .backend(.matchNotFound), .backend(.matchAlreadyFinished), .invalidSnapshot] {
      let game = RealtimeCombatSession(gameClient: ControlledTicketClient(errors: [error]), localNow: {1000})
      game.start(session: Self.playerSession())
      try await until {game.connectionIssue != nil}
      XCTAssertEqual(game.state, .disconnected)
      XCTAssertTrue(game.connectionIssue?.contains("leave") == true || game.connectionIssue?.contains("Leave") == true)
      game.stop()
    }
  }

  func testRepeatedTransientFailuresExposeFeedbackAndRecoverAutomatically() async throws {
    let client = ControlledTicketClient(errors: [.networkUnavailable, .backend(.combatUnavailable), .networkUnavailable])
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: client, makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession())
    try await until(timeout: 5) {game.connectionIssue != nil}
    XCTAssertEqual(game.state, .retrying)
    XCTAssertTrue(game.connectionIssue?.contains("Wi-Fi") == true)
    try await until(timeout: 6) {game.clockReady}
    let calls = await client.calls
    XCTAssertEqual(calls, 4)
    XCTAssertNil(game.connectionIssue)
  }

  func testExplicitRetryPreservesExactPendingCommandsAndSnapshotRevision() async throws {
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: TicketOnlyClient(), makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession()); try await until {game.clockReady}
    let revision = game.snapshotRevision
    let id = try XCTUnwrap(game.submit(.reload))
    try await until {socket.commands.count == 1}
    XCTAssertEqual(game.pendingCommandIDs, [id])
    game.retryConnection()
    try await until {game.clockReady && socket.commands.count == 2}
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(try encoder.encode(socket.commands[0]), try encoder.encode(socket.commands[1]))
    XCTAssertEqual(game.pendingCommandIDs, [id])
    XCTAssertGreaterThan(game.snapshotRevision, revision)
    let replayRevision = game.snapshotRevision
    let command = socket.commands[1]
    socket.output?.yield(.ack(commandId: id, clientSequence: command.clientSequence, replayed: true, eventSequence: 0))
    try await until {game.pendingCommandIDs.isEmpty}
    XCTAssertEqual(game.snapshotRevision, replayRevision, "A receipt is not a full snapshot")
    socket.output?.yield(.events([RealtimeCombatTests.event(1, .commandResult(commandId: id, clientSequence: 1, playerId: "p1", accepted: false, reason: "notRunning"))]))
    try await until {game.events.count == 1}
    XCTAssertEqual(game.snapshotRevision, replayRevision, "An event projection is not a full snapshot")
    game.stop()
    XCTAssertEqual(game.snapshotRevision, replayRevision)
  }

  func testCancelledTicketCompletionCannotReplaceNewConnection() async throws {
    let client = ControlledTicketClient(gateFirst: true)
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: client, makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession())
    await client.waitForFirstRequest()
    game.retryConnection()
    try await until {game.clockReady}
    let revision = game.snapshotRevision
    await client.finishFirstRequest(with: .backend(.invalidSession))
    for _ in 0..<10 {await Task.yield()}
    XCTAssertEqual(game.state, .connected)
    XCTAssertNil(game.connectionIssue)
    XCTAssertEqual(game.snapshotRevision, revision)
    XCTAssertEqual(socket.connectCount, 1)
  }

  func testCancelledWriterFailureCannotCloseReplacementSocket() async throws {
    let first = ScriptedCombatSocket(); first.suspendNextCommand = true
    let second = ScriptedCombatSocket()
    var connections = 0
    let game = RealtimeCombatSession(gameClient: TicketOnlyClient(), makeTransport: {
      connections += 1
      return connections == 1 ? first : second
    }, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession()); try await until {game.clockReady}
    _ = game.submit(.reload)
    try await until {first.commandContinuation != nil}
    game.retryConnection()
    try await until {game.clockReady && second.commands.count == 1}
    first.commandContinuation?.resume(throwing: CombatTransportError.disconnected)
    first.commandContinuation = nil
    for _ in 0..<10 {await Task.yield()}
    XCTAssertEqual(second.closeCount, 0)
    XCTAssertEqual(game.state, .connected)
  }

  func testHTTPAdmissionFailuresUseOnlySanitizedClassification() throws {
    let url = try XCTUnwrap(URL(string: "https://combat.example.test/connect"))
    let raw = NSError(domain: "untrusted-server-error", code: 1)
    for status in [400, 401, 403, 404, 409, 426] {
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
      XCTAssertEqual(CombatSocketTransport.safeFailure(raw, response: response), .admissionRejected)
    }
    for status in [408, 425, 429, 500, 502, 503] {
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
      XCTAssertEqual(CombatSocketTransport.safeFailure(raw, response: response), .disconnected)
    }
  }

  func testSuspendingQueuedReadinessClosesSocketUntilExplicitForegroundRetry() async throws {
    let client = ControlledTicketClient()
    let first = ScriptedCombatSocket()
    let second = ScriptedCombatSocket()
    second.initialSnapshot.players[0].frameReady = false
    var connections = 0
    let game = RealtimeCombatSession(gameClient: client, makeTransport: {
      connections += 1
      return connections == 1 ? first : second
    }, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession()); try await until {game.clockReady}
    let id = try XCTUnwrap(game.submit(.frameReady(ready: true, residualMeters: 0.02,
      residualDegrees: 0.1, clockUncertaintyMs: 1)))
    try await until {first.commands.count == 1}
    let priorSnapshotRevision = game.snapshotRevision
    let stalePing = try XCTUnwrap(first.lastPing)
    game.suspendConnection()
    XCTAssertEqual(game.state, .disconnected)
    XCTAssertTrue(game.connectionSuspended)
    XCTAssertFalse(game.clockReady)
    XCTAssertNil(game.matchTimeMs)
    XCTAssertNil(game.submit(.reload))
    XCTAssertEqual(first.closeCount, 1)
    XCTAssertEqual(game.pendingCommandIDs, [id])
    XCTAssertNotNil(game.snapshot, "Suspension retains the last confirmed score")
    try await Task.sleep(for: .milliseconds(1300))
    let suspendedTicketCalls = await client.calls
    XCTAssertEqual(suspendedTicketCalls, 1)
    XCTAssertEqual(connections, 1)

    game.retryConnection()
    try await until {game.clockReady && second.commands.count == 1}
    XCTAssertFalse(game.connectionSuspended)
    XCTAssertEqual(game.localPlayer?.frameReady, false, "Reconnect starts from fresh authority readiness")
    XCTAssertGreaterThan(game.snapshotRevision, priorSnapshotRevision)
    XCTAssertEqual(second.commands.first?.commandId, id)
    let foregroundTicketCalls = await client.calls
    XCTAssertEqual(foregroundTicketCalls, 2)
    // A delayed old ping cannot poison the new clock even if a transport
    // delivers it through the replacement stream.
    second.output?.yield(.pong(nonce: stalePing.nonce, clientSentAtMs: stalePing.sent,
      serverReceivedAtMs: 1_000_000, serverSentAtMs: 1_000_000))
    for _ in 0..<10 {await Task.yield()}
    XCTAssertTrue(game.clockReady)
    XCTAssertEqual(game.state, .connected)
    XCTAssertEqual(second.closeCount, 0)
  }

  func testSuspendingPendingTicketIgnoresItsLateCompletion() async throws {
    let client = ControlledTicketClient(gateFirst: true)
    let socket = ScriptedCombatSocket()
    let game = RealtimeCombatSession(gameClient: client, makeTransport: {socket}, localNow: {1000})
    defer {game.stop()}
    game.start(session: Self.playerSession())
    await client.waitForFirstRequest()
    game.suspendConnection()
    try await client.finishFirstRequestWithTicket()
    for _ in 0..<10 {await Task.yield()}
    XCTAssertTrue(game.connectionSuspended)
    XCTAssertEqual(game.state, .disconnected)
    XCTAssertEqual(socket.connectCount, 0)
    XCTAssertNil(game.latestAccessTicket)
    game.retryConnection()
    try await until {game.clockReady}
    XCTAssertEqual(socket.connectCount, 1)
  }

  func testSuspendingFatalOrFinishedConnectionDoesNotScheduleForegroundRetry() async throws {
    let fatal = RealtimeCombatSession(gameClient: ControlledTicketClient(errors: [.backend(.invalidSession)]))
    defer {fatal.stop()}
    fatal.start(session: Self.playerSession())
    try await until {fatal.connectionIssue != nil}
    let issue = fatal.connectionIssue
    fatal.suspendConnection()
    XCTAssertFalse(fatal.connectionSuspended)
    XCTAssertEqual(fatal.connectionIssue, issue)
    XCTAssertEqual(fatal.state, .disconnected)

    let socket = ScriptedCombatSocket(); socket.initialSnapshot.phase = .finished
    let finished = RealtimeCombatSession(gameClient: TicketOnlyClient(), makeTransport: {socket})
    defer {finished.stop()}
    finished.start(session: Self.playerSession())
    try await until {finished.state == .finished}
    finished.suspendConnection()
    XCTAssertFalse(finished.connectionSuspended)
    XCTAssertEqual(finished.state, .finished)
    finished.retryConnection()
    XCTAssertEqual(socket.connectCount, 1)
  }

  private static func playerSession() -> PlayerSession {
    .init(matchId:"match",code:"ABCDEF",playerId:"p1",sessionSecret:UUID().uuidString)
  }
  private func until(timeout: TimeInterval=2,_ predicate: @MainActor () -> Bool) async throws {
    let deadline=Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {try await Task.sleep(for:.milliseconds(10))}
    XCTAssertTrue(predicate(),"Expected native session state did not arrive")
    if !predicate() {throw CombatTransportError.disconnected}
  }
}

@MainActor
private final class ScriptedCombatSocket: CombatSocketConnecting {
  var output: AsyncThrowingStream<CombatWire.ServerMessage,Error>.Continuation?
  var commands: [CombatWire.Envelope] = []
  var serverTime: Double = 0
  var closeCount = 0
  var connectCount = 0
  var suspendNextCommand = false
  var commandContinuation: CheckedContinuation<Void, Error>?
  var initialSnapshot = RealtimeCombatTests.snapshot()
  var lastPing: (nonce: String, sent: Double)?
  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage,Error> {
    connectCount += 1
    let pair=AsyncThrowingStream<CombatWire.ServerMessage,Error>.makeStream()
    output=pair.continuation
    output?.yield(.snapshot(initialSnapshot,eventSequence:0,clientSequence:0))
    return pair.stream
  }
  func send(_ message: CombatWire.ClientMessage) async throws {
    switch message {
    case .command(let command):
      commands.append(command)
      if suspendNextCommand {
        suspendNextCommand = false
        try await withCheckedThrowingContinuation {commandContinuation = $0}
      }
    case .ping(let nonce,let sent):
      lastPing = (nonce, sent)
      output?.yield(.pong(nonce:nonce,clientSentAtMs:sent,serverReceivedAtMs:serverTime,serverSentAtMs:serverTime))
    default: break
    }
  }
  func close() {closeCount += 1; output?.finish(); output=nil}
}

private actor ControlledTicketClient: GameSessionClient {
  nonisolated let availability = GameSessionAvailability.available
  private var errors: [GameSessionClientError]
  private let gateFirst: Bool
  private var firstRequest: CheckedContinuation<CombatAccessTicket, Error>?
  private var firstRequestObserver: CheckedContinuation<Void, Never>?
  private(set) var calls = 0
  init(errors: [GameSessionClientError] = [], gateFirst: Bool = false) {self.errors = errors; self.gateFirst = gateFirst}
  func combatTicket(session: PlayerSession) async throws -> CombatAccessTicket {
    calls += 1
    if gateFirst && calls == 1 {
      return try await withCheckedThrowingContinuation {
        firstRequest = $0
        firstRequestObserver?.resume(); firstRequestObserver = nil
      }
    }
    if !errors.isEmpty {throw errors.removeFirst()}
    return try TicketOnlyClient.access()
  }
  func waitForFirstRequest() async {
    if calls > 0 {return}
    await withCheckedContinuation {firstRequestObserver = $0}
  }
  func finishFirstRequest(with error: GameSessionClientError) {firstRequest?.resume(throwing: error); firstRequest = nil}
  func finishFirstRequestWithTicket() throws {firstRequest?.resume(returning: try TicketOnlyClient.access()); firstRequest = nil}
  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func setReady(session: PlayerSession, isReady: Bool) async throws {}
  func startDuel(session: PlayerSession) async throws {}
  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {throw GameSessionClientError.notConfigured}
  nonisolated func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {AsyncThrowingStream {$0.finish()}}
  nonisolated func connectionStates() -> AsyncStream<GameSessionConnectionState> {AsyncStream {$0.finish()}}
}

private struct TicketOnlyClient: GameSessionClient {
  let availability = GameSessionAvailability.available
  static func access() throws -> CombatAccessTicket {
    CombatAccessTicket(endpoint:try XCTUnwrap(URL(string:"https://combat.example.test/v1/matches/match/connect")),token:UUID().uuidString,expiresAt:Date().addingTimeInterval(120),authorityEpoch:1,frameEpoch:1)
  }
  func combatTicket(session: PlayerSession) async throws -> CombatAccessTicket {try Self.access()}
  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func setReady(session: PlayerSession,isReady: Bool) async throws {throw GameSessionClientError.notConfigured}
  func startDuel(session: PlayerSession) async throws {throw GameSessionClientError.notConfigured}
  func debugFire(session: PlayerSession,clientShotId: String) async throws -> DebugFireResult {throw GameSessionClientError.notConfigured}
  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot,Error> {AsyncThrowingStream {$0.finish()}}
  func connectionStates() -> AsyncStream<GameSessionConnectionState> {AsyncStream {$0.finish()}}
}
