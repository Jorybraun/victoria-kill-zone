import Combine
import Foundation

enum RealtimeConnectionState: Equatable {case disconnected, connecting, synchronizing, connected, retrying, finished}

/// Owns one authenticated authority connection, bounded exact-retry commands,
/// clock synchronization and the replica consumed by the game presentation.
@MainActor
final class RealtimeCombatSession: ObservableObject {
  @Published private(set) var state: RealtimeConnectionState = .disconnected
  @Published private(set) var snapshot: CombatWire.Snapshot?
  @Published private(set) var events: [CombatWire.ServerEvent] = []
  @Published private(set) var clockReady = false
  @Published private(set) var clockUncertaintyMs = Double.infinity
  @Published private(set) var refusal: String?
  private(set) var latestAccessTicket: CombatAccessTicket?

  private let gameClient: any GameSessionClient
  private let makeTransport: @MainActor () -> any CombatSocketConnecting
  private let localNow: @Sendable () -> Double
  private var transport: (any CombatSocketConnecting)?
  private var session: PlayerSession?
  private var replica: CombatReplica?
  private var clock = CombatClock()
  private var pending: [Int:CombatWire.Envelope] = [:]
  private var outgoing: [CombatWire.Envelope] = []
  private var pings: [String:Double] = [:]
  private var nextSequence = 1
  private var runner: Task<Void,Never>?
  private var ticker: Task<Void,Never>?
  private var writer: Task<Void,Never>?
  private var writerGeneration = 0
  private var generation = 0
  private var receivedSnapshot = false

  init(gameClient: any GameSessionClient,
       makeTransport: @escaping @MainActor () -> any CombatSocketConnecting = {CombatSocketTransport()},
       localNow: @escaping @Sendable () -> Double = {ProcessInfo.processInfo.systemUptime * 1000}) {
    self.gameClient=gameClient; self.makeTransport=makeTransport; self.localNow=localNow
  }

  var matchTimeMs: Double? {clock.matchTime(at:localNow())}
  var localPlayer: CombatWire.Player? {snapshot?.players.first(where:{$0.playerId == session?.playerId})}
  var hasCommandCapacity: Bool {pending.count < 32}
  var canSubmitSpatialInput: Bool {state == .connected && clockReady && receivedSnapshot && hasCommandCapacity}

  func start(session: PlayerSession) {
    if self.session == session, runner != nil {return}
    stop()
    self.session=session; replica=CombatReplica(matchID:session.matchId,localPlayerID:session.playerId)
    let current=generation
    state = .connecting
    runner=Task { [weak self] in
      var attempts=0
      while !Task.isCancelled {
        guard let self, self.generation == current else {return}
        do {
          let ticket=try await self.gameClient.combatTicket(session:session)
          guard !Task.isCancelled, self.generation == current else {return}
          self.latestAccessTicket=ticket
          let transport=self.makeTransport(); self.transport=transport
          let messages=try transport.connect(ticket:ticket)
          self.state = .synchronizing; self.receivedSnapshot=false; self.clock.reset()
          self.startClockPump(generation:current)
          for try await message in messages {
            guard !Task.isCancelled, self.generation == current else {return}
            try await self.receive(message)
            if self.receivedSnapshot {attempts=0}
          }
        } catch {
          // User-facing status is deliberately independent of raw transport errors.
        }
        guard !Task.isCancelled, self.generation == current else {return}
        self.disconnectTransport()
        if self.snapshot?.phase == .finished {self.state = .finished; return}
        self.state = .retrying
        attempts += 1
        let delay=min(10.0,pow(2.0,Double(min(attempts - 1,4))))
        do {try await Task.sleep(for:.seconds(delay + Double.random(in:0...0.25)))} catch {return}
      }
    }
  }

  /// Refuse locally when disconnected; the authority independently checks all rules.
  @discardableResult
  func submit(_ command: CombatWire.Command) -> String? {
    guard canSubmitSpatialInput, let snapshot, let time=matchTimeMs else {return nil}
    let id=UUID().uuidString
    let envelope=CombatWire.Envelope(commandId:id,clientSequence:nextSequence,authorityEpoch:snapshot.authorityEpoch,frameEpoch:snapshot.frameEpoch,sentAtMs:time,command:command)
    nextSequence += 1; pending[envelope.clientSequence]=envelope; outgoing.append(envelope)
    startWriter()
    return id
  }

  func stop() {
    generation += 1
    runner?.cancel(); runner=nil
    disconnectTransport()
    pending.removeAll(); replica=nil; snapshot=nil; events=[]; session=nil
    latestAccessTicket=nil
    nextSequence=1; refusal=nil; state = .disconnected
  }

  private func disconnectTransport() {
    ticker?.cancel(); ticker=nil; writerGeneration += 1; writer?.cancel(); writer=nil
    transport?.close(); transport=nil
    outgoing.removeAll(); pings.removeAll(); receivedSnapshot=false
    clock.reset(); clockReady=false; clockUncertaintyMs = .infinity
  }

  private func receive(_ message: CombatWire.ServerMessage) async throws {
    guard var replica else {throw CombatReplicaError.invalidSnapshot}
    switch message {
    case .snapshot(let next,let eventSequence,let clientSequence):
      let changedEpoch=try replica.replace(next,eventSequence:eventSequence,clientSequence:clientSequence)
      if changedEpoch {pending.removeAll(); outgoing.removeAll(); clock.reset(); clockReady=false}
      pending=pending.filter {$0.key > clientSequence && $0.value.authorityEpoch == next.authorityEpoch && $0.value.frameEpoch == next.frameEpoch}
      let replay=pending.values.sorted {$0.clientSequence < $1.clientSequence}
      // A missing locally retained sequence cannot be fabricated. A fresh snapshot
      // is authoritative, so abandon only unconfirmed commands beyond that gap.
      if replay.enumerated().contains(where:{$0.element.clientSequence != clientSequence + $0.offset + 1}) {pending.removeAll()}
      nextSequence=max(clientSequence,pending.keys.max() ?? clientSequence) + 1
      writerGeneration += 1; writer?.cancel(); writer=nil
      outgoing=pending.values.sorted {$0.clientSequence < $1.clientSequence}
      self.replica=replica; self.snapshot=replica.snapshot; receivedSnapshot=true
      state = next.phase == .finished ? .finished : .connected
      startWriter()
      try await transport?.send(.received(eventSequence:eventSequence))
    case .events(let incoming):
      do {
        let fresh=try replica.apply(incoming)
        self.replica=replica; self.snapshot=replica.snapshot
        if receivedSnapshot && state == .synchronizing {state = .connected}
        if !fresh.isEmpty {events=fresh}
        for event in fresh {
          if case .commandResult(_,_,let player,false,let reason)=event.event, player == session?.playerId {refusal=reason}
        }
        if snapshot?.phase == .finished {state = .finished}
        try await transport?.send(.received(eventSequence:replica.eventSequence))
      } catch CombatReplicaError.eventGap {
        state = .synchronizing
        try await transport?.send(.resume(afterEventSequence:replica.eventSequence))
      }
    case .ack(let id,let sequence,_,_):
      if pending[sequence]?.commandId == id {pending.removeValue(forKey:sequence)}
    case .pong(let nonce,let sent,let received,let serverSent):
      guard let localSent=pings.removeValue(forKey:nonce), localSent == sent else {return}
      _ = clock.observe(localSentMs:localSent,serverReceivedMs:received,serverSentMs:serverSent,localReceivedMs:localNow())
      clockReady=clock.isReady(at:localNow()); clockUncertaintyMs=clock.uncertaintyMs
    case .error(let code,_):
      refusal=code
      if ["epochMismatch","replayExpired","sequenceConflict","idempotencyConflict"].contains(code) {
        state = .synchronizing
        try await transport?.send(.resume(afterEventSequence:replica.eventSequence))
      } else if code == "unauthorized" || code == "unavailable" {throw CombatTransportError.disconnected}
    }
  }

  private func startWriter() {
    guard writer == nil, transport != nil, !outgoing.isEmpty else {return}
    let current=generation
    writerGeneration += 1
    let currentWriter=writerGeneration
    writer=Task { [weak self] in
      guard let self else {return}
      defer {if self.generation == current && self.writerGeneration == currentWriter {self.writer=nil}}
      do {
        while !Task.isCancelled && self.generation == current && !self.outgoing.isEmpty {
          let next=self.outgoing.removeFirst()
          try await self.transport?.send(.command(next))
        }
      } catch {self.transport?.close()}
    }
  }

  private func startClockPump(generation current: Int) {
    ticker?.cancel()
    ticker=Task { [weak self] in
      var count=0
      while !Task.isCancelled {
        guard let self, self.generation == current else {return}
        let now=self.localNow(), nonce=UUID().uuidString
        self.pings=self.pings.filter {now - $0.value <= 5000}
        self.pings[nonce]=now
        self.clockReady=self.clock.isReady(at:now)
        do {
          try await self.transport?.send(.ping(nonce:nonce,clientSentAtMs:now))
          count += 1
          try await Task.sleep(for:.milliseconds(count < 5 ? 100 : 1000))
        } catch {self.transport?.close(); return}
      }
    }
  }
}
