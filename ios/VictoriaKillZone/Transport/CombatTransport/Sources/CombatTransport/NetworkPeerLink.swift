import Foundation
import Network
import Security

public struct TransportCredentials: Sendable {
  public let preSharedKey: Data
  public let identity: (any TransportIdentityProvider)?

  public init(
    preSharedKey: Data,
    identity: (any TransportIdentityProvider)? = nil
  ) {
    self.preSharedKey = preSharedKey
    self.identity = identity
  }
}

public struct NetworkPeerLinkConfiguration: Sendable {
  public enum Role: String, Sendable {
    case host
    case client
  }

  public let serviceToken: String
  public let credentials: TransportCredentials
  public let role: Role
  public let localSlot: UInt8
  public let playerCount: Int
  /// Hosts advertise over Bonjour in the field; loopback fixtures bind a port
  /// directly and hand the endpoint to clients.
  public let advertisesService: Bool

  public init(
    serviceToken: String,
    credentials: TransportCredentials,
    role: Role = .client,
    localSlot: UInt8 = 1,
    playerCount: Int = 2,
    advertisesService: Bool = true
  ) {
    self.serviceToken = serviceToken
    self.credentials = credentials
    self.role = role
    self.localSlot = localSlot
    self.playerCount = playerCount
    self.advertisesService = advertisesService
  }
}

public typealias PeerLinkReceiveHandler =
  @Sendable (TransportFrame, Int64, Int64?) -> Void

public protocol PeerLink: AnyObject, Sendable {
  var remoteSlot: UInt8 { get }
  var evidenceTier: TransportEvidenceTier { get }
  var deliversOrderedReliableFrames: Bool { get }
  func start()
  func stop()
  func send(_ frame: TransportFrame) throws
  func setReceiveHandler(_ handler: PeerLinkReceiveHandler?)
}

/// Direct Network.framework peer link.
///
/// Topology: the host binds one reliable-QUIC listener (Bonjour advertised) and
/// one datagram-QUIC listener. Every flow is client-initiated; the host never
/// dials a peer and never infers an endpoint from a connection path. A client's
/// reliable flow authenticates with the PSK-derived `slotClaim`; the host answers
/// with a `pairingOffer` carrying a fresh token plus its datagram port, and the
/// client's datagram flow authenticates with the matching `pairingClaim`, so both
/// flows of a slot are bound to one authenticated peer.
///
/// Network I/O and adapter tables are confined to `queue`; state-machine and
/// handler access is confined to `stateLock`.
public final class NetworkPeerLink: PeerLink, @unchecked Sendable {
  public let remoteSlot: UInt8
  public let evidenceTier: TransportEvidenceTier = .device
  public let deliversOrderedReliableFrames = true

  private let configuration: NetworkPeerLinkConfiguration
  private let identity: TransportIdentityProvider?
  private let queue = DispatchQueue(label: "vkz.combat-transport.network")
  private let verifyQueue = DispatchQueue(label: "vkz.combat-transport.verify")
  private let stateLock = NSLock()
  private var stateMachine: PeerLinkStateMachine
  private var nextConnectionID: UInt64 = 1
  private var connections: [PeerLinkStateMachine.ConnectionID: NWConnection] = [:]
  private var datagramConnections: [PeerLinkStateMachine.ConnectionID: NWConnection] = [:]
  private var reliableBuffers: [PeerLinkStateMachine.ConnectionID: Data] = [:]
  private var reliableListener: NWListener?
  private var datagramListener: NWListener?
  private var browser: NWBrowser?
  private var hostDatagramPort: UInt16?
  private var slotsAwaitingOffer: Set<UInt8> = []
  private var receiveHandler: PeerLinkReceiveHandler?
  private var failureHandler: (() -> Void)?
  private var listenersReadyHandler: (@Sendable (UInt16, UInt16) -> Void)?

  public init(
    remoteSlot: UInt8,
    configuration: NetworkPeerLinkConfiguration,
    identity: TransportIdentityProvider? = nil,
    receiveHandler: PeerLinkReceiveHandler? = nil,
    failureHandler: (() -> Void)? = nil,
    listenersReadyHandler: (@Sendable (UInt16, UInt16) -> Void)? = nil
  ) throws {
    self.remoteSlot = remoteSlot
    self.configuration = configuration
    self.identity = identity ?? configuration.credentials.identity
    self.receiveHandler = receiveHandler
    self.failureHandler = failureHandler
    self.listenersReadyHandler = listenersReadyHandler
    stateMachine = try PeerLinkStateMachine(
      role: configuration.role == .host ? .host : .client,
      localSlot: configuration.role == .host ? 0 : configuration.localSlot,
      remoteSlot: configuration.role == .host ? nil : remoteSlot,
      playerCount: configuration.playerCount,
      preSharedKey: configuration.credentials.preSharedKey
    )
  }

  public func start() {
    queue.async { [self] in
      switch configuration.role {
      case .host:
        startListeners()
      case .client:
        startBrowser()
      }
    }
  }

  /// Client entry point for a known host endpoint (loopback fixtures), skipping
  /// Bonjour resolution. Field clients use `start()`.
  public func connect(to endpoint: NWEndpoint) {
    queue.async { [self] in
      formClientReliableFlow(to: endpoint)
    }
  }

  public func stop() {
    queue.async { [self] in
      browser?.cancel()
      reliableListener?.cancel()
      datagramListener?.cancel()
      connections.values.forEach { $0.cancel() }
      datagramConnections.values.forEach { $0.cancel() }
      browser = nil
      reliableListener = nil
      datagramListener = nil
      connections.removeAll()
      datagramConnections.removeAll()
      reliableBuffers.removeAll()
    }
  }

  public func send(_ frame: TransportFrame) throws {
    let outcome = try withStateLock { try stateMachine.sendOutcome(frame) }
    let writes = try encode(outcome.actions)
    queue.async { [weak self] in
      self?.writeEncoded(writes)
    }
    if let failure = outcome.issues.compactMap(\.failure).first {
      throw failure
    }
  }

  public func setReceiveHandler(_ handler: PeerLinkReceiveHandler?) {
    withStateLock {
      receiveHandler = handler
    }
  }

  // MARK: - Host

  private func startListeners() {
    let datagramParameters = NWParameters(quic: makeQUICOptions(datagram: true))
    datagramParameters.includePeerToPeer = true
    datagramListener = try? NWListener(using: datagramParameters)
    datagramListener?.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.hostDatagramPort = self.datagramListener?.port?.rawValue
        self.flushPendingOffers()
        self.announceListenersIfReady()
      case .failed:
        self.failureHandler?()
      default:
        break
      }
    }
    datagramListener?.newConnectionHandler = { [weak self] connection in
      self?.attachHostConnection(connection, datagram: true)
    }
    datagramListener?.start(queue: queue)

    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    if configuration.advertisesService {
      reliableListener = try? NWListener(
        service: NWListener.Service(
          name: configuration.serviceToken,
          type: "_vkz-combat._udp"
        ),
        using: parameters
      )
    } else {
      reliableListener = try? NWListener(using: parameters)
    }
    reliableListener?.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.announceListenersIfReady()
      case .failed:
        self.failureHandler?()
      default:
        break
      }
    }
    reliableListener?.newConnectionHandler = { [weak self] connection in
      self?.attachHostConnection(connection, datagram: false)
    }
    reliableListener?.start(queue: queue)
  }

  private func announceListenersIfReady() {
    guard let reliablePort = reliableListener?.port?.rawValue,
          reliablePort != 0,
          let datagramPort = hostDatagramPort,
          datagramPort != 0
    else { return }
    listenersReadyHandler?(reliablePort, datagramPort)
  }

  private func attachHostConnection(_ connection: NWConnection, datagram: Bool) {
    let id = mintConnectionID()
    do {
      try withStateLock {
        try stateMachine.acceptConnection(id)
      }
    } catch {
      connection.cancel()
      return
    }
    if datagram {
      datagramConnections[id] = connection
    } else {
      connections[id] = connection
    }
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        // The reliable flow is only usable once its slot claim binds it, which
        // happens in `handle(actions:)`; datagram flows likewise wait for the
        // pairing claim.
        break
      case .failed:
        self.failConnection(id)
      case .cancelled:
        self.failConnection(id)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id, datagram: datagram)
  }

  private func offerPairing(to slot: UInt8) {
    guard let port = hostDatagramPort else {
      slotsAwaitingOffer.insert(slot)
      return
    }
    var token = Data(count: TransportFrameCodec.pairingTokenLength)
    let generated = token.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return false }
      return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) == errSecSuccess
    }
    guard generated else {
      failureHandler?()
      return
    }
    do {
      let action = try withStateLock {
        try stateMachine.issuePairingOffer(
          for: slot,
          datagramPort: port,
          token: token
        )
      }
      write([action])
    } catch {
      failureHandler?()
    }
  }

  private func flushPendingOffers() {
    let pending = slotsAwaitingOffer
    slotsAwaitingOffer.removeAll()
    pending.forEach { offerPairing(to: $0) }
  }

  // MARK: - Client

  private func startBrowser() {
    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: "_vkz-combat._udp", domain: nil),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        self?.failureHandler?()
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self else { return }
      let matching = results.compactMap { result -> (String, NWEndpoint)? in
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return (name, result.endpoint)
      }
      guard let selectedName = PeerLinkStateMachine.selectServiceName(
        from: matching.map(\.0),
        matching: configuration.serviceToken
      ),
      let endpoint = matching.first(where: { $0.0 == selectedName })?.1
      else {
        return
      }
      self.formClientReliableFlow(to: endpoint)
      self.browser?.cancel()
      self.browser = nil
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  private func formClientReliableFlow(to endpoint: NWEndpoint) {
    let id = mintConnectionID()
    do {
      try withStateLock {
        try stateMachine.bindClientConnection(id, to: remoteSlot)
      }
    } catch {
      failureHandler?()
      return
    }
    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    let connection: NWConnection
    if case let .hostPort(host, port) = endpoint {
      connection = NWConnection(host: host, port: port, using: parameters)
    } else {
      connection = NWConnection(to: endpoint, using: parameters)
    }
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.sendClientSlotClaim(on: id)
        self.markFlowReady(.reliable, for: id, slot: self.remoteSlot)
      case .failed:
        self.failConnection(id)
      case .cancelled:
        self.failConnection(id)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id, datagram: false)
  }

  /// Dials the datagram flow after an authenticated `pairingOffer`. The host
  /// address comes from the established, pinned reliable connection and the port
  /// from the offer itself; the flow is then bound by its own pairing claim.
  private func formClientDatagramFlow(
    offer: PairingOfferFrame,
    reliableConnection id: PeerLinkStateMachine.ConnectionID
  ) {
    guard let host = hostAddress(of: connections[id]) else {
      failureHandler?()
      return
    }
    guard let port = NWEndpoint.Port(rawValue: offer.datagramPort) else { return }
    let datagramID = mintConnectionID()
    do {
      try withStateLock {
        try stateMachine.bindClientDatagramConnection(datagramID, to: remoteSlot)
      }
    } catch {
      failureHandler?()
      return
    }
    let connection = NWConnection(
      host: host,
      port: port,
      using: NWParameters(quic: makeQUICOptions(datagram: true))
    )
    datagramConnections[datagramID] = connection
    let claim = PeerLinkStateMachine.makePairingClaim(
      preSharedKey: configuration.credentials.preSharedKey,
      token: offer.token,
      claimedSlot: configuration.localSlot
    )
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.sendDatagram(.pairingClaim(claim), on: datagramID)
        self.markFlowReady(.pose, for: datagramID, slot: self.remoteSlot)
      case .failed:
        self.failConnection(datagramID)
      case .cancelled:
        self.failConnection(datagramID)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, id: datagramID, datagram: true)
  }

  private func hostAddress(of connection: NWConnection?) -> NWEndpoint.Host? {
    guard let remote = connection?.currentPath?.remoteEndpoint else { return nil }
    if case let .hostPort(host, _) = remote { return host }
    return nil
  }

  private func sendClientSlotClaim(on id: PeerLinkStateMachine.ConnectionID) {
    let claim = PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: configuration.credentials.preSharedKey,
      nonce: UInt32.random(in: 1...UInt32.max),
      claimedSlot: configuration.localSlot
    )
    do {
      let action = try withStateLock {
        try stateMachine.sendSlotClaim(claim, on: id)
      }
      write([action])
    } catch {
      failureHandler?()
    }
  }

  // MARK: - Flow readiness and writes

  private func markFlowReady(
    _ channel: PeerLinkStateMachine.Channel,
    for id: PeerLinkStateMachine.ConnectionID,
    slot: UInt8? = nil
  ) {
    let target = withStateLock { slot ?? stateMachine.boundSlot(for: id) }
    guard let target else { return }
    do {
      let actions = try withStateLock {
        try stateMachine.setFlowReady(channel, for: target, connection: id)
      }
      write(actions)
    } catch {
      failConnection(id)
    }
  }

  private func encode(
    _ actions: [PeerLinkStateMachine.Action]
  ) throws -> [(PeerLinkStateMachine.Action, Data)] {
    try actions.compactMap { action in
      guard case let .write(_, _, frame) = action else { return nil }
      return (action, try TransportFrameCodec.encode(frame))
    }
  }

  private func write(_ actions: [PeerLinkStateMachine.Action]) {
    guard let writes = try? encode(actions) else {
      failureHandler?()
      return
    }
    writeEncoded(writes)
  }

  private func writeEncoded(
    _ writes: [(PeerLinkStateMachine.Action, Data)]
  ) {
    for (action, encoded) in writes {
      guard case let .write(id, channel, _) = action else { continue }
      switch channel {
      case .pose:
        guard let connection = datagramConnections[id] else {
          failConnection(id)
          continue
        }
        connection.send(
          content: encoded,
          isComplete: true,
          completion: .contentProcessed { [weak self] error in
            if error != nil { self?.failConnection(id) }
          }
        )
      case .reliable:
        guard let connection = connections[id] else {
          failConnection(id)
          continue
        }
        // QUIC streams are byte streams: frames carry an explicit length prefix
        // so receivers can split them as bytes arrive.
        connection.send(
          content: Self.lengthPrefixed(encoded),
          isComplete: false,
          completion: .contentProcessed { [weak self] error in
            if error != nil { self?.failConnection(id) }
          }
        )
      }
    }
  }

  private func sendDatagram(
    _ frame: TransportFrame,
    on id: PeerLinkStateMachine.ConnectionID
  ) {
    guard let encoded = try? TransportFrameCodec.encode(frame),
          let connection = datagramConnections[id]
    else {
      failConnection(id)
      return
    }
    connection.send(
      content: encoded,
      isComplete: true,
      completion: .contentProcessed { [weak self] error in
        if error != nil { self?.failConnection(id) }
      }
    )
  }

  private static func lengthPrefixed(_ payload: Data) -> Data {
    var framed = Data()
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) {
      framed.append(contentsOf: $0)
    }
    framed.append(payload)
    return framed
  }

  // MARK: - Receive

  private func receive(
    on connection: NWConnection,
    id: PeerLinkStateMachine.ConnectionID,
    datagram: Bool
  ) {
    if datagram {
      connection.receiveMessage { [weak self] content, _, _, error in
        guard let self else { return }
        if let content, let frame = try? TransportFrameCodec.decode(content) {
          self.admit(frame, on: connection, id: id)
        }
        if error == nil {
          self.receive(on: connection, id: id, datagram: true)
        } else {
          self.failConnection(id)
        }
      }
      return
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
      [weak self] content, _, isComplete, error in
      guard let self else { return }
      if let content, !content.isEmpty {
        var buffer = self.reliableBuffers[id] ?? Data()
        buffer.append(content)
        for frame in self.drainFrames(from: &buffer) {
          self.admit(frame, on: connection, id: id)
        }
        self.reliableBuffers[id] = buffer
      }
      if error == nil, !isComplete {
        self.receive(on: connection, id: id, datagram: false)
      } else if error != nil {
        self.failConnection(id)
      }
    }
  }

  private func drainFrames(from buffer: inout Data) -> [TransportFrame] {
    var frames: [TransportFrame] = []
    while buffer.count >= 4 {
      let length = buffer.prefix(4).withUnsafeBytes {
        Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
      }
      guard length > 0, length <= 8_192 else {
        buffer.removeAll()
        return frames
      }
      guard buffer.count >= 4 + length else { return frames }
      let payload = buffer.subdata(in: 4..<(4 + length))
      buffer.removeSubrange(0..<(4 + length))
      if let frame = try? TransportFrameCodec.decode(payload) {
        frames.append(frame)
      }
    }
    return frames
  }

  private func admit(
    _ frame: TransportFrame,
    on connection: NWConnection,
    id: PeerLinkStateMachine.ConnectionID
  ) {
    do {
      let actions = try withStateLock { try stateMachine.receive(frame, on: id) }
      handle(actions, on: connection, id: id)
    } catch {
      failConnection(id)
    }
  }

  private func handle(
    _ actions: [PeerLinkStateMachine.Action],
    on connection: NWConnection,
    id: PeerLinkStateMachine.ConnectionID
  ) {
    for action in actions {
      switch action {
      case let .bound(_, slot):
        markFlowReady(.reliable, for: id, slot: slot)
        offerPairing(to: slot)
      case let .datagramBound(_, slot):
        markFlowReady(.pose, for: id, slot: slot)
      case let .received(_, receivedFrame):
        deliver(receivedFrame, on: connection, id: id)
      case .rejected:
        connection.cancel()
        failConnection(id)
      case .reliableGap:
        failureHandler?()
      case .dropped, .write, .disconnected:
        break
      }
    }
  }

  private func deliver(
    _ frame: TransportFrame,
    on connection: NWConnection,
    id: PeerLinkStateMachine.ConnectionID
  ) {
    if case let .pairingOffer(offer, _) = frame {
      guard configuration.role == .client else { return }
      formClientDatagramFlow(offer: offer, reliableConnection: id)
      return
    }
    if configuration.role == .host {
      do {
        let outcome = try withStateLock {
          try stateMachine.relayOutcome(frame, from: id)
        }
        write(outcome.actions)
        if outcome.issues.contains(where: { $0.failure != nil }) {
          failureHandler?()
        }
      } catch {
        failureHandler?()
        connection.cancel()
        failConnection(id)
        return
      }
    }
    let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    let handler = withStateLock { receiveHandler }
    handler?(frame, nowMs, nil)
  }

  private func failConnection(_ id: PeerLinkStateMachine.ConnectionID) {
    let actions = withStateLock { stateMachine.disconnect(id) }
    connections[id]?.cancel()
    datagramConnections[id]?.cancel()
    connections[id] = nil
    datagramConnections[id] = nil
    reliableBuffers[id] = nil
    if !actions.isEmpty {
      failureHandler?()
    }
  }

  private func mintConnectionID() -> PeerLinkStateMachine.ConnectionID {
    defer { nextConnectionID &+= 1 }
    return .init(nextConnectionID)
  }

  private func makeQUICOptions(datagram: Bool) -> NWProtocolQUIC.Options {
    let quic = NWProtocolQUIC.Options(alpn: ["vkz-combat-v1"])
    quic.isDatagram = datagram
    quic.maxDatagramFrameSize = 512
    guard let identity else { return quic }
    switch configuration.role {
    case .host:
      TransportSecurity.applyHostIdentity(identity, to: quic)
    case .client:
      TransportSecurity.applyClientPinning(
        identity,
        to: quic,
        queue: verifyQueue
      )
    }
    return quic
  }

  private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body()
  }
}
