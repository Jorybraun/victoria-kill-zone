import Foundation
import Network
import Security

private protocol ReliableGroupLifetime {}

@available(macOS 14.0, iOS 17.0, *)
private final class ReliableGroupBox: ReliableGroupLifetime {
  let group: NWConnectionGroup

  init(group: NWConnectionGroup) {
    self.group = group
  }
}

public struct TransportCredentials: Sendable, Equatable {
  public let preSharedKey: Data

  public init(preSharedKey: Data) {
    self.preSharedKey = preSharedKey
  }
}

public struct NetworkPeerLinkConfiguration: Sendable, Equatable {
  public let serviceToken: String
  public let credentials: TransportCredentials

  public init(serviceToken: String, credentials: TransportCredentials) {
    self.serviceToken = serviceToken
    self.credentials = credentials
  }
}

public protocol PeerLink: AnyObject, Sendable {
  var remoteSlot: UInt8 { get }
  func start()
  func stop()
  func send(_ frame: TransportFrame) throws
}

/// Network I/O is confined to `queue`; callers never access NW objects directly.
public final class NetworkPeerLink: PeerLink, @unchecked Sendable {
  public let remoteSlot: UInt8
  private let configuration: NetworkPeerLinkConfiguration
  private let queue: DispatchQueue
  private var connection: NWConnection?
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var reliableGroup: (any ReliableGroupLifetime)?
  private var receiveHandler: ((TransportFrame) -> Void)?
  private var failureHandler: (() -> Void)?

  public init(
    remoteSlot: UInt8,
    configuration: NetworkPeerLinkConfiguration,
    receiveHandler: ((TransportFrame) -> Void)? = nil,
    failureHandler: (() -> Void)? = nil
  ) {
    self.remoteSlot = remoteSlot
    self.configuration = configuration
    self.receiveHandler = receiveHandler
    self.failureHandler = failureHandler
    queue = DispatchQueue(label: "vkz.combat-transport.network")
  }

  public func start() {
    queue.async { [self] in
      let quic = NWProtocolQUIC.Options(alpn: ["vkz-combat-v1"])
      quic.isDatagram = true
      quic.maxDatagramFrameSize = 512
      self.applyCredentials(to: quic)
      let parameters = NWParameters(quic: quic)
      parameters.includePeerToPeer = true

      let service = NWListener.Service(
        name: configuration.serviceToken,
        type: "_vkz-combat._udp"
      )
      let listener = try? NWListener(service: service, using: parameters)
      listener?.stateUpdateHandler = { [weak self] state in
        if case .failed = state {
          self?.failureHandler?()
        }
      }
      listener?.newConnectionHandler = { [weak self] connection in
        self?.attach(connection)
      }
      listener?.start(queue: queue)
      self.listener = listener

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
        guard let self, let endpoint = results.first?.endpoint else { return }
        if #available(macOS 14.0, iOS 17.0, *) {
          self.formReliableGroup(to: endpoint)
        }
        self.browser?.cancel()
        self.listener?.cancel()
      }
      browser.start(queue: queue)
      self.browser = browser
    }
  }

  public func stop() {
    queue.async { [self] in
      browser?.cancel()
      listener?.cancel()
      connection?.cancel()
      browser = nil
      listener = nil
      connection = nil
    }
  }

  public func send(_ frame: TransportFrame) throws {
    let encoded = try TransportFrameCodec.encode(frame)
    queue.async { [weak self] in
      guard let self, let connection else { return }
      let context = NWConnection.ContentContext(
        identifier: "vkz-combat-v1",
        metadata: []
      )
      connection.send(
        content: encoded,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { [weak self] error in
          if error != nil { self?.failureHandler?() }
        }
      )
    }
  }

  private func attach(_ connection: NWConnection) {
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        self?.failureHandler?()
      }
    }
    connection.start(queue: queue)
    receive(on: connection)
  }

  @available(macOS 14.0, iOS 17.0, *)
  private func formReliableGroup(to endpoint: NWEndpoint) {
    guard reliableGroup == nil else { return }
    let quic = NWProtocolQUIC.Options(alpn: ["vkz-combat-v1"])
    applyCredentials(to: quic)
    let parameters = NWParameters(quic: quic)
    parameters.includePeerToPeer = true
    let descriptor = NWMultiplexGroup(to: endpoint)
    let group = NWConnectionGroup(with: descriptor, using: parameters)
    group.stateUpdateHandler = { [weak self] state in
      if case .failed = state {
        self?.failureHandler?()
      }
    }
    group.newConnectionHandler = { [weak self] connection in
      self?.attach(connection)
    }
    group.start(queue: queue)
    reliableGroup = ReliableGroupBox(group: group)
  }

  private func applyCredentials(to quic: NWProtocolQUIC.Options) {
    let identity = Data(configuration.serviceToken.utf8)
    guard let psk = makeDispatchData(configuration.credentials.preSharedKey),
          let pskIdentity = makeDispatchData(identity)
    else {
      return
    }
    sec_protocol_options_add_pre_shared_key(
      quic.securityProtocolOptions,
      psk,
      pskIdentity
    )
  }

  private func makeDispatchData(_ data: Data) -> Dispatch.__DispatchData? {
    guard !data.isEmpty else { return nil }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      DispatchData(bytes: bytes)._bridgeToObjectiveC()
    }
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] content, _, _, error in
      if let content, let frame = try? TransportFrameCodec.decode(content) {
        self?.receiveHandler?(frame)
      }
      if error == nil {
        self?.receive(on: connection)
      } else {
        self?.failureHandler?()
      }
    }
  }
}
