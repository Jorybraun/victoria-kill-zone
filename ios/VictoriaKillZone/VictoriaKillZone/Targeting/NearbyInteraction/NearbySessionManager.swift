import Foundation

/// Per-peer NI configuration the manager derives from the policy's bootstrap
/// mode. Kept framework-free so the hedge ordering is testable on any host.
struct NearbyPeerSessionPlan: Equatable, Sendable {
  let peerID: String
  let token: Data
  /// Maps to `NINearbyPeerConfiguration.isCameraAssistanceEnabled`. Apple
  /// requires `ARSession` collaboration to be off while this is on, so the
  /// manager refuses the plan when collaboration has already started.
  let cameraAssistance: Bool
}

enum NearbySessionPlanError: Error, Equatable {
  /// `isCameraAssistanceEnabled` with `isCollaborationEnabled == true`.
  case cameraAssistanceAfterCollaboration
  case peerCapExceeded
  case duplicatePeer
}

/// Decides which NISessions should exist. One session per peer, never more
/// than `NearbyRendezvousPolicy.maximumPeers` (ADR 0012 §1).
enum NearbySessionPlanner {
  static func plans(
    for peers: [String], tokens: (String) -> Data?, mode: NearbyBootstrapMode,
    collaborationStarted: Bool
  ) throws -> [NearbyPeerSessionPlan] {
    guard Set(peers).count == peers.count else { throw NearbySessionPlanError.duplicatePeer }
    guard peers.count <= NearbyRendezvousPolicy.maximumPeers else { throw NearbySessionPlanError.peerCapExceeded }
    if mode.usesCameraAssistance, collaborationStarted {
      throw NearbySessionPlanError.cameraAssistanceAfterCollaboration
    }
    return peers.compactMap { peer in
      tokens(peer).map {
        NearbyPeerSessionPlan(peerID: peer, token: $0, cameraAssistance: mode.usesCameraAssistance)
      }
    }
  }
}

#if os(iOS) && canImport(NearbyInteraction) && canImport(ARKit)
import ARKit
import NearbyInteraction

/// Owns the per-peer `NISession`s for one match epoch and pumps their
/// updates into `NearbyRendezvousPolicy`. Ranging is expressed in the local
/// ARKit world frame using the camera pose supplied by the caller each tick.
@MainActor
final class NearbySessionManager: NSObject {
  struct Availability: Equatable {
    let supportsPreciseDistance: Bool
    let supportsDirection: Bool
    let supportsCameraAssistance: Bool

    static var current: Availability {
      let caps = NISession.deviceCapabilities
      return Availability(
        supportsPreciseDistance: caps.supportsPreciseDistanceMeasurement,
        supportsDirection: caps.supportsDirectionMeasurement,
        supportsCameraAssistance: caps.supportsCameraAssistance)
    }
  }

  private(set) var policy = NearbyRendezvousPolicy()
  private(set) var collaborationStarted = false
  private var sessions: [String: NISession] = [:]
  private var sessionPeers: [ObjectIdentifier: String] = [:]
  /// Roster members other than the local peer; one session exists per entry.
  private var rosterPeers: [String] = []
  /// The configuration each session was last run with; reused on timeout
  /// re-runs and after suspension instead of building a fresh plain config.
  private var configurations: [String: NINearbyPeerConfiguration] = [:]
  /// The `policy.tokenGeneration(for:)` a session was last run at; a changed
  /// generation means a new peer token arrived and the session must re-run.
  private var runningGeneration: [String: Int] = [:]
  /// Whether the currently built sessions carry `isCameraAssistanceEnabled`.
  private var sessionsUseCameraAssistance = false
  private var latestCameraPose: NearbyRigidPose?
  private let relay: any NearbyRendezvousRelaying
  private var tokenInboundTask: Task<Void, Never>?
  private var rangingInboundTask: Task<Void, Never>?
  private var pumpTask: Task<Void, Never>?
  private var arSession: ARSession?

  var onSnapshot: (@MainActor (NearbyRendezvousSnapshot) -> Void)?

  init(relay: any NearbyRendezvousRelaying) {
    self.relay = relay
    super.init()
  }

  /// Serialized `NIDiscoveryToken` for the opaque `niToken` relay message.
  static func serialize(_ token: NIDiscoveryToken) throws -> Data {
    try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
  }

  static func deserialize(_ data: Data) throws -> NIDiscoveryToken {
    guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data)
    else { throw NearbyRendezvousFailure.invalidToken }
    return token
  }

  func start(epoch: UInt16, localPeerID: String, hostPeerID: String, roster: [String],
    arSession: ARSession
  ) throws {
    guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
      throw NearbyRendezvousFailure.unsupported
    }
    stop()
    self.arSession = arSession
    let bootstrap: NearbyBootstrapMode = Availability.current.supportsDirection ? .plain : .cameraAssisted
    try policy.configure(epoch: epoch, localPeerID: localPeerID, hostPeerID: hostPeerID,
      roster: roster, bootstrap: bootstrap)
    collaborationStarted = false
    rosterPeers = roster.filter { $0 != localPeerID }
    sessionsUseCameraAssistance = bootstrap.usesCameraAssistance
      && NISession.deviceCapabilities.supportsCameraAssistance
    // A discovery token identifies the NISession that issued it, so each
    // roster peer gets its own session up front; sessions run once the
    // matching peer token arrives (see reconcileSessions).
    var localTokens: [String: Data] = [:]
    for peer in rosterPeers {
      let session = NISession()
      session.delegate = self
      session.delegateQueue = .main
      guard let token = session.discoveryToken else { throw NearbyRendezvousFailure.invalidToken }
      sessions[peer] = session
      sessionPeers[ObjectIdentifier(session)] = peer
      localTokens[peer] = try Self.serialize(token)
    }
    try policy.recordLocalTokens(localTokens)
    tokenInboundTask = Task { [weak self] in
      guard let self else { return }
      for await (peerID, token) in relay.nearbyTokens() {
        await self.receiveTokens(from: peerID, token: token)
      }
    }
    rangingInboundTask = Task { [weak self] in
      guard let self else { return }
      for await (peerID, data) in relay.nearbyRanging() {
        await self.receiveRanging(from: peerID, data: data)
      }
    }
    pumpTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(200))
        await self?.pump()
      }
    }
    publish()
  }

  func stop() {
    tokenInboundTask?.cancel()
    rangingInboundTask?.cancel()
    pumpTask?.cancel()
    tokenInboundTask = nil
    rangingInboundTask = nil
    pumpTask = nil
    for session in sessions.values { session.invalidate() }
    sessions = [:]
    sessionPeers = [:]
    rosterPeers = []
    configurations = [:]
    runningGeneration = [:]
    sessionsUseCameraAssistance = false
    arSession = nil
    policy.stop()
    publish()
  }

  /// Called by the DuelFrame provider before it flips
  /// `ARWorldTrackingConfiguration.isCollaborationEnabled` on. Returns false
  /// while a camera-assisted bootstrap is still running. Camera assistance
  /// must be off the sessions before collab starts, so an assisted set is
  /// rebuilt without it first (the new tokens ride the rate-limited token
  /// lane — rare enough to fit its ~1/s budget).
  func markCollaborationStarting() -> Bool {
    guard policy.snapshot.collaborationMayStart else { return false }
    if sessionsUseCameraAssistance { rebuildSessions(cameraAssistance: false) }
    collaborationStarted = true
    policy.endBootstrap()
    publish()
    return true
  }

  /// Latest ARKit camera transform, column-major, from the frame loop.
  func updateCameraPose(_ columnMajor: [Double]) {
    latestCameraPose = NearbyRigidPose(columnMajor: columnMajor)
  }

  // MARK: Private

  private func receiveTokens(from peerID: String, token: String) async {
    policy.receive(tokens: Data(token.utf8), from: peerID, at: Date())
    reconcileSessions()
    publish()
  }

  private func receiveRanging(from peerID: String, data: Data) async {
    policy.receive(ranging: data, from: peerID, at: Date())
    publish()
  }

  private func pump() async {
    let now = Date()
    policy.flushSamples()
    policy.solveIfDue(at: now)
    if policy.directionAppearsUnavailable, !collaborationStarted {
      if policy.advanceHedge(at: now) != nil {
        rebuildSessions(cameraAssistance: policy.snapshot.bootstrapMode.usesCameraAssistance)
      }
    }
    for data in policy.drainOutboundTokens() {
      guard let string = String(data: data, encoding: .utf8) else { continue }
      await relay.sendNearbyToken(string)
    }
    for data in policy.drainOutboundRanging() { await relay.sendNearbyRanging(data) }
    publish()
  }

  private func reconcileSessions() {
    let plans: [NearbyPeerSessionPlan]
    do {
      plans = try NearbySessionPlanner.plans(for: rosterPeers,
        tokens: policy.token(for:), mode: policy.snapshot.bootstrapMode,
        collaborationStarted: collaborationStarted)
    } catch {
      policy.fail(.cameraAssistanceRequiresCollaborationOff)
      return
    }
    for plan in plans {
      let generation = policy.tokenGeneration(for: plan.peerID)
      guard let session = sessions[plan.peerID],
        runningGeneration[plan.peerID] != generation,
        let peerToken = try? Self.deserialize(plan.token)
      else { continue }
      let configuration = NINearbyPeerConfiguration(peerToken: peerToken)
      if sessionsUseCameraAssistance, NISession.deviceCapabilities.supportsCameraAssistance {
        configuration.isCameraAssistanceEnabled = true
      }
      if configuration.isCameraAssistanceEnabled, let arSession {
        session.setARSession(arSession)
      }
      configurations[plan.peerID] = configuration
      session.run(configuration)
      runningGeneration[plan.peerID] = generation
    }
  }

  /// Invalidates every session, rebuilds one per roster peer (new discovery
  /// tokens are queued on the token lane), and re-runs any peer whose remote
  /// token is already in. Used by the ordered hedge and by
  /// `markCollaborationStarting` to drop camera assistance before collab.
  private func rebuildSessions(cameraAssistance: Bool) {
    for session in sessions.values { session.invalidate() }
    sessions = [:]
    sessionPeers = [:]
    configurations = [:]
    runningGeneration = [:]
    sessionsUseCameraAssistance = cameraAssistance
      && NISession.deviceCapabilities.supportsCameraAssistance
    var localTokens: [String: Data] = [:]
    for peer in rosterPeers {
      let session = NISession()
      session.delegate = self
      session.delegateQueue = .main
      sessions[peer] = session
      sessionPeers[ObjectIdentifier(session)] = peer
      if let token = session.discoveryToken, let data = try? Self.serialize(token) {
        localTokens[peer] = data
      }
    }
    try? policy.recordLocalTokens(localTokens)
    reconcileSessions()
  }

  private func publish() {
    onSnapshot?(policy.snapshot)
  }
}

extension NearbySessionManager: NISessionDelegate {
  nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
    let now = Date()
    Task { @MainActor in
      guard let peerID = self.sessionPeers[ObjectIdentifier(session)], let pose = self.latestCameraPose
      else { return }
      for object in nearbyObjects {
        guard let distance = object.distance else { continue }
        let direction = object.direction.map {
          NearbyVector3(x: Double($0.x), y: Double($0.y), z: Double($0.z))
        }
        let sample = NearbyRangingSample(peerID: peerID, distanceMeters: Double(distance),
          direction: direction, cameraPose: pose, observedAt: now)
        self.policy.ingestLocalSample(sample, at: now)
      }
      self.publish()
    }
  }

  nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
    reason: NINearbyObject.RemovalReason
  ) {
    // Timeouts re-run the stored configuration; the peer token is unchanged.
    Task { @MainActor in
      guard reason == .timeout, let peerID = self.sessionPeers[ObjectIdentifier(session)],
        let configuration = self.configurations[peerID]
      else { return }
      session.run(configuration)
    }
  }

  nonisolated func session(_ session: NISession, didInvalidateWith error: any Error) {
    Task { @MainActor in
      guard let peerID = self.sessionPeers[ObjectIdentifier(session)] else { return }
      self.sessions[peerID] = nil
      self.sessionPeers[ObjectIdentifier(session)] = nil
      if (error as? NIError)?.code == .userDidNotAllow {
        self.policy.fail(.permissionDenied)
      } else {
        self.reconcileSessions()
      }
      self.publish()
    }
  }

  nonisolated func sessionSuspensionEnded(_ session: NISession) {
    Task { @MainActor in
      guard let peerID = self.sessionPeers[ObjectIdentifier(session)],
        let configuration = self.configurations[peerID]
      else { return }
      session.run(configuration)
    }
  }
}
#endif
