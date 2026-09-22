import Combine
import Foundation
import os

/// Per-peer Nearby Interaction session state as reported by the targeting NI manager.
enum NearbyPeerSessionState: String, Codable, Equatable, Sendable {
  case idle, awaitingToken, running, suspended, invalidated
}

struct NearbyPeerSample: Equatable, Sendable {
  let playerID: String
  let distanceMeters: Double?
  let hasDirection: Bool
  let capturedAt: Date
}

struct NearbyTransformSolution: Equatable, Sendable {
  let playerID: String
  let residualMeters: Double
  let residualDegrees: Double
  let solvedAt: Date
}

enum NearbyRendezvousFailure: String, Error, Equatable, Sendable {
  case unsupported          // no UWB / NISession.isSupported == false
  case permissionDenied     // NIError.userDidNotAllow
  case sessionInvalidated
}

enum NearbyRendezvousEvent: Equatable, Sendable {
  case sessionState(playerID: String, state: NearbyPeerSessionState)
  case sample(NearbyPeerSample)
  case transformSolved(NearbyTransformSolution)
  case failed(NearbyRendezvousFailure)
}

/// Implemented inside ios/**/Targeting/** (NI session manager + transform solver, ADR 0012).
/// One NISession per peer; tokens are opaque archived NIDiscoveryToken bytes.
@MainActor
protocol NearbyRendezvousDriving: AnyObject {
  /// Archived local NIDiscoveryToken, nil until start() has run.
  var localDiscoveryToken: Data? { get }
  func events() -> AsyncStream<NearbyRendezvousEvent>
  /// Runs the local session; first call triggers the Nearby Interaction permission prompt.
  func start() async throws
  func acceptPeerToken(playerID: String, data: Data) throws
  func removePeer(playerID: String)
  func stop() async
}

enum NearbyRendezvousPhase: Equatable {
  case inactive, unsupported, awaitingPermission, permissionDenied
  case awaitingTokens(received: Int, expected: Int)
  case pointing(solved: Int, expected: Int)
  case retryFacing(pending: Int)
  case solved(count: Int)
}

struct NearbyPeerStatus: Equatable {
  var sessionState: NearbyPeerSessionState = .awaitingToken
  var directionSamples = 0
  var distanceOnlySamples = 0
  var solution: NearbyTransformSolution?
}

/// Quick Play NI rendezvous (ADR 0012): drives the targeting-side NI manager,
/// relays discovery tokens through the combat socket, and reduces per-peer
/// session state to one player-facing phase. Diagnostics are sanitized like
/// DuelFrameDiagnostics — a stable join-order peer index (p1, p2, …), never a
/// player ID.
@MainActor
final class NearbyRendezvousCoordinator: ObservableObject {
  private static let logger = Logger(subsystem: "com.victoriakillzone.nearby", category: "rendezvous")
  private static let diagnosticCapacity = 256

  private let driver: (any NearbyRendezvousDriving)?
  private let now: () -> Date
  private let retryFacingAfter: TimeInterval

  @Published private(set) var phase: NearbyRendezvousPhase = .inactive
  @Published private(set) var peers: [String: NearbyPeerStatus] = [:]
  /// Called once the archived local discovery token exists after start().
  var onLocalToken: ((Data) -> Void)?
  private(set) var diagnostics: [DuelFrameDiagnosticEvent] = []

  private var eventsTask: Task<Void, Never>?
  private var pointingDeadlineTask: Task<Void, Never>?
  private var startedAt: Date?
  private var pointingSince: Date?
  private var peerIndex: [String: Int] = [:]
  private var nextPeerIndex = 1
  private var sampleTotals: [String: Int] = [:]

  init(driver: (any NearbyRendezvousDriving)?, now: @escaping () -> Date = Date.init, retryFacingAfter: TimeInterval = 3) {
    self.driver = driver; self.now = now; self.retryFacingAfter = retryFacingAfter
  }

  var needsSettings: Bool {phase == .permissionDenied}

  func start(peerIDs ids: Set<String>) async {
    eventsTask?.cancel(); eventsTask = nil
    pointingDeadlineTask?.cancel(); pointingDeadlineTask = nil
    peers = [:]; peerIndex = [:]; nextPeerIndex = 1; sampleTotals = [:]
    pointingSince = nil; startedAt = now(); diagnostics = []
    for id in ids {addPeer(id)}
    guard let driver else {
      setPhase(.unsupported); record("niSession", "unsupported"); return
    }
    setPhase(.awaitingPermission); record("niPermission", "prompt")
    do {try await driver.start()} catch {
      let failure = (error as? NearbyRendezvousFailure) ?? .sessionInvalidated
      if failure == .unsupported {
        setPhase(.unsupported); record("niSession", "unsupported")
      } else {
        setPhase(.permissionDenied); record("niPermission", "denied")
      }
      return
    }
    record("niPermission", "granted"); record("niSession", "start")
    if let token = driver.localDiscoveryToken {onLocalToken?(token)}
    recomputePhase()
    let stream = driver.events()
    eventsTask = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled else {return}
        self?.handle(event)
      }
    }
  }

  /// Roster reconciliation: late joiners get a session slot, departed peers are
  /// torn down on the driver. Tokens/positions already held are kept.
  func updatePeers(_ ids: Set<String>) {
    var changed = false
    for id in ids where peers[id] == nil {addPeer(id); changed = true}
    for id in peers.keys where !ids.contains(id) {
      peers.removeValue(forKey: id); peerIndex.removeValue(forKey: id); sampleTotals.removeValue(forKey: id)
      driver?.removePeer(playerID: id); changed = true
    }
    if changed {recomputePhase()}
  }

  func receivePeerToken(playerID: String, data: Data) {
    if peers[playerID] == nil {addPeer(playerID)}
    do {try driver?.acceptPeerToken(playerID: playerID, data: data)}
    catch {record("niSession", "\(peerTag(playerID)) tokenRejected")}
    // The peer keeps .awaitingToken until its sessionState event arrives;
    // token acceptance alone does not prove the NI session is running.
    recomputePhase()
  }

  func retry() async {
    switch phase {
    case .permissionDenied:
      await start(peerIDs: Set(peers.keys))
    case .retryFacing:
      pointingSince = now()
      schedulePointingDeadline()
      recomputePhase()
    default: break
    }
  }

  func stop() async {
    eventsTask?.cancel(); eventsTask = nil
    pointingDeadlineTask?.cancel(); pointingDeadlineTask = nil
    await driver?.stop()
    peers = [:]; peerIndex = [:]; sampleTotals = [:]
    pointingSince = nil
    setPhase(.inactive)
  }

  static func derivePhase(peers: [String: NearbyPeerStatus], startedPointingAt: Date?,
    now: Date, retryAfter: TimeInterval) -> NearbyRendezvousPhase
  {
    let expected = peers.count
    guard expected > 0 else {return .awaitingTokens(received: 0, expected: 0)}
    let ready = peers.values.filter {$0.sessionState != .awaitingToken}.count
    if ready < expected {return .awaitingTokens(received: ready, expected: expected)}
    let solved = peers.values.filter {$0.solution != nil}.count
    if solved == expected {return .solved(count: solved)}
    if let startedPointingAt, now.timeIntervalSince(startedPointingAt) >= retryAfter {
      let pending = peers.values.filter {$0.directionSamples == 0 && $0.solution == nil}.count
      if pending > 0 {return .retryFacing(pending: pending)}
    }
    return .pointing(solved: solved, expected: expected)
  }

  /// Merges this session's NI diagnostics after the frame provider's event
  /// array and writes the combined setup log like DuelFrameDiagnostics.export.
  func exportSetupLog(merging frameLog: URL) throws -> URL {
    let frames = try JSONDecoder().decode([DuelFrameDiagnosticEvent].self,
      from: Data(contentsOf: frameLog))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(frames + diagnostics)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("duel-frame-setup-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  private func addPeer(_ playerID: String) {
    peers[playerID] = NearbyPeerStatus()
    if peerIndex[playerID] == nil {peerIndex[playerID] = nextPeerIndex; nextPeerIndex += 1}
  }

  private func peerTag(_ playerID: String) -> String {"p\(peerIndex[playerID] ?? 0)"}

  private func handle(_ event: NearbyRendezvousEvent) {
    switch event {
    case .sessionState(let playerID, let state):
      if peers[playerID] == nil {addPeer(playerID)}
      peers[playerID]?.sessionState = state
      record("niSession", "\(peerTag(playerID)) state=\(state.rawValue)")
    case .sample(let sample):
      if peers[sample.playerID] == nil {addPeer(sample.playerID)}
      if sample.hasDirection {peers[sample.playerID]?.directionSamples += 1}
      else {peers[sample.playerID]?.distanceOnlySamples += 1}
      let total = (sampleTotals[sample.playerID] ?? 0) + 1
      sampleTotals[sample.playerID] = total
      if total % 10 == 0, let status = peers[sample.playerID] {
        record("niSamples", "\(peerTag(sample.playerID)) direction=\(status.directionSamples) distanceOnly=\(status.distanceOnlySamples)")
      }
    case .transformSolved(let solution):
      if peers[solution.playerID] == nil {addPeer(solution.playerID)}
      peers[solution.playerID]?.solution = solution
      record("niTransform", "\(peerTag(solution.playerID)) residual=\(String(format: "%.2f", solution.residualMeters))m \(String(format: "%.1f", solution.residualDegrees))deg")
    case .failed(let failure):
      record("niSession", "failed \(failure.rawValue)")
      setPhase(failure == .unsupported ? .unsupported : .permissionDenied)
      if failure == .permissionDenied {record("niPermission", "denied")}
      return
    }
    recomputePhase()
  }

  private func recomputePhase() {
    let next = Self.derivePhase(peers: peers, startedPointingAt: pointingSince,
      now: now(), retryAfter: retryFacingAfter)
    if pointingSince == nil {
      if case .awaitingTokens = next {} else {
        pointingSince = now()
        schedulePointingDeadline()
      }
    }
    setPhase(next)
  }

  /// Direction loss while pointing is time-based, so the retry prompt needs a
  /// deadline even when no new driver event arrives to trigger a recompute.
  private func schedulePointingDeadline() {
    pointingDeadlineTask?.cancel()
    pointingDeadlineTask = Task { [weak self, retryFacingAfter] in
      do {try await Task.sleep(for: .seconds(retryFacingAfter))} catch {return}
      self?.recomputePhase()
    }
  }

  private func setPhase(_ next: NearbyRendezvousPhase) {
    guard next != phase else {return}
    phase = next
    record("niPhase", "\(next)")
  }

  private func record(_ kind: String, _ detail: String) {
    let base = startedAt ?? now()
    let event = DuelFrameDiagnosticEvent(elapsedMs: Int64(now().timeIntervalSince(base) * 1000),
      kind: kind, detail: detail)
    diagnostics.append(event)
    if diagnostics.count > Self.diagnosticCapacity {
      diagnostics.removeFirst(diagnostics.count - Self.diagnosticCapacity)
    }
    Self.logger.info("\(event.elapsedMs)ms \(event.kind, privacy: .public): \(event.detail, privacy: .public)")
  }
}
