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

  public init(
    serviceToken: String,
    credentials: TransportCredentials,
    role: Role = .client
  ) {
    self.serviceToken = serviceToken
    self.credentials = credentials
    self.role = role
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

/// Network I/O is confined to `queue`; callers never access NW objects directly.
public final class NetworkPeerLink: PeerLink, @unchecked Sendable {
  public let remoteSlot: UInt8
  public let evidenceTier: TransportEvidenceTier = .device
  private let configuration: NetworkPeerLinkConfiguration
  private let queue = DispatchQueue(label: "vkz.combat-transport.network")
  private var connections: [UInt8: NWConnection] = [:]
  private var datagramConnections: [UInt8: NWConnection] = [:]
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
  ) {
    self.remoteSlot = remoteSlot
    self.configuration = configuration
    self.receiveHandler = receiveHandler
    self.failureHandler = failureHandler
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
    let encoded = try TransportFrameCodec.encode(frame)
    queue.async { [weak self] in
      guard let self else { return }
      let connection: NWConnection?
      switch frame {
      case .pose:
        connection = datagramConnections[remoteSlot]
      case .reliable:
        connection = connections[remoteSlot]
      }
      let context = NWConnection.ContentContext(
        identifier: frame.relayed ? "vkz-combat-relayed" : "vkz-combat-v1",
        metadata: []
      )
      connection?.send(
        content: encoded,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          if error != nil { self?.failureHandler?() }
        }
      )
    }
  }

  public func setReceiveHandler(_ handler: PeerLinkReceiveHandler?) {
    queue.async { [self] in
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
      guard let self else { return }
      attach(connection, for: remoteSlot)
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
      guard let self, let endpoint = results.first?.endpoint else { return }
      formReliableGroup(to: endpoint)
      formDatagramConnection(to: endpoint)
      self.browser?.cancel()
      self.browser = nil
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  private func attach(_ connection: NWConnection, for remoteSlot: UInt8) {
    connections[remoteSlot] = connection
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.failureHandler?() }
    }
    connection.start(queue: queue)
    receive(on: connection, for: remoteSlot)
  }

  private func formReliableGroup(to endpoint: NWEndpoint) {
    guard reliableGroup == nil else { return }
    let parameters = NWParameters(quic: makeQUICOptions(datagram: false))
    parameters.includePeerToPeer = true
    let descriptor = NWMultiplexGroup(to: endpoint)
    let group = NWConnectionGroup(with: descriptor, using: parameters)
    group.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.failureHandler?() }
    }
    group.newConnectionHandler = { [weak self] connection in
      self?.attach(connection, for: self?.remoteSlot ?? 0)
    }
    group.start(queue: queue)
    reliableGroup = group
  }

  private func formDatagramConnection(to endpoint: NWEndpoint) {
    let connection = NWConnection(
      to: endpoint,
      using: NWParameters(quic: makeQUICOptions(datagram: true))
    )
    datagramConnections[remoteSlot] = connection
    connection.start(queue: queue)
    receive(on: connection, for: remoteSlot)
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

  private func receive(on connection: NWConnection, for remoteSlot: UInt8) {
    connection.receiveMessage { [weak self] content, _, _, error in
      if let content, let frame = try? TransportFrameCodec.decode(content) {
        let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        self?.receiveHandler?(frame, nowMs, nil)
      }
      if error == nil {
        self?.receive(on: connection, for: remoteSlot)
      } else {
        self?.failureHandler?()
      }
    }
  }
}
