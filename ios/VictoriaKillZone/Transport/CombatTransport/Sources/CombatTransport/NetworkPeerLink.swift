import Foundation
import Network
import Security

public struct TransportCredentials: Sendable, Equatable {
  public let preSharedKey: Data

  public init(preSharedKey: Data) {
    self.preSharedKey = preSharedKey
  }
}

public struct NetworkPeerLinkConfiguration: Sendable, Equatable {
  public enum Role: String, Sendable {
    case host
    case client
  }

  public let serviceToken: String
  public let credentials: TransportCredentials
  public let role: Role
  public let localSlot: UInt8
  public let playerCount: Int

  public init(
    serviceToken: String,
    credentials: TransportCredentials,
    role: Role = .client,
    localSlot: UInt8 = 1,
    playerCount: Int = 2
  ) {
    self.serviceToken = serviceToken
    self.credentials = credentials
    self.role = role
    self.localSlot = localSlot
    self.playerCount = playerCount
  }
}

public typealias PeerLinkReceiveHandler =
  @Sendable (TransportFrame, Int64, Int64?) -> Void

public protocol PeerLink: AnyObject, Sendable {
  var remoteSlot: UInt8 { get }
  var evidenceTier: TransportEvidenceTier { get }
  func start()
  func stop()
  func send(_ frame: TransportFrame) throws
  func setReceiveHandler(_ handler: PeerLinkReceiveHandler?)
}

/// Network I/O is confined to `queue`; state-machine access is confined to `stateLock`.
public final class NetworkPeerLink: PeerLink, @unchecked Sendable {
  public let remoteSlot: UInt8
  public let evidenceTier: TransportEvidenceTier = .device

  private let configuration: NetworkPeerLinkConfiguration
  private let queue = DispatchQueue(label: "vkz.combat-transport.network")
  private let stateLock = NSLock()
  private var stateMachine: PeerLinkStateMachine
  private var nextConnectionID: UInt64 = 1
  private var reliableReadyConnections: Set<PeerLinkStateMachine.ConnectionID> = []
  private var connections: [PeerLinkStateMachine.ConnectionID: NWConnection] = [:]
  private var datagramConnections: [PeerLinkStateMachine.ConnectionID: NWConnection] = [:]
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var reliableGroup: NWConnectionGroup?
  private var receiveHandler: PeerLinkReceiveHandler?
  private var failureHandler: (() -> Void)?

  public init(
    remoteSlot: UInt8,
    configuration: NetworkPeerLinkConfiguration,
    receiveHandler: PeerLinkReceiveHandler? = nil,
    failureHandler: (() -> Void)? = nil
  ) throws {
    self.remoteSlot = remoteSlot
    self.configuration = configuration
    self.receiveHandler = receiveHandler
    self.failureHandler = failureHandler
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
        startListener()
      case .client:
        startBrowser()
      }
    }
  }

  public func stop() {
    queue.async { [self] in
      browser?.cancel()
      listener?.cancel()
      reliableGroup?.cancel()
      connections.values.forEach { $0.cancel() }
      datagramConnections.values.forEach { $0.cancel() }
      browser = nil
      listener = nil
      reliableGroup = nil
      connections.removeAll()
      datagramConnections.removeAll()
    }
  }

  public func send(_ frame: TransportFrame) throws {
    let outcome = try withStateLock { try stateMachine.sendOutcome(frame) }
    let writes = try outcome.actions.map { action -> (PeerLinkStateMachine.Action, Data) in
      guard case let .write(_, _, actionFrame) = action else {
        return (action, Data())
      }
      return (action, try TransportFrameCodec.encode(actionFrame))
    }
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

  private func startListener() {
    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    let service = NWListener.Service(
      name: configuration.serviceToken,
      type: "_vkz-combat._udp"
    )
    listener = try? NWListener(service: service, using: parameters)
    listener?.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.failureHandler?() }
    }
    listener?.newConnectionHandler = { [weak self] connection in
      self?.attachHostConnection(connection)
    }
    listener?.start(queue: queue)
  }

  private func startBrowser() {
    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: "_vkz-combat._udp", domain: nil),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.failureHandler?() }
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
      formClientFlows(to: endpoint)
      self.browser?.cancel()
      self.browser = nil
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  private func attachHostConnection(_ connection: NWConnection) {
    let id = mintConnectionID()
    do {
      try withStateLock {
        try stateMachine.acceptConnection(id)
      }
    } catch {
      connection.cancel()
      return
    }
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.markFlowReady(.reliable, for: id)
        if let endpoint = connection.currentPath?.remoteEndpoint {
          self.formDatagramFlow(to: endpoint, for: id, slot: nil)
        }
      case .failed, .cancelled:
        self.failConnection(id)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id)
  }

  private func formClientFlows(to endpoint: NWEndpoint) {
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
    let group = NWConnectionGroup(
      with: NWMultiplexGroup(to: endpoint),
      using: parameters
    )
    group.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.failureHandler?() }
    }
    group.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      self.connections[id] = connection
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.markFlowReady(.reliable, for: id)
          self.sendClientSlotClaim(on: id)
        case .failed, .cancelled:
          self.failConnection(id)
        default:
          break
        }
      }
      connection.start(queue: self.queue)
      self.receive(on: connection, id: id)
    }
    group.start(queue: queue)
    reliableGroup = group
    formDatagramFlow(to: endpoint, for: id, slot: remoteSlot)
  }

  private func formDatagramFlow(
    to endpoint: NWEndpoint,
    for id: PeerLinkStateMachine.ConnectionID,
    slot: UInt8?
  ) {
    let connection = NWConnection(
      to: endpoint,
      using: NWParameters(quic: makeQUICOptions(datagram: true))
    )
    datagramConnections[id] = connection
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.markFlowReady(.pose, for: id, slot: slot)
      case .failed, .cancelled:
        self.failConnection(id)
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(on: connection, id: id)
  }

  private func sendClientSlotClaim(on id: PeerLinkStateMachine.ConnectionID) {
    let claim = PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: configuration.credentials.preSharedKey,
      nonce: UInt32.random(in: 1...UInt32.max),
      claimedSlot: configuration.localSlot
    )
    guard let action = try? withStateLock({
      try stateMachine.sendSlotClaim(claim, on: id)
    }) else { return }
    write([action])
  }

  private func markFlowReady(
    _ channel: PeerLinkStateMachine.Channel,
    for id: PeerLinkStateMachine.ConnectionID,
    slot: UInt8? = nil
  ) {
    if channel == .reliable {
      reliableReadyConnections.insert(id)
    }
    let target = withStateLock {
      slot
        ?? (configuration.role == .client
          ? remoteSlot
          : stateMachine.boundSlot(for: id))
    }
    guard let target else { return }
    guard let actions = try? withStateLock({
      try stateMachine.setFlowReady(channel, for: target, connection: id)
    }) else { return }
    write(actions)
  }

  private func write(_ actions: [PeerLinkStateMachine.Action]) {
    let writes = actions.compactMap { action -> (PeerLinkStateMachine.Action, Data)? in
      guard case let .write(_, _, frame) = action,
            let encoded = try? TransportFrameCodec.encode(frame)
      else { return nil }
      return (action, encoded)
    }
    writeEncoded(writes)
  }

  private func writeEncoded(
    _ writes: [(PeerLinkStateMachine.Action, Data)]
  ) {
    for (action, encoded) in writes {
      guard case let .write(id, channel, frame) = action else { continue }
      let connection = channel == .pose ? datagramConnections[id] : connections[id]
      guard let connection else {
        failConnection(id)
        continue
      }
      let context = NWConnection.ContentContext(
        identifier: frame.relayed ? "vkz-combat-relayed" : "vkz-combat-v1",
        metadata: []
      )
      connection.send(
        content: encoded,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          if error != nil { self?.failConnection(id) }
        }
      )
    }
  }

  private func receive(
    on connection: NWConnection,
    id: PeerLinkStateMachine.ConnectionID
  ) {
    connection.receiveMessage { [weak self] content, _, _, error in
      guard let self else { return }
      if let content, let frame = try? TransportFrameCodec.decode(content) {
        do {
          let actions = try self.withStateLock {
            try self.stateMachine.receive(frame, on: id)
          }
          for action in actions {
            switch action {
            case let .bound(_, slot):
              if self.reliableReadyConnections.contains(id) {
                self.markFlowReady(.reliable, for: id, slot: slot)
              }
              if let endpoint = connection.currentPath?.remoteEndpoint {
                self.formDatagramFlow(to: endpoint, for: id, slot: slot)
              }
            case let .received(_, receivedFrame):
              let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
              let handler = self.withStateLock { self.receiveHandler }
              handler?(receivedFrame, nowMs, nil)
            case .rejected:
              connection.cancel()
            case .write, .disconnected:
              break
            }
          }
        } catch {
          self.failConnection(id)
        }
      }
      if error == nil {
        self.receive(on: connection, id: id)
      } else {
        self.failConnection(id)
      }
    }
  }

  private func failConnection(_ id: PeerLinkStateMachine.ConnectionID) {
    let actions = withStateLock { stateMachine.disconnect(id) }
    connections[id]?.cancel()
    datagramConnections[id]?.cancel()
    connections[id] = nil
    datagramConnections[id] = nil
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
    applyCredentials(to: quic)
    return quic
  }

  private func applyCredentials(to quic: NWProtocolQUIC.Options) {
    let identity = Data(configuration.serviceToken.utf8)
    guard let psk = makeDispatchData(configuration.credentials.preSharedKey),
          let pskIdentity = makeDispatchData(identity)
    else { return }
    sec_protocol_options_add_pre_shared_key(
      quic.securityProtocolOptions,
      psk,
      pskIdentity
    )
  }

  private func makeDispatchData(_ data: Data) -> Dispatch.__DispatchData? {
    guard !data.isEmpty else { return nil }
    return data.withUnsafeBytes { bytes in
      DispatchData(bytes: bytes) as __DispatchData
    }
  }

  private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body()
  }
}
