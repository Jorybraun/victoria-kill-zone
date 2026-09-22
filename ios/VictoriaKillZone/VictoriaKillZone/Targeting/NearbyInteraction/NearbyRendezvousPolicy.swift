import Foundation

/// Which NI bootstrap the session runs (ADR 0012 §5, ordered hedge).
enum NearbyBootstrapMode: String, Equatable, Sendable {
  /// Plain NI; ARKit collaboration may run alongside from the start.
  case plain
  /// `isCameraAssistanceEnabled` on every peer configuration. Requires
  /// `isCollaborationEnabled = false` on the shared ARSession, so collab
  /// must not start until the bootstrap phase ends.
  case cameraAssisted
  /// No direction at all: few-steps ranging and a least-squares fit.
  case distanceOnly

  var next: NearbyBootstrapMode? {
    switch self {
    case .plain: .cameraAssisted
    case .cameraAssisted: .distanceOnly
    case .distanceOnly: nil
    }
  }

  var usesCameraAssistance: Bool { self == .cameraAssisted }
  var solvesDistanceOnly: Bool { self == .distanceOnly }
}

enum NearbyRendezvousPhase: Equatable, Sendable {
  case idle
  /// Sessions may run; ARKit collaboration is held off while camera
  /// assistance is on.
  case bootstrap
  /// Transforms solved (or bootstrap abandoned); collab may start and NI
  /// keeps ranging for live peer positions.
  case live
}

enum NearbyRendezvousStage: Equatable, Sendable {
  case idle
  case awaitingTokens
  case ranging
  case needsRetry(NearbyRendezvousRetryReason)
  case solved
  case failed(NearbyRendezvousFailure)
}

struct NearbyRendezvousSnapshot: Equatable, Sendable {
  var stage: NearbyRendezvousStage = .idle
  var phase: NearbyRendezvousPhase = .idle
  var bootstrapMode: NearbyBootstrapMode = .plain
  var epoch: UInt16?
  var hostPeerID: String?
  var localPeerID: String?
  /// Peers whose token has arrived and whose NI session should be running.
  var rangingPeers: [String] = []
  var alignments: [String: NearbyPeerAlignment] = [:]
  /// Direction-bearing sample counts per link, for the setup log.
  var directionSamples: [String: Int] = [:]

  /// The camera-assisted bootstrap must finish before `isCollaborationEnabled`
  /// flips on; plain NI never blocks collab.
  var collaborationMayStart: Bool {
    !(phase == .bootstrap && bootstrapMode.usesCameraAssistance)
  }

  /// The local device's transform into the host frame, when solved.
  var localToHostFrame: NearbyFrameTransform? {
    guard let localPeerID else { return nil }
    if localPeerID == hostPeerID { return .identity }
    return alignments[localPeerID]?.toHostFrame
  }
}

/// Pure rendezvous state: roster and token bookkeeping, bounded sample
/// windows for every link, pairwise + graph solving, and the ordered U2
/// hedge. Owns no NISession and no socket; `NearbySessionManager` and the
/// client-flow adapter feed it.
struct NearbyRendezvousPolicy: Sendable {
  /// One NISession per peer, three at the four-player cap (ADR 0012 §1).
  static let maximumPeers = 3
  static let sampleWindow = 40
  static let maximumSampleAge: TimeInterval = 6
  /// How long a link may range without any direction before the hedge advances.
  static let directionTimeout: TimeInterval = 8
  /// Resolve at most this often; NI updates at several hertz per peer.
  static let minimumSolveInterval: TimeInterval = 0.25

  private(set) var snapshot = NearbyRendezvousSnapshot()
  private var roster: Set<String> = []
  private var tokens: [String: Data] = [:]
  private var ownToken: Data?
  /// `localSamples[peer]`: this device toward `peer`.
  private var localSamples: [String: [NearbyRangingSample]] = [:]
  /// `remoteSamples[from]?[to]`: device `from` toward `to`, relayed.
  private var remoteSamples: [String: [String: [NearbyRangingSample]]] = [:]
  private var rangingStartedAt: [String: Date] = [:]
  private var lastSolvedAt: Date?
  private var pendingOutbound: [Data] = []
  private var pendingSamples: [NearbyRangingSample] = []

  var localToken: Data? { ownToken }
  func token(for peerID: String) -> Data? { tokens[peerID] }

  // MARK: Lifecycle

  mutating func configure(epoch: UInt16, localPeerID: String, hostPeerID: String,
    roster participants: [String], bootstrap: NearbyBootstrapMode = .plain
  ) throws {
    guard epoch > 0 else { throw NearbyRendezvousFailure.invalidConfiguration }
    if let current = snapshot.epoch, epoch <= current { throw NearbyRendezvousFailure.staleEpoch }
    let others = Set(participants).subtracting([localPeerID])
    guard participants.contains(localPeerID), participants.contains(hostPeerID)
    else { throw NearbyRendezvousFailure.invalidConfiguration }
    guard others.count <= Self.maximumPeers else { throw NearbyRendezvousFailure.tooManyPeers }
    reset()
    roster = Set(participants)
    snapshot = NearbyRendezvousSnapshot(stage: .awaitingTokens, phase: .bootstrap,
      bootstrapMode: bootstrap, epoch: epoch, hostPeerID: hostPeerID, localPeerID: localPeerID)
  }

  mutating func stop() {
    reset()
    snapshot = NearbyRendezvousSnapshot()
  }

  mutating func fail(_ failure: NearbyRendezvousFailure) {
    snapshot.stage = .failed(failure)
    snapshot.phase = .live
  }

  /// Advances the ordered hedge: plain → camera-assisted → distance-only.
  /// Returns the new mode, or nil when the hedge is exhausted.
  @discardableResult
  mutating func advanceHedge(at now: Date) -> NearbyBootstrapMode? {
    guard let next = snapshot.bootstrapMode.next else { return nil }
    snapshot.bootstrapMode = next
    snapshot.phase = .bootstrap
    snapshot.alignments = [:]
    for peer in snapshot.rangingPeers { rangingStartedAt[peer] = now }
    snapshot.stage = snapshot.rangingPeers.isEmpty ? .awaitingTokens : .ranging
    return next
  }

  /// Ends the bootstrap phase regardless of solve state so ARKit collaboration
  /// may start; ranging continues for live peer positions.
  mutating func endBootstrap() {
    guard snapshot.phase == .bootstrap else { return }
    snapshot.phase = .live
  }

  // MARK: Tokens

  /// Records this device's serialized `NIDiscoveryToken` and queues the token
  /// envelope for relay. Call `drainOutbound()` to send.
  mutating func recordLocalToken(_ token: Data) throws {
    guard let epoch = snapshot.epoch else { throw NearbyRendezvousFailure.notConfigured }
    guard !token.isEmpty else { throw NearbyRendezvousFailure.invalidToken }
    ownToken = token
    pendingOutbound.append(try NearbyRelayEnvelope.token(epoch: epoch, token: token).encoded())
  }

  /// Applies a relayed envelope from `peerID`. Unknown peers and other epochs
  /// are ignored, not fatal: the relay is shared with the whole room.
  mutating func receive(from peerID: String, data: Data, at now: Date) {
    guard let epoch = snapshot.epoch, roster.contains(peerID), peerID != snapshot.localPeerID,
      let envelope = try? NearbyRelayEnvelope.decode(data), envelope.epoch == epoch
    else { return }
    switch envelope {
    case .token(_, let token):
      guard tokens[peerID] == nil else { return }
      tokens[peerID] = token
      snapshot.rangingPeers = tokens.keys.sorted()
      rangingStartedAt[peerID] = now
      if case .awaitingTokens = snapshot.stage { snapshot.stage = .ranging }
    case .ranging(_, let samples):
      for sample in samples where roster.contains(sample.peerID) && sample.peerID != peerID {
        var window = remoteSamples[peerID, default: [:]][sample.peerID, default: []]
        Self.append(sample, to: &window, now: now)
        remoteSamples[peerID, default: [:]][sample.peerID] = window
      }
    }
  }

  /// Encoded envelopes ready for the relay, in order. Empties the queue.
  mutating func drainOutbound() -> [Data] {
    defer { pendingOutbound.removeAll() }
    return pendingOutbound
  }

  // MARK: Samples

  /// A local UWB reading toward a peer. Queues it for relay (batched by
  /// `flushSamples`) and triggers a solve when due.
  mutating func ingestLocalSample(_ sample: NearbyRangingSample, at now: Date) {
    guard snapshot.epoch != nil, roster.contains(sample.peerID), sample.isValid else { return }
    var window = localSamples[sample.peerID, default: []]
    guard Self.append(sample, to: &window, now: now) else { return }
    localSamples[sample.peerID] = window
    if sample.hasDirection {
      snapshot.directionSamples[sample.peerID, default: 0] += 1
    }
    pendingSamples.append(sample)
    if pendingSamples.count >= NearbyRelayEnvelope.maximumSamplesPerEnvelope { flushSamples() }
    solveIfDue(at: now)
  }

  /// Batches recent local samples into one relay envelope.
  mutating func flushSamples() {
    guard let epoch = snapshot.epoch, !pendingSamples.isEmpty else { return }
    let batch = Array(pendingSamples.suffix(NearbyRelayEnvelope.maximumSamplesPerEnvelope))
    pendingSamples.removeAll()
    if let data = try? NearbyRelayEnvelope.ranging(epoch: epoch, samples: batch).encoded() {
      pendingOutbound.append(data)
    }
  }

  // MARK: Solving

  mutating func solveIfDue(at now: Date) {
    if let lastSolvedAt, now.timeIntervalSince(lastSolvedAt) < Self.minimumSolveInterval { return }
    solve(at: now)
  }

  /// Solves every link this device can see (its own, plus relayed pairs
  /// between other peers), cross-checks through the graph and updates the
  /// stage. Once solved, later solves refine alignments in place.
  mutating func solve(at now: Date) {
    guard let localPeerID = snapshot.localPeerID, let hostPeerID = snapshot.hostPeerID,
      snapshot.stage != .idle
    else { return }
    if case .failed = snapshot.stage { return }
    lastSolvedAt = now
    pruneStale(now: now)

    var graph = NearbyFrameGraph()
    var directionless: Set<String> = []
    var lowMotion: Set<String> = []
    let participants = roster.sorted()
    for (index, a) in participants.enumerated() {
      for b in participants[(index + 1)...] {
        guard let aToB = samples(from: a, to: b), let bToA = samples(from: b, to: a) else { continue }
        if snapshot.bootstrapMode.solvesDistanceOnly {
          let ranges = NearbyDistanceOnlySolver.ranges(local: aToB, remote: bToA)
          switch NearbyDistanceOnlySolver.solve(ranges) {
          case .solved(let solution):
            graph.setLink(from: b, to: a, transform: solution.localFromRemote)
          case .insufficientMotion, .insufficientRanges:
            if a == localPeerID || b == localPeerID { lowMotion.insert(a == localPeerID ? b : a) }
          }
          continue
        }
        switch NearbyPairwiseSolver.solve(local: aToB, remote: bToA) {
        case .solved(let solution):
          graph.setLink(from: b, to: a, transform: solution.localFromRemote)
        case .needsDirection, .insufficientPairs:
          if a == localPeerID || b == localPeerID { directionless.insert(a == localPeerID ? b : a) }
        }
      }
    }

    var alignments: [String: NearbyPeerAlignment] = [:]
    var inconsistent: [String] = []
    for peer in participants where peer != hostPeerID {
      switch graph.alignment(of: peer, toHost: hostPeerID, participants: participants) {
      case .solved(let alignment): alignments[peer] = alignment
      case .inconsistent: inconsistent.append(peer)
      case .unreachable: break
      }
    }
    snapshot.alignments = alignments

    let localSolved = localPeerID == hostPeerID || alignments[localPeerID] != nil
    if localSolved {
      snapshot.stage = .solved
      if snapshot.phase == .bootstrap { snapshot.phase = .live }
      return
    }
    if inconsistent.contains(localPeerID) {
      snapshot.stage = .needsRetry(.inconsistentLinks(peerIDs: inconsistent.sorted()))
      return
    }
    let missingTokens = roster.subtracting(tokens.keys).subtracting([localPeerID]).sorted()
    if snapshot.rangingPeers.isEmpty {
      snapshot.stage = .awaitingTokens
      return
    }
    let timedOut = snapshot.rangingPeers.filter { peer in
      rangingStartedAt[peer].map { now.timeIntervalSince($0) >= Self.directionTimeout } ?? false
    }
    if snapshot.bootstrapMode.solvesDistanceOnly {
      let stuck = lowMotion.intersection(timedOut).sorted()
      snapshot.stage = stuck.isEmpty ? .ranging : .needsRetry(.insufficientMotion(peerIDs: stuck))
    } else {
      let stuck = directionless.intersection(timedOut).sorted()
      if !stuck.isEmpty {
        snapshot.stage = .needsRetry(.directionUnavailable(peerIDs: stuck))
      } else if !missingTokens.isEmpty, directionless.isEmpty {
        snapshot.stage = .needsRetry(.awaitingTokens(peerIDs: missingTokens))
      } else {
        snapshot.stage = .ranging
      }
    }
  }

  /// True when the hedge should advance: every link of this device has been
  /// ranging past the direction timeout with no direction on either side.
  var directionAppearsUnavailable: Bool {
    if case .needsRetry(.directionUnavailable(let peers)) = snapshot.stage {
      return Set(peers) == Set(snapshot.rangingPeers) && !peers.isEmpty
    }
    return false
  }

  // MARK: Private

  private func samples(from source: String, to target: String) -> [NearbyRangingSample]? {
    let window = source == snapshot.localPeerID ? localSamples[target] : remoteSamples[source]?[target]
    guard let window, !window.isEmpty else { return nil }
    return window
  }

  @discardableResult
  private static func append(_ sample: NearbyRangingSample, to window: inout [NearbyRangingSample], now: Date) -> Bool {
    guard now.timeIntervalSince(sample.observedAt) <= maximumSampleAge,
      sample.observedAt.timeIntervalSince(now) <= 1
    else { return false }
    if let last = window.last, sample.observedAt < last.observedAt {
      window.append(sample)
      window.sort { $0.observedAt < $1.observedAt }
    } else {
      window.append(sample)
    }
    if window.count > sampleWindow { window.removeFirst(window.count - sampleWindow) }
    return true
  }

  private mutating func pruneStale(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.maximumSampleAge)
    localSamples = localSamples.mapValues { $0.filter { $0.observedAt >= cutoff } }
    remoteSamples = remoteSamples.mapValues { links in
      links.mapValues { $0.filter { $0.observedAt >= cutoff } }
    }
  }

  private mutating func reset() {
    roster = []
    tokens = [:]
    ownToken = nil
    localSamples = [:]
    remoteSamples = [:]
    rangingStartedAt = [:]
    lastSolvedAt = nil
    pendingOutbound = []
    pendingSamples = []
  }
}
