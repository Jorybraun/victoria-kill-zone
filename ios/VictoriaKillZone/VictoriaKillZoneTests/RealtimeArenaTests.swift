import Foundation
import XCTest
@testable import VictoriaKillZone

final class RealtimeArenaTests: XCTestCase {
  private let date = Date(timeIntervalSince1970: 2000)

  @MainActor
  func testConcurrentStopsBothAwaitActualCameraTeardown() async throws {
    let camera = ArenaLifecycleCamera()
    let controller = makeController(camera)
    await controller.start()
    var firstDone = false, secondDone = false
    let first = Task {await controller.stop(); firstDone = true}
    try await waitFor {await camera.stops == 1}
    let second = Task {await controller.stop(); secondDone = true}
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertFalse(firstDone); XCTAssertFalse(secondDone)
    await camera.releaseStop()
    await first.value; await second.value
    XCTAssertTrue(firstDone); XCTAssertTrue(secondDone)
    let stops = await camera.stops; XCTAssertEqual(stops, 1)
  }

  @MainActor
  func testNewStartWaitsForPreviousCameraTeardown() async throws {
    let camera = ArenaLifecycleCamera()
    let controller = makeController(camera)
    await controller.start()
    let stopping = Task {await controller.stop()}
    try await waitFor {await camera.stops == 1}
    let restarting = Task {await controller.start()}
    try await Task.sleep(for: .milliseconds(10))
    let during = await camera.starts; XCTAssertEqual(during, 1)
    await camera.releaseStop(); await stopping.value; await restarting.value
    let after = await camera.starts; XCTAssertEqual(after, 2)
    await camera.disableStopGate(); await controller.stop()
  }

  @MainActor
  func testStopWaitsForSuspendedStartBeforeStoppingCamera() async throws {
    let camera = ArenaLifecycleCamera(gateStart: true)
    let controller = makeController(camera)
    let starting = Task {await controller.start()}
    try await waitFor {await camera.starts == 1}
    var stopped = false
    let stopping = Task {await controller.stop(); stopped = true}
    try await Task.sleep(for: .milliseconds(10))
    let before = await camera.stops; XCTAssertEqual(before, 0); XCTAssertFalse(stopped)
    await camera.releaseStart()
    try await waitFor {await camera.stops == 1}
    XCTAssertFalse(stopped)
    await camera.releaseStop(); await starting.value; await stopping.value
    let running = await camera.running; XCTAssertFalse(running)
  }

  @MainActor
  func testNonSightingRulesAreRejectedAndStopCombat() async throws {
    for geometry in ["trackedBody", "phoneProxy"] {
      let socket = ArenaModeSocket()
      let camera = ArenaSightingCamera()
      var snapshot = RealtimeCombatTests.snapshot()
      snapshot.rules.geometry = geometry
      socket.initialSnapshot = snapshot
      let controller = RealtimeArenaController(
        session: .init(matchId: "match", code: "ABC123", playerId: "p1", sessionSecret: UUID().uuidString),
        client: ArenaTestTicketClient(), targeting: camera,
        makeTransport: {socket})
      await controller.start()
      try await waitFor {controller.message == RealtimeArenaPresentation.Sighting.incompatibleServerMessage}
      XCTAssertTrue(controller.incompatibleRules, geometry)
      XCTAssertEqual(controller.stage, .unavailable, geometry)
      try await waitFor {socket.closeCount > 0}
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(socket.connectCount, 1, "An incompatible server must not be retried")
      await controller.stop()
    }
  }

  @MainActor
  func testFinishedNonSightingSnapshotStillShowsMismatch() async throws {
    let socket = ArenaModeSocket()
    let camera = ArenaSightingCamera()
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.rules.geometry = "trackedBody"; snapshot.phase = .finished
    socket.initialSnapshot = snapshot
    let controller = RealtimeArenaController(
      session: .init(matchId: "match", code: "ABC123", playerId: "p1", sessionSecret: UUID().uuidString),
      client: ArenaTestTicketClient(), targeting: camera, makeTransport: {socket})
    await controller.start()
    try await waitFor {controller.message == RealtimeArenaPresentation.Sighting.incompatibleServerMessage}
    XCTAssertTrue(controller.incompatibleRules)
    XCTAssertEqual(controller.stage, .unavailable, "A finished mismatched match shows the mismatch, not results")
    await controller.stop()
  }

  @MainActor
  func testSightingMatchStartsRunsAndFiresWithoutSharedFrameTraffic() async throws {
    let socket = ArenaSightingSocket()
    let camera = ArenaSightingCamera()
    let session = PlayerSession(matchId: "private-match-9", code: "PRIVATE-CODE-9",
      playerId: "private-player-9", sessionSecret: "private-session-secret-9")
    socket.initialSnapshot.matchId = session.matchId
    socket.initialSnapshot.players[0].playerId = session.playerId
    let controller = RealtimeArenaController(
      session: session,
      client: ArenaTestTicketClient(), targeting: camera,
      makeTransport: {socket}, localNow: {1000})
    defer {Task {await controller.stop()}}
    await controller.start()
    try await waitFor {controller.stage == .running}
    try await waitFor {controller.eligibility.fire}
    controller.fireOnce()
    try await waitFor {
      socket.sentMessages.contains {
        guard case .command(let envelope) = $0 else {return false}
        if case .fire = envelope.command {return true}
        return false
      }
    }

    let encoded = try socket.sentMessages.map {try JSONEncoder().encode($0)}
    let objects = try encoded.map {try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])}
    let types = objects.compactMap {$0["type"] as? String}
    XCTAssertTrue(types.allSatisfy {["command", "ping", "received", "resume"].contains($0)})
    XCTAssertFalse(types.contains("collab"))
    XCTAssertFalse(types.contains("niToken"))
    XCTAssertFalse(types.contains("map"))
    XCTAssertFalse(encoded.contains {String(decoding: $0, as: UTF8.self).contains("frameReady")})
    let commands = objects.compactMap {object -> String? in
      guard let envelope = object["envelope"] as? [String: Any],
        let command = envelope["command"] as? [String: Any] else {return nil}
      return command["kind"] as? String
    }
    XCTAssertTrue(commands.contains("start"))
    XCTAssertTrue(commands.contains("pose"))
    XCTAssertTrue(commands.contains("fire"))
    XCTAssertFalse(commands.contains("frameReady"))
    XCTAssertFalse(commands.contains("collab"))
    XCTAssertFalse(commands.contains("niToken"))
    let diagnostics = controller.diagnosticEvents()
    XCTAssertFalse(diagnostics.isEmpty)
    XCTAssertTrue(diagnostics.contains { $0.kind == "stage" && $0.detail.contains("running") })
    for privateValue in [session.matchId, session.code, session.playerId, session.sessionSecret] {
      XCTAssertFalse(diagnostics.contains { $0.detail.contains(privateValue) })
    }
  }

  @MainActor
  private func makeController(_ camera: ArenaLifecycleCamera) -> RealtimeArenaController {
    .init(session: .init(matchId: "match", code: "ABC123", playerId: "p1", sessionSecret: UUID().uuidString),
      client: UnavailableGameSessionClient(), targeting: camera)
  }
  @MainActor
  private func waitFor(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await condition()), Date() < deadline {try await Task.sleep(for: .milliseconds(2))}
    let fulfilled = await condition(); XCTAssertTrue(fulfilled)
  }

  func testCollidersUseOnlyObservedJointsWithStableIdentity() {
    let body = skeleton(includeHand: false)
    let colliders = RealtimeAssociationPolicy.colliders(body)
    XCTAssertEqual(colliders.map(\.id), ["head", "torso"])
    XCTAssertEqual(colliders[0].center, [0, 1.7, 0])
    let noHead = TargetingSkeleton(joints: body.joints.filter {$0.name != "head"}, bones: [], capturedAt: date)
    XCTAssertEqual(RealtimeAssociationPolicy.colliders(noHead).map(\.id), ["torso"], "Neck must not fabricate an unobserved head")
  }
  func testConfirmedHitNeverFlashesAnotherPersonsSkeleton() throws {
    let association = try XCTUnwrap(RealtimeAssociationPolicy.associateSighting(
      skeleton: skeleton(), observationConfidence: 0.9, players: Array(players().prefix(2)),
      localPlayerID: "p1", now: date))
    let body = skeleton()
    XCTAssertNotNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p2", association: association, skeleton: body, now: date))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p3", association: association, skeleton: body, now: date))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p2", association: association, skeleton: body, now: date.addingTimeInterval(0.101)))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: nil, association: association, skeleton: body, now: date))
  }
  func testDisconnectedBackgroundAndClockLossDisableAllGameplay() {
    let snapshot = RealtimeCombatTests.snapshot()
    XCTAssertTrue(eligibility(snapshot).fire)
    for result in [eligibility(snapshot, clock: false), eligibility(snapshot, scene: false), eligibility(snapshot, pose: false), eligibility(snapshot, capacity: false)] {
      XCTAssertFalse(result.fire); XCTAssertFalse(result.reload); XCTAssertFalse(result.shield); XCTAssertFalse(result.slowField); XCTAssertFalse(result.begin)
    }
  }
  func testAuthorityReloadShieldRespawnAndProtectionGateFire() {
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.players[0].ammo = 3
    XCTAssertTrue(eligibility(snapshot).reload)
    snapshot.players[0].reloadEndsAtMs = 6000
    XCTAssertFalse(eligibility(snapshot).fire); XCTAssertFalse(eligibility(snapshot).shield)
    snapshot.players[0].reloadEndsAtMs = nil; snapshot.players[0].shield.activeUntilMs = 6000
    XCTAssertFalse(eligibility(snapshot).fire); XCTAssertTrue(eligibility(snapshot).shield, "A raised shield can be lowered")
    snapshot.players[0].shield.activeUntilMs = nil; snapshot.players[0].health = 0
    XCTAssertFalse(eligibility(snapshot).fire); XCTAssertFalse(eligibility(snapshot).slowField)
    snapshot.players[0].health = 100; snapshot.players[0].protectedUntilMs = 5001
    XCTAssertFalse(eligibility(snapshot).fire)
  }
  func testLocalCadenceClosesTheWindowBeforeAuthorityAcknowledgment() {
    let snapshot = RealtimeCombatTests.snapshot()
    XCTAssertFalse(eligibility(snapshot, localFire: 4900).fire)
    XCTAssertTrue(eligibility(snapshot, localFire: 4850).fire)
  }
  func testSightingEligibilityAndBeginIgnoreFrameReadiness() {
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.rules.geometry = "sighting"
    snapshot.players[0].frameReady = false; snapshot.players[1].frameReady = false
    // No shared frame exists under sighting: a fresh pose and a connected
    // roster are the entire fire and begin gates (ADR 0013).
    XCTAssertTrue(eligibility(snapshot).fire)
    snapshot.phase = .calibrating
    XCTAssertTrue(eligibility(snapshot).begin)
    snapshot.players[1].connected = false
    let waiting = eligibility(snapshot)
    XCTAssertFalse(waiting.begin); XCTAssertFalse(waiting.fire)
    XCTAssertEqual(waiting.reason, "Waiting for opponent")
  }
  func testSlowFieldIsUnavailableWhileFireAndShieldRemain() {
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.rules.geometry = "sighting"
    snapshot.players[0].frameReady = false; snapshot.players[1].frameReady = false
    let result = eligibility(snapshot)
    XCTAssertFalse(result.slowField)
    XCTAssertTrue(result.fire); XCTAssertTrue(result.shield)
  }
  func testSightingAssociationNeedsExactlyOneConnectedRemote() {
    let remote = Array(players().prefix(2))
    let association = RealtimeAssociationPolicy.associateSighting(skeleton: skeleton(), observationConfidence: 0.9,
      players: remote, localPlayerID: "p1", now: date)
    XCTAssertEqual(association?.playerID, "p2")
    XCTAssertEqual(association?.confidence, 0.9)
    XCTAssertNil(RealtimeAssociationPolicy.associateSighting(skeleton: skeleton(), observationConfidence: 0.79,
      players: remote, localPlayerID: "p1", now: date))
    XCTAssertNil(RealtimeAssociationPolicy.associateSighting(skeleton: skeleton(), observationConfidence: 0.9,
      players: players(), localPlayerID: "p1", now: date), "Two or more remote players are ambiguous")
    var disconnected = remote; disconnected[1].connected = false
    XCTAssertNil(RealtimeAssociationPolicy.associateSighting(skeleton: skeleton(), observationConfidence: 0.9,
      players: disconnected, localPlayerID: "p1", now: date))
    XCTAssertNil(RealtimeAssociationPolicy.associateSighting(skeleton: skeleton(at: date.addingTimeInterval(-0.101)),
      observationConfidence: 0.9, players: remote, localPlayerID: "p1", now: date))
  }
  func testSightingPoseBuildsFromCameraRay() throws {
    let ray = TargetingCameraRay(origin: .init(x: 1, y: 2, z: 3), direction: .init(x: 0, y: 0, z: -1),
      capturedAt: date.addingTimeInterval(-0.05))
    let pose = try XCTUnwrap(RealtimePoseBuilder.pose(ray: ray, sequence: 3, matchTimeMs: 1000, now: date))
    XCTAssertEqual(pose.position, [1, 2, 3]); XCTAssertEqual(pose.capturedAtMs, 950, accuracy: 0.001)
    XCTAssertEqual(pose.tracking, "normal")
    let x = pose.orientation[0], y = pose.orientation[1], z = pose.orientation[2], w = pose.orientation[3]
    XCTAssertEqual(x * x + y * y + z * z + w * w, 1, accuracy: 0.001)
    // The constructed orientation must face along the ray direction.
    let forward = [-2 * (x * z + w * y), -2 * (y * z - w * x), -(1 - 2 * (x * x + y * y))]
    XCTAssertEqual(forward[0], 0, accuracy: 0.001); XCTAssertEqual(forward[1], 0, accuracy: 0.001)
    XCTAssertEqual(forward[2], -1, accuracy: 0.001)
    XCTAssertNil(RealtimePoseBuilder.pose(ray: ray, sequence: 4, matchTimeMs: 1000, now: date.addingTimeInterval(0.2)))
  }

  func testBeginNeedsHostAndConnectedOpponentAndRoundClockExcludesCalibration() {
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.phase = .calibrating
    XCTAssertTrue(eligibility(snapshot).begin)
    snapshot.players[1].connected = false; XCTAssertFalse(eligibility(snapshot).begin)
    snapshot.players[1].connected = true; snapshot.players[0].role = "player"; XCTAssertFalse(eligibility(snapshot).begin)
    XCTAssertNil(RealtimeActionEligibility.remainingRoundMs(snapshot: snapshot, now: 12_000))
    snapshot.roundStartedAtMs = 10_000
    XCTAssertEqual(RealtimeActionEligibility.remainingRoundMs(snapshot: snapshot, now: 12_000), 178_000)
    snapshot.players[0].role = "host"; snapshot.phase = .paused
    XCTAssertFalse(eligibility(snapshot).begin, "A started match resumes automatically when authoritative coverage returns")
  }

  private func eligibility(_ snapshot: CombatWire.Snapshot, clock: Bool = true, scene: Bool = true, pose: Bool = true, capacity: Bool = true, localFire: Double? = nil) -> RealtimeActionEligibility {
    .evaluate(snapshot: snapshot, localPlayerID: "p1", clockReady: clock, sceneActive: scene, canSubmit: capacity, poseFresh: pose, localFireAtMs: localFire, matchTimeMs: 5000)
  }
  private func skeleton(includeHand: Bool = true, at: Date? = nil) -> TargetingSkeleton {
    var joints: [TargetingSkeletonJoint] = [.init(name: "head", position: .init(x: 0, y: 1.7, z: 0)),
      .init(name: "neck_1_joint", position: .init(x: 0, y: 1.5, z: 0)), .init(name: "root", position: .init(x: 0, y: 0.9, z: 0))]
    if includeHand {joints.append(.init(name: "leftHand", position: .init(x: 0, y: 1, z: 0)))}
    return .init(joints: joints, bones: [], capturedAt: at ?? date)
  }
  private func players() -> [CombatWire.Player] {
    var players = RealtimeCombatTests.snapshot().players
    for index in 3...4 {var player = players[1]; player.playerId = "p\(index)"; player.displayName = "Player \(index)"; players.append(player)}
    return players
  }
}

private actor ArenaLifecycleCamera: TargetingSession {
  nonisolated let availability = TargetingAvailability.available
  nonisolated let currentSnapshot = TargetingSnapshot.unavailable()
  private let gateStart: Bool
  private var gateStop = true
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var running = false
  init(gateStart: Bool = false) {self.gateStart = gateStart}
  nonisolated func snapshots() -> AsyncStream<TargetingSnapshot> {AsyncStream {$0.finish()}}
  func start() async throws {
    starts += 1
    if gateStart {await withCheckedContinuation {startContinuation = $0}}
    running = true
  }
  func stop() async {
    stops += 1
    if gateStop {await withCheckedContinuation {stopContinuation = $0}}
    running = false
  }
  func releaseStart() {startContinuation?.resume(); startContinuation = nil}
  func releaseStop() {stopContinuation?.resume(); stopContinuation = nil}
  func disableStopGate() {gateStop = false; releaseStop()}
}

private actor ArenaSightingCamera: TargetingSession {
  nonisolated let availability = TargetingAvailability.available
  nonisolated let currentSnapshot = TargetingSnapshot.unavailable()
  private nonisolated let streamPair = AsyncStream<TargetingSnapshot>.makeStream()
  private var cameraTask: Task<Void, Never>?

  nonisolated func snapshots() -> AsyncStream<TargetingSnapshot> {streamPair.stream}
  func start() async throws {
    let continuation = streamPair.continuation
    cameraTask = Task {
      while !Task.isCancelled {
        let now = Date()
        let ray = TargetingCameraRay(origin: .init(x: 0, y: 0, z: 0),
          direction: .init(x: 0, y: 0, z: -1), capturedAt: now)
        continuation.yield(TargetingSnapshot(state: .searching, bodyDetected: false,
          torsoDetected: false, confidence: 0, observedAt: now, poseObservedAt: nil,
          bodyBounds: nil, torsoBounds: nil, headRegion: nil, torsoRegion: nil,
          aimClaim: nil, cameraRay: ray, poseStaleAfter: 0.2))
        do {try await Task.sleep(for: .milliseconds(20))} catch {return}
      }
    }
  }
  func stop() async {
    cameraTask?.cancel(); cameraTask = nil
    streamPair.continuation.finish()
  }
}

@MainActor
private final class ArenaModeSocket: CombatSocketConnecting {
  var output: AsyncThrowingStream<CombatWire.ServerMessage, Error>.Continuation?
  var closeCount = 0
  var connectCount = 0
  var initialSnapshot = RealtimeCombatTests.snapshot()
  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage, Error> {
    connectCount += 1
    let pair = AsyncThrowingStream<CombatWire.ServerMessage, Error>.makeStream()
    output = pair.continuation
    output?.yield(.snapshot(initialSnapshot, eventSequence: 0, clientSequence: 0, release: nil))
    return pair.stream
  }
  func send(_ message: CombatWire.ClientMessage) async throws {}
  func close() {closeCount += 1; output?.finish(); output = nil}
}

@MainActor
private final class ArenaSightingSocket: CombatSocketConnecting {
  var output: AsyncThrowingStream<CombatWire.ServerMessage, Error>.Continuation?
  var sentMessages: [CombatWire.ClientMessage] = []
  var initialSnapshot = RealtimeCombatTests.snapshot()
  var eventSequence = 0
  let serverTime = 5000.0

  init() {
    initialSnapshot.rules.geometry = "sighting"
    initialSnapshot.matchTimeMs = serverTime
    initialSnapshot.phase = .calibrating
    initialSnapshot.roundStartedAtMs = nil
    for index in initialSnapshot.players.indices {initialSnapshot.players[index].frameReady = false}
  }

  func connect(ticket: CombatAccessTicket) throws -> AsyncThrowingStream<CombatWire.ServerMessage, Error> {
    let pair = AsyncThrowingStream<CombatWire.ServerMessage, Error>.makeStream()
    output = pair.continuation
    output?.yield(.snapshot(initialSnapshot, eventSequence: 0, clientSequence: 0, release: nil))
    return pair.stream
  }

  func send(_ message: CombatWire.ClientMessage) async throws {
    sentMessages.append(message)
    switch message {
    case .ping(let nonce, let sent):
      output?.yield(.pong(nonce: nonce, clientSentAtMs: sent,
        serverReceivedAtMs: serverTime, serverSentAtMs: serverTime))
    case .command(let envelope):
      if case .start = envelope.command {
        var running = initialSnapshot
        running.phase = .running
        running.roundStartedAtMs = serverTime
        eventSequence += 1
        output?.yield(.snapshot(running, eventSequence: eventSequence,
          clientSequence: envelope.clientSequence, release: nil))
      } else {
        output?.yield(.ack(commandId: envelope.commandId, clientSequence: envelope.clientSequence,
          replayed: false, eventSequence: eventSequence))
      }
    default:
      break
    }
  }

  func close() {output?.finish(); output = nil}
}

private struct ArenaTestTicketClient: GameSessionClient {
  let availability = GameSessionAvailability.available
  func combatTicket(session: PlayerSession) async throws -> CombatAccessTicket {
    try CombatAccessTicket(endpoint: XCTUnwrap(URL(string: "https://combat.example.test/v1/matches/\(session.matchId)/connect")),
      token: UUID().uuidString, expiresAt: Date().addingTimeInterval(120), authorityEpoch: 1, frameEpoch: 1)
  }
  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession {throw GameSessionClientError.notConfigured}
  func setReady(session: PlayerSession, isReady: Bool) async throws {}
  func startDuel(session: PlayerSession) async throws {}
  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult {throw GameSessionClientError.notConfigured}
  nonisolated func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> {AsyncThrowingStream {$0.finish()}}
  nonisolated func connectionStates() -> AsyncStream<GameSessionConnectionState> {AsyncStream {$0.finish()}}
}
