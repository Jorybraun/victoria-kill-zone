import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class SavedArenaMatchTests: XCTestCase {
  func testHostSharesSavedBytesUnderCurrentEpochWithoutRestoringReadiness() async throws {
    let saved = try Self.arena()
    let camera = SavedMatchCamera(), maps = SavedMatchMaps()
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: saved, maps: maps, epoch: 7)
    coordinator.configure(epoch: 7, isHost: true)
    try await until { coordinator.state == .installed }
    let uploaded = await maps.uploads
    XCTAssertEqual(uploaded.count, 1)
    XCTAssertEqual(uploaded.first?.epoch, 7)
    XCTAssertEqual(uploaded.first?.bytes, saved.bytes)
    XCTAssertEqual(uploaded.first?.frameID, saved.summary.frameID)
    XCTAssertEqual(provider.snapshot.stage, .relocalizingWorld)
    XCTAssertNil(provider.snapshot.residual)
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    await coordinator.stop()
  }

  func testSameEpochRetryUsesIdenticalMapButRequiresFreshAlignment() async throws {
    let saved = try Self.arena(), camera = SavedMatchCamera(), maps = SavedMatchMaps()
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: saved, maps: maps)
    coordinator.configure(epoch: 1, isHost: true)
    try await until { coordinator.state == .installed }
    await coordinator.stop()
    coordinator.configure(epoch: 1, isHost: true)
    try await until { coordinator.state == .installed }
    let uploads = await maps.uploads, installs = await camera.installed
    XCTAssertEqual(uploads.count, 1)
    XCTAssertEqual(installs.count, 2)
    XCTAssertEqual(installs[0], installs[1])
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    await coordinator.stop()
  }

  func testConflictingPublishedArenaIsNotOverwrittenOrInstalled() async throws {
    let saved = try Self.arena(), other = try Self.arena(world: Data([7, 8, 9]))
    let camera = SavedMatchCamera(), maps = SavedMatchMaps(published: try other.map(epoch: 1))
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: saved, maps: maps)
    coordinator.configure(epoch: 1, isHost: true)
    try await until { if case .failed = coordinator.state { true } else { false } }
    let uploads = await maps.uploads, installs = await camera.installed
    XCTAssertTrue(uploads.isEmpty)
    XCTAssertTrue(installs.isEmpty)
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    await coordinator.stop()
  }

  func testTransientDownloadErrorRetriesBeforeHostScans() async throws {
    let camera = SavedMatchCamera(), maps = SavedMatchMaps(failures: [URLError(.networkConnectionLost)])
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: nil, maps: maps)
    coordinator.configure(epoch: 1, isHost: true)
    try await until(timeout: 5) { coordinator.state == .mapping }
    let uploads = await maps.uploads
    XCTAssertTrue(uploads.isEmpty)
    await coordinator.stop()
  }

  func testRepeatedTransferErrorsFailAfterRetries() async throws {
    let camera = SavedMatchCamera()
    let maps = SavedMatchMaps(failures: [URLError(.timedOut), URLError(.timedOut), URLError(.timedOut)])
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: nil, maps: maps)
    coordinator.configure(epoch: 1, isHost: true)
    try await until(timeout: 8) { if case .failed = coordinator.state { true } else { false } }
    guard case .failed(let message) = coordinator.state else { return XCTFail("Expected failed map state") }
    XCTAssertTrue(message.contains("could not be loaded"))
    let uploads = await maps.uploads
    XCTAssertTrue(uploads.isEmpty)
    await coordinator.stop()
  }

  func testGuestWaitsForAuthenticatedMapAndNeverUploadsSelection() async throws {
    let camera = SavedMatchCamera(), maps = SavedMatchMaps()
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: try Self.arena(), maps: maps)
    coordinator.configure(epoch: 1, isHost: false)
    try await until { coordinator.state == .waitingForHost }
    let uploads = await maps.uploads
    XCTAssertTrue(uploads.isEmpty)
    XCTAssertFalse(provider.snapshot.permitsSpatialFire())
    await coordinator.stop()
  }

  func testMatchingPublishedBytesNeedNoUpload() async throws {
    let saved = try Self.arena(), camera = SavedMatchCamera()
    let maps = SavedMatchMaps(published: try saved.map(epoch: 1))
    let provider = DuelFrameProvider(targeting: camera)
    let coordinator = makeCoordinator(frame: provider, saved: saved, maps: maps)
    coordinator.configure(epoch: 1, isHost: true)
    try await until { coordinator.state == .installed }
    let uploads = await maps.uploads
    XCTAssertTrue(uploads.isEmpty)
    XCTAssertEqual(provider.snapshot.stage, .relocalizingWorld)
    await coordinator.stop()
  }

  private func makeCoordinator(frame: DuelFrameProvider, saved: SavedArenaBundle?,
                               maps: SavedMatchMaps, epoch: Int = 1) -> RealtimeMapCoordinator {
    let client = SavedMatchClient(epoch: epoch)
    return RealtimeMapCoordinator(session: .init(matchId: "match", code: "ABC123", playerId: "host",
      sessionSecret: "local-test-value"), client: client, combat: RealtimeCombatSession(gameClient: client),
      frame: frame, savedArena: saved, maps: maps)
  }

  static func arena(world: Data = Data([1, 2, 3])) throws -> SavedArenaBundle {
    let reference = try DuelFrameReference(imageData: Data([1, 2, 3]), widthMeters: 1, heightMeters: 0.6,
      mapFromImage: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], sampleCount: 3, maximumCornerDeviationMeters: 0.005)
    let bytes = try DuelFrameCalibrationBundle.encode(worldMap: world, reference: reference)
    let map = try DuelFrameMap(epoch: 1, bytes: bytes)
    return SavedArenaBundle(summary: .init(id: UUID(), name: "Living room", createdAt: Date(),
      frameID: map.frameID, byteCount: bytes.count), bytes: bytes)
  }

  private func until(timeout: TimeInterval = 3, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate())
  }
}

private actor SavedMatchCamera: DuelFrameSessionDriving {
  private(set) var installed: [DuelFrameMap] = []
  nonisolated func duelFrameObservations() -> AsyncStream<DuelFrameObservation> { AsyncStream { $0.finish() } }
  func beginFrameMapping(epoch: UInt16) async throws {}
  func captureFrameMap(epoch: UInt16) async throws -> Data { throw DuelFrameFailure.unsupported }
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws { installed.append(map) }
  func endFrameMapping() async {}
}

private actor SavedMatchMaps: CombatMapTransferring {
  private let published: DuelFrameMap?
  private var downloadFailures: [Error]
  private(set) var uploads: [DuelFrameMap] = []
  init(published: DuelFrameMap? = nil, failures: [Error] = []) { self.published = published; self.downloadFailures = failures }
  func upload(_ map: DuelFrameMap, ticket: CombatAccessTicket) async throws { uploads.append(map) }
  func download(epoch: UInt16, ticket: CombatAccessTicket) async throws -> DuelFrameMap {
    if !downloadFailures.isEmpty { throw downloadFailures.removeFirst() }
    guard let published else { throw CombatMapError.unavailable }
    return published
  }
}

private struct SavedMatchClient: GameSessionClient {
  let availability = GameSessionAvailability.available
  let epoch: Int
  func combatTicket(session: PlayerSession) async throws -> CombatAccessTicket {
    .init(endpoint: URL(string: "https://example.test/v1/matches/match/connect")!, token: "local-test-value",
      expiresAt: Date().addingTimeInterval(60), authorityEpoch: 1, frameEpoch: epoch)
  }
  func createDuel(_ request: CreateDuelRequest) async throws -> PlayerSession { throw GameSessionClientError.notConfigured }
  func joinDuel(_ request: JoinDuelRequest) async throws -> PlayerSession { throw GameSessionClientError.notConfigured }
  func setReady(session: PlayerSession, isReady: Bool) async throws {}
  func startDuel(session: PlayerSession) async throws {}
  func debugFire(session: PlayerSession, clientShotId: String) async throws -> DebugFireResult { throw GameSessionClientError.notConfigured }
  func snapshots(for session: PlayerSession) -> AsyncThrowingStream<MatchSnapshot, Error> { AsyncThrowingStream { $0.finish() } }
  func connectionStates() -> AsyncStream<GameSessionConnectionState> { AsyncStream { $0.finish() } }
}
