import CombatTransport
import Foundation

enum ArenaClock {
  static func nowMs() -> Int64 {
    Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded())
  }
}

enum ArenaPeerLinkState: Equatable, Sendable {
  case idle
  case advertising
  case browsing
  case connecting
  case connected
  case failed(String)

  var label: String {
    switch self {
    case .idle: "idle"
    case .advertising: "advertising"
    case .browsing: "browsing"
    case .connecting: "connecting"
    case .connected: "connected"
    case .failed(let reason): "failed:\(reason)"
    }
  }
}

struct ArenaPeerLinkStats: Equatable, Sendable {
  var bytesIn = 0
  var bytesOut = 0
  var framingErrors = 0
}

protocol ArenaPeerLinking: AnyObject {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)? { get set }
  var onStateChange: ((ArenaPeerLinkState) -> Void)? { get set }
  var stats: ArenaPeerLinkStats { get }
  func start(role: ArenaRole)
  func stop()
  func send(_ message: ArenaLinkMessage)
}

final class CombatTransportArenaLink: ArenaPeerLinking, @unchecked Sendable {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)?
  var onStateChange: ((ArenaPeerLinkState) -> Void)?

  private let scope: MatchScope
  private let playerId: String
  private let joinSecret: String
  private let identity: (any TransportIdentityProvider)?
  private let linkFactory: ((ArenaRole) -> any PeerLink)?
  private let queue = DispatchQueue(
    label: "com.victoriakillzone.arena.combat-link",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var _stats = ArenaPeerLinkStats()
  private var mapper: ArenaLinkFrameMapper?
  private var orderer = ReliableEventOrderer()
  private var link: (any PeerLink)?
  private var role: ArenaRole?
  private var state: ArenaPeerLinkState = .idle
  private var helloVerified = false
  /// Queue-owned lifetime token; removing a handler cannot cancel callbacks
  /// already captured or enqueued by a stopped endpoint.
  private var generation: UInt64 = 0

  var stats: ArenaPeerLinkStats {
    lock.withLock { _stats }
  }

  /// Without an identity the QUIC handshake cannot complete on device; the ephemeral per-match identity provider is a follow-up (see ADR 0004 'Transport integration').
  init(
    matchId: String,
    playerId: String,
    joinSecret: String,
    identity: (any TransportIdentityProvider)? = nil
  ) {
    scope = MatchScope(matchId: matchId)
    self.playerId = playerId
    self.joinSecret = joinSecret
    self.identity = identity
    linkFactory = nil
  }

  init(
    matchId: String,
    playerId: String,
    joinSecret: String,
    linkFactory: @escaping (ArenaRole) -> any PeerLink,
    identity: (any TransportIdentityProvider)? = nil
  ) {
    scope = MatchScope(matchId: matchId)
    self.playerId = playerId
    self.joinSecret = joinSecret
    self.identity = identity
    self.linkFactory = linkFactory
  }

  func start(role: ArenaRole) {
    queue.async { [self] in
      stopLocked(publish: false)
      self.role = role
      let generation = self.generation
      let endpoint: any PeerLink
      if let linkFactory {
        endpoint = linkFactory(role)
      } else {
        do {
          let configuration: NetworkPeerLinkConfiguration
          switch role {
          case .host:
            configuration = NetworkPeerLinkConfiguration(
              serviceToken: scope.serviceToken,
              credentials: TransportCredentials(
                preSharedKey: scope.preSharedKey(joinSecret: joinSecret),
                identity: identity
              ),
              role: .host,
              localSlot: 0,
              playerCount: 2,
              txtEntries: scope.txtEntries
            )
          case .guest:
            configuration = NetworkPeerLinkConfiguration(
              serviceToken: scope.serviceToken,
              credentials: TransportCredentials(
                preSharedKey: scope.preSharedKey(joinSecret: joinSecret),
                identity: identity
              ),
              role: .client,
              localSlot: 1,
              playerCount: 2,
              requiredTXTEntries: scope.txtEntries
            )
          }
          endpoint = try NetworkPeerLink(
            remoteSlot: 0,
            configuration: configuration,
            linkEventHandler: { [weak self] event in
              guard let self else { return }
              self.queue.async { [weak self] in
                guard let self, self.generation == generation, self.link != nil else { return }
                self.handle(event)
              }
            }
          )
        } catch {
          setState(.failed("transport:\(error)"))
          return
        }
      }
      self.link = endpoint
      self.mapper = ArenaLinkFrameMapper(
        senderSlot: role == .host ? 0 : 1,
        epoch: 1,
        onRejection: { [weak self] _ in
          self?.recordFramingError()
        }
      )
      let endpointID = ObjectIdentifier(endpoint)
      endpoint.setReceiveHandler { [weak self] frame, _, _ in
        guard let self else { return }
        self.queue.async { [weak self] in
          guard let self, self.generation == generation,
                let current = self.link, ObjectIdentifier(current) == endpointID
          else { return }
          self.receive(frame)
        }
      }
      if linkFactory != nil {
        setState(.connecting)
        sendHello()
      } else {
        setState(role == .host ? .advertising : .browsing)
      }
      endpoint.start()
    }
  }

  func stop() {
    queue.async { [self] in
      stopLocked(publish: true)
    }
  }

  func send(_ message: ArenaLinkMessage) {
    queue.async { [self] in
      guard helloVerified, let link, var mapper else {
        recordFramingError()
        return
      }
      do {
        let frames = try mapper.outbound(message)
        self.mapper = mapper
        for frame in frames {
          try link.send(.reliable(frame))
          lock.withLock { _stats.bytesOut += frame.payload.count }
        }
      } catch {
        recordFramingError()
      }
    }
  }

  private func handle(_ event: NetworkPeerLinkEvent) {
    switch event {
    case .listening:
      setState(.advertising)
    case .browsing:
      setState(.browsing)
    case .connecting:
      setState(.connecting)
    case .peerBound:
      sendHello()
    case .peerDisconnected:
      setState(role == .host ? .advertising : .browsing)
      helloVerified = false
    case .rejected:
      recordFramingError()
    case .failed(let reason):
      fail(reason)
    }
  }

  private func sendHello() {
    guard let link, var mapper else { return }
    do {
      let hello = try MatchHelloCodec.encode(MatchHello(
        scopeId: scope.scopeId,
        playerId: playerId,
        protocolVersion: MatchScope.protocolVersion
      ))
      let frame = mapper.controlFrame(payload: Data([0]) + hello)
      try link.send(.reliable(frame))
      lock.withLock { _stats.bytesOut += frame.payload.count }
      self.mapper = mapper
    } catch {
      fail("hello send failed")
    }
  }

  private func receive(_ frame: TransportFrame) {
    guard link != nil else { return }
    if case .failed = state { return }
    receiveFrame(frame)
  }

  private func receiveFrame(_ frame: TransportFrame) {
    guard case let .reliable(reliable, _) = frame else { return }
    lock.withLock { _stats.bytesIn += reliable.payload.count }
    let deliveries: [ReliableEventFrame]
    if link?.deliversOrderedReliableFrames == true {
      deliveries = [reliable]
    } else {
      let delivery = orderer.ingest(reliable)
      guard delivery.status == .delivered else { return }
      deliveries = delivery.frames
    }
    for delivered in deliveries {
      if !helloVerified {
        guard delivered.eventKind == .control,
              let kind = delivered.payload.first,
              kind == 0
        else {
          recordFramingError()
          continue
        }
        do {
          let hello = try MatchHelloCodec.decode(Data(delivered.payload.dropFirst()))
          guard hello.scopeId == scope.scopeId,
                hello.protocolVersion == MatchScope.protocolVersion
          else {
            fail("peer belongs to another match")
            return
          }
          helloVerified = true
          setState(.connected)
        } catch {
          fail("peer belongs to another match")
          return
        }
        continue
      }
      guard var mapper else { return }
      let message = mapper.inbound(delivered)
      self.mapper = mapper
      if let message {
        onMessage?(message, ArenaClock.nowMs())
      } else if delivered.eventKind != .bulkChunk {
        recordFramingError()
      }
    }
  }

  private func stopLocked(publish: Bool) {
    generation &+= 1
    link?.setReceiveHandler(nil)
    link?.stop()
    link = nil
    mapper = nil
    orderer = ReliableEventOrderer()
    helloVerified = false
    if publish { setState(.idle) }
  }

  private func fail(_ reason: String) {
    stopLocked(publish: false)
    setState(.failed(reason))
  }

  private func setState(_ newState: ArenaPeerLinkState) {
    guard state != newState else { return }
    state = newState
    onStateChange?(newState)
  }

  private func recordFramingError() {
    lock.withLock { _stats.framingErrors += 1 }
  }
}
