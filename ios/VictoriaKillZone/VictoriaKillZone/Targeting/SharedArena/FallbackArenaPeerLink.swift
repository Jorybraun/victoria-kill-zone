import CombatTransport
import Foundation

enum ArenaLinkPath: Equatable {
  case undecided
  case quic
  case tcp
}

final class FallbackArenaPeerLink: ArenaPeerLinking, @unchecked Sendable {
  var onMessage: ((ArenaLinkMessage, Int64) -> Void)?
  var onStateChange: ((ArenaPeerLinkState) -> Void)?

  private let primary: any ArenaPeerLinking
  private let fallback: any ArenaPeerLinking
  private let primaryTimeout: TimeInterval
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var _activePath: ArenaLinkPath = .undecided
  private var timer: DispatchWorkItem?
  private var generation = 0
  private var role: ArenaRole?
  private var started = false

  init(
    primary: any ArenaPeerLinking,
    fallback: any ArenaPeerLinking,
    primaryTimeout: TimeInterval = 3,
    queue: DispatchQueue = DispatchQueue(label: "com.victoriakillzone.arena.fallback-link")
  ) {
    self.primary = primary
    self.fallback = fallback
    self.primaryTimeout = max(0, primaryTimeout)
    self.queue = queue
  }

  var activePath: ArenaLinkPath {
    lock.withLock { _activePath }
  }

  var stats: ArenaPeerLinkStats {
    switch activePath {
    case .tcp:
      fallback.stats
    case .undecided, .quic:
      primary.stats
    }
  }

  func start(role: ArenaRole) {
    queue.async { [self] in
      generation += 1
      let token = generation
      if started {
        stopLocked(publish: false)
      }
      started = true
      self.role = role
      setActivePath(.undecided)
      configureCallbacks(for: primary, path: .quic, generation: token)
      configureCallbacks(for: fallback, path: .tcp, generation: token)
      primary.start(role: role)

      let timer = DispatchWorkItem { [weak self] in
        guard let self, self.generation == token, self.activePath == .undecided else { return }
        activateFallback(role: role, generation: token)
      }
      self.timer = timer
      queue.asyncAfter(
        deadline: .now() + primaryTimeout,
        execute: timer
      )
    }
  }

  func stop() {
    queue.async { [self] in
      generation += 1
      stopLocked(publish: true)
      started = false
    }
  }

  func send(_ message: ArenaLinkMessage) {
    switch activePath {
    case .tcp:
      fallback.send(message)
    case .undecided, .quic:
      primary.send(message)
    }
  }

  private func configureCallbacks(
    for link: any ArenaPeerLinking,
    path: ArenaLinkPath,
    generation token: Int
  ) {
    link.onStateChange = { [weak self] state in
      guard let self else { return }
      self.queue.async { [weak self] in
        guard let self, self.generation == token else { return }
        self.handle(state, from: path, generation: token)
      }
    }
    link.onMessage = { [weak self] message, arrivalMs in
      guard let self else { return }
      self.queue.async { [weak self] in
        guard let self, self.generation == token else { return }
        guard self.activePath == path || (path == .quic && self.activePath == .undecided) else {
          return
        }
        self.onMessage?(message, arrivalMs)
      }
    }
  }

  private func handle(
    _ state: ArenaPeerLinkState,
    from path: ArenaLinkPath,
    generation token: Int
  ) {
    guard activePath == path || (path == .quic && activePath == .undecided) else { return }
    if path == .quic {
      switch state {
      case .connected:
        timer?.cancel()
        timer = nil
        setActivePath(.quic)
      case .failed where activePath == .undecided:
        activateFallback(role: role, generation: token)
        return
      default:
        break
      }
    }
    onStateChange?(state)
  }

  private func activateFallback(role: ArenaRole?, generation token: Int) {
    guard generation == token, activePath == .undecided, let role else { return }
    timer?.cancel()
    timer = nil
    primary.stop()
    setActivePath(.tcp)
    fallback.start(role: role)
  }

  private func setActivePath(_ path: ArenaLinkPath) {
    lock.withLock { _activePath = path }
  }

  private func stopLocked(publish: Bool) {
    timer?.cancel()
    timer = nil
    primary.stop()
    fallback.stop()
    setActivePath(.undecided)
    if publish {
      onStateChange?(.idle)
    }
  }
}

enum ArenaPeerLinkFactory {
  static func make(
    matchId: String,
    playerId: String,
    joinSecret: String
  ) -> any ArenaPeerLinking & DuelPeerLink {
    let scope = MatchScope(matchId: matchId)
    #if canImport(Network)
      return FallbackArenaPeerLink(
        primary: CombatTransportArenaLink(
          matchId: matchId,
          playerId: playerId,
          joinSecret: joinSecret
        ),
        fallback: ArenaPeerLink(serviceName: scope.serviceToken)
      )
    #else
      return CombatTransportArenaLink(
        matchId: matchId,
        playerId: playerId,
        joinSecret: joinSecret
      )
    #endif
  }
}
