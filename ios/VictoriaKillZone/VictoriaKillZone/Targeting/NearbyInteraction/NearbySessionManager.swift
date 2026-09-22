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
  private var latestCameraPose: NearbyRigidPose?
  private let relay: any NearbyRendezvousRelaying
  private var inboundTask: Task<Void, Never>?
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
    // One discovery token is shared by every session on this device.
    let probe = NISession()
    guard let token = probe.discoveryToken else { throw NearbyRendezvousFailure.invalidToken }
    probe.invalidate()
    try policy.recordLocalToken(try Self.serialize(token))
    inboundTask = Task { [weak self] in
      guard let self else { return }
      for await (peerID, data) in relay.nearbyEnvelopes() {
        await self.receive(from: peerID, data: data)
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
    inboundTask?.cancel()
    pumpTask?.cancel()
    inboundTask = nil
    pumpTask = nil
    for session in sessions.values { session.invalidate() }
    sessions = [:]
    sessionPeers = [:]
    arSession = nil
    policy.stop()
    publish()
  }

  /// Called by the DuelFrame provider before it flips
  /// `ARWorldTrackingConfiguration.isCollaborationEnabled` on. Returns false
  /// while a camera-assisted bootstrap is still running.
  func markCollaborationStarting() -> Bool {
    guard policy.snapshot.collaborationMayStart else { return false }
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

  private func receive(from peerID: String, data: Data) async {
    policy.receive(from: peerID, data: data, at: Date())
    reconcileSessions()
    publish()
  }

  private func pump() async {
    let now = Date()
    policy.flushSamples()
    policy.solveIfDue(at: now)
    if policy.directionAppearsUnavailable, !collaborationStarted {
      if policy.advanceHedge(at: now) != nil { rebuildSessions() }
    }
    for data in policy.drainOutbound() { await relay.sendNearbyEnvelope(data) }
    publish()
  }

  private func reconcileSessions() {
    let plans: [NearbyPeerSessionPlan]
    do {
      plans = try NearbySessionPlanner.plans(for: policy.snapshot.rangingPeers,
        tokens: policy.token(for:), mode: policy.snapshot.bootstrapMode,
        collaborationStarted: collaborationStarted)
    } catch {
      policy.fail(.cameraAssistanceRequiresCollaborationOff)
      return
    }
    for plan in plans where sessions[plan.peerID] == nil { run(plan) }
  }

  private func rebuildSessions() {
    for session in sessions.values { session.invalidate() }
    sessions = [:]
    sessionPeers = [:]
    reconcileSessions()
  }

  private func run(_ plan: NearbyPeerSessionPlan) {
    guard let token = try? Self.deserialize(plan.token) else { return }
    let configuration = NINearbyPeerConfiguration(peerToken: token)
    if plan.cameraAssistance, NISession.deviceCapabilities.supportsCameraAssistance {
      configuration.isCameraAssistanceEnabled = true
    }
    let session = NISession()
    session.delegate = self
    session.delegateQueue = .main
    if configuration.isCameraAssistanceEnabled, let arSession {
      session.setARSession(arSession)
    }
    sessions[plan.peerID] = session
    sessionPeers[ObjectIdentifier(session)] = plan.peerID
    session.run(configuration)
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
    // Timeouts re-run the same configuration; the peer token is unchanged.
    Task { @MainActor in
      guard reason == .timeout, let peerID = self.sessionPeers[ObjectIdentifier(session)],
        let token = self.policy.token(for: peerID), let peerToken = try? Self.deserialize(token)
      else { return }
      session.run(NINearbyPeerConfiguration(peerToken: peerToken))
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
        let token = self.policy.token(for: peerID), let peerToken = try? Self.deserialize(token)
      else { return }
      let configuration = NINearbyPeerConfiguration(peerToken: peerToken)
      configuration.isCameraAssistanceEnabled = self.policy.snapshot.bootstrapMode.usesCameraAssistance
        && !self.collaborationStarted && NISession.deviceCapabilities.supportsCameraAssistance
      session.run(configuration)
    }
  }
}
#endif
