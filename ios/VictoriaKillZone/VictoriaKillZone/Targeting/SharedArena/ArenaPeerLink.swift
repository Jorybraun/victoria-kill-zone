import Foundation

#if canImport(Network)
  import Network

  final class ArenaPeerLink: ArenaPeerLinking, @unchecked Sendable {
    static let serviceType = "_pewpew-arena._tcp"
    /// Single-read ceiling; frames larger than this arrive across several reads
    /// and are reassembled by `ArenaLinkCodec.drainFrames`.
    private static let readChunk = 256 * 1024
    private let serviceName: String

    var onMessage: ((ArenaLinkMessage, Int64) -> Void)?
    var onStateChange: ((ArenaPeerLinkState) -> Void)?

    private let queue = DispatchQueue(label: "com.victoriakillzone.arena.link", qos: .userInitiated)
    private let serviceName: String?
    private let lock = NSLock()
    private var _stats = ArenaPeerLinkStats()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var state: ArenaPeerLinkState = .idle

    init(serviceName: String? = nil) {
      self.serviceName = serviceName
    }

    var stats: ArenaPeerLinkStats {
      lock.withLock { _stats }
    }

    func start(role: ArenaRole) {
      queue.async { [self] in
        tearDownLocked()
        switch role {
        case .host: startListenerLocked()
        case .guest: startBrowserLocked()
        }
      }
    }

    func stop() {
      queue.async { [self] in
        tearDownLocked()
        setState(.idle)
      }
    }

    func send(_ message: ArenaLinkMessage) {
      queue.async { [self] in
        guard let connection, state == .connected else { return }
        guard let data = try? ArenaLinkCodec.encode(message) else { return }
        lock.withLock { self._stats.bytesOut += data.count }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
          if let error { self?.fail("send:\(error.localizedDescription)") }
        })
      }
    }

    // MARK: Host

    private func startListenerLocked() {
      do {
        let listener = try NWListener(using: Self.parameters())
        listener.service = serviceName.map {
          NWListener.Service(name: $0, type: Self.serviceType)
        } ?? NWListener.Service(type: Self.serviceType)
        listener.stateUpdateHandler = { [weak self] listenerState in
          switch listenerState {
          case .ready: self?.setState(.advertising)
          case .failed(let error): self?.fail("listener:\(error.localizedDescription)")
          default: break
          }
        }
        listener.newConnectionHandler = { [weak self] incoming in
          guard let self else { return }
          // The proof is two phones: the first peer wins, later ones are refused.
          guard connection == nil else {
            incoming.cancel()
            return
          }
          adopt(incoming)
        }
        self.listener = listener
        listener.start(queue: queue)
      } catch {
        fail("listener:\(error.localizedDescription)")
      }
    }

    // MARK: Guest

    private func startBrowserLocked() {
      let browser = NWBrowser(
        for: .bonjour(type: Self.serviceType, domain: nil),
        using: Self.parameters()
      )
      browser.stateUpdateHandler = { [weak self] browserState in
        switch browserState {
        case .ready: self?.setState(.browsing)
        case .failed(let error): self?.fail("browser:\(error.localizedDescription)")
        default: break
        }
      }
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        guard let self, connection == nil else { return }
        let result = results.first { result in
          guard let serviceName = self.serviceName else { return true }
          guard case let .service(name, type, _, _) = result.endpoint else { return false }
          return name == serviceName && type == Self.serviceType
        }
        guard let result else { return }
        adopt(NWConnection(to: result.endpoint, using: Self.parameters()))
        browser.cancel()
        self.browser = nil
      }
      self.browser = browser
      browser.start(queue: queue)
    }

    // MARK: Connection

    private func adopt(_ connection: NWConnection) {
      self.connection = connection
      receiveBuffer.removeAll(keepingCapacity: true)
      setState(.connecting)
      connection.stateUpdateHandler = { [weak self] connectionState in
        guard let self else { return }
        switch connectionState {
        case .ready:
          setState(.connected)
          receiveNext()
        case .failed(let error):
          fail("connection:\(error.localizedDescription)")
        case .cancelled:
          if self.connection === connection { self.connection = nil }
        default:
          break
        }
      }
      connection.start(queue: queue)
    }

    private func receiveNext() {
      guard let connection else { return }
      connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) {
        [weak self] content, _, isComplete, error in
        guard let self else { return }
        if let content, !content.isEmpty {
          let arrivalMs = ArenaClock.nowMs()
          lock.withLock { self._stats.bytesIn += content.count }
          receiveBuffer.append(content)
          do {
            for message in try ArenaLinkCodec.drainFrames(from: &receiveBuffer) {
              onMessage?(message, arrivalMs)
            }
          } catch {
            lock.withLock { self._stats.framingErrors += 1 }
            fail("framing:\(String(describing: error))")
            return
          }
        }
        if let error {
          fail("receive:\(error.localizedDescription)")
        } else if isComplete {
          fail("peer closed")
        } else {
          receiveNext()
        }
      }
    }

    private func fail(_ reason: String) {
      tearDownLocked()
      setState(.failed(reason))
    }

    private func tearDownLocked() {
      listener?.cancel()
      listener = nil
      browser?.cancel()
      browser = nil
      connection?.cancel()
      connection = nil
      receiveBuffer.removeAll(keepingCapacity: false)
    }

    private func setState(_ newState: ArenaPeerLinkState) {
      guard state != newState else { return }
      state = newState
      onStateChange?(newState)
    }

    private static func parameters() -> NWParameters {
      let parameters = NWParameters.tcp
      parameters.includePeerToPeer = true
      return parameters
    }
  }
#endif
