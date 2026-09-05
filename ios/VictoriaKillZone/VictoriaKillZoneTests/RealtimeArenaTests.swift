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

  func testAssociationSelectsObservedHandMatchAcrossFourPlayers() throws {
    let association = try XCTUnwrap(associate(phones: [phone("p2", x: 0.1), phone("p3", x: 1), phone("p4", x: 2)]))
    XCTAssertEqual(association.playerID, "p2")
    XCTAssertGreaterThanOrEqual(association.confidence, 0.8)
    XCTAssertEqual(association.marginMeters, 0.9, accuracy: 0.001)
  }
  func testAmbiguousNearbyPhonesDoNotPickRosterOrder() {
    let phones = [phone("p2", x: 0.1), phone("p3", x: 0.2), phone("p4", x: 2)]
    XCTAssertNil(associate(phones: phones)); XCTAssertNil(associate(phones: phones.reversed()))
  }
  func testMissingOrStaleCompetitorDoesNotCreateFalseIdentityMargin() {
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], roster: players()))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1), phone("p3", x: 0.11, at: 899), phone("p4", x: 2)], roster: players()))
  }
  func testEliminatedBodyCannotBeReassignedToNearbyLivingPlayer() {
    var roster = players(); roster[1].health = 0
    XCTAssertNil(associate(phones: [phone("p2", x: 0), phone("p3", x: 0.4), phone("p4", x: 2)], roster: roster))
  }
  func testOneRemoteMemberStillRequiresActualHandGeometry() {
    XCTAssertNil(associate(phones: [phone("p2", x: 2)]))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], skeleton: skeleton(includeHand: false)))
  }
  func testStaleFutureUnalignedAndLowConfidenceInputsFailClosed() {
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1, at: 899)]))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1, at: 1001)]))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], skeleton: skeleton(at: date.addingTimeInterval(-0.101))))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], ready: false))
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], confidence: 0.79))
  }
  func testDisconnectedOrUnreadyPlayersCannotOwnObservedBody() {
    var roster = players(); roster[1].connected = false
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], roster: roster))
    roster[1].connected = true; roster[1].frameReady = false
    XCTAssertNil(associate(phones: [phone("p2", x: 0.1)], roster: roster))
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
    let association = try XCTUnwrap(associate(phones: [phone("p2", x: 0.1)])), body = skeleton()
    XCTAssertNotNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p2", association: association, skeleton: body, now: date))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p3", association: association, skeleton: body, now: date))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: "p2", association: association, skeleton: body, now: date.addingTimeInterval(0.101)))
    XCTAssertNil(RealtimeAssociationPolicy.hitSkeleton(targetPlayerID: nil, association: association, skeleton: body, now: date))
  }
  func testCameraPoseUsesMeasuredCaptureTimeAndRigidOrientation() throws {
    var matrix = ArenaRigidTransform.identityStorage; matrix[12] = 2; matrix[13] = 1; matrix[14] = -3
    let sample = DuelFramePose(columnMajor: matrix, capturedAt: date.addingTimeInterval(-0.05), frameTimestamp: 10)
    let pose = try XCTUnwrap(RealtimePoseBuilder.pose(sample, sequence: 7, matchTimeMs: 1000, now: date))
    XCTAssertEqual(pose.position, [2, 1, -3]); XCTAssertEqual(pose.orientation, [0, 0, 0, 1]); XCTAssertEqual(pose.sequence, 7)
    XCTAssertEqual(pose.capturedAtMs, 950, accuracy: 0.001)
    XCTAssertNil(RealtimePoseBuilder.pose(sample, sequence: 8, matchTimeMs: 1100, now: date.addingTimeInterval(0.1)))
  }
  func testDisconnectedBackgroundAndClockLossDisableAllGameplay() {
    let snapshot = RealtimeCombatTests.snapshot()
    XCTAssertTrue(eligibility(snapshot).fire)
    for result in [eligibility(snapshot, clock: false), eligibility(snapshot, scene: false), eligibility(snapshot, frame: false), eligibility(snapshot, pose: false), eligibility(snapshot, capacity: false)] {
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
  func testBeginNeedsHostAndCompleteAlignmentAndRoundClockExcludesCalibration() {
    var snapshot = RealtimeCombatTests.snapshot(); snapshot.phase = .calibrating
    XCTAssertTrue(eligibility(snapshot).begin)
    snapshot.players[1].frameReady = false; XCTAssertFalse(eligibility(snapshot).begin)
    snapshot.players[1].frameReady = true; snapshot.players[0].role = "player"; XCTAssertFalse(eligibility(snapshot).begin)
    XCTAssertNil(RealtimeActionEligibility.remainingRoundMs(snapshot: snapshot, now: 12_000))
    snapshot.roundStartedAtMs = 10_000
    XCTAssertEqual(RealtimeActionEligibility.remainingRoundMs(snapshot: snapshot, now: 12_000), 178_000)
    snapshot.players[0].role = "host"; snapshot.phase = .paused
    XCTAssertFalse(eligibility(snapshot).begin, "A started match resumes automatically when authoritative coverage returns")
  }

  private func eligibility(_ snapshot: CombatWire.Snapshot, clock: Bool = true, frame: Bool = true, scene: Bool = true, pose: Bool = true, capacity: Bool = true, localFire: Double? = nil) -> RealtimeActionEligibility {
    .evaluate(snapshot: snapshot, localPlayerID: "p1", clockReady: clock, frameReady: frame, sceneActive: scene, canSubmit: capacity, poseFresh: pose, localFireAtMs: localFire, matchTimeMs: 5000)
  }
  private func associate(phones: [CombatWire.PlayerPose], skeleton body: TargetingSkeleton? = nil, ready: Bool = true, confidence: Double = 0.9, roster: [CombatWire.Player]? = nil) -> RealtimeBodyAssociation? {
    RealtimeAssociationPolicy.associate(skeleton: body ?? skeleton(), observationConfidence: confidence, phonePoses: phones,
      players: roster ?? (phones.count == 1 ? Array(players().prefix(2)) : players()),
      localPlayerID: "p1", matchTimeMs: 1000, now: date, frameReady: ready)
  }
  private func phone(_ id: String, x: Double, at: Double = 1000) -> CombatWire.PlayerPose {
    .init(playerId: id, pose: .init(sequence: 1, capturedAtMs: at, position: [x, 1, 0], orientation: [0, 0, 0, 1], tracking: "normal"))
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
