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
  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage,Error> {
    let pair=AsyncThrowingStream<CombatWire.ServerMessage,Error>.makeStream()
    output=pair.continuation
    output?.yield(.snapshot(RealtimeCombatTests.snapshot(),eventSequence:0,clientSequence:0))
    return pair.stream
  }
  func send(_ message: CombatWire.ClientMessage) async throws {
    switch message {
    case .command(let command): commands.append(command)
    case .ping(let nonce,let sent): output?.yield(.pong(nonce:nonce,clientSentAtMs:sent,serverReceivedAtMs:0,serverSentAtMs:0))
    default: break
    }
  }
  func close() {output?.finish(); output=nil}
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
