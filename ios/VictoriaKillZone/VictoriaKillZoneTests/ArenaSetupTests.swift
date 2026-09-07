import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class ArenaSetupTests: XCTestCase {
  func testSavedCompletionWaitsForCameraTeardownAndContainsCapturedReference() async throws {
    let stop = ArenaSetupGate(), camera = ArenaSetupCamera(stopGate: nil)
    await camera.setStopGate(stop)
    let store = ArenaSetupStore(), setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    await setup.captureReference()
    setup.name = "  Living room  "
    let saving = Task {await setup.save()}
    try await until {await stop.entered}
    XCTAssertEqual(setup.phase, .stopping)
    XCTAssertNil(setup.completion)
    let names = await store.savedNames
    XCTAssertEqual(names, ["Living room"])
    await stop.release()
    await saving.value
    guard case .saved(let arena) = setup.completion else {return XCTFail("Missing saved completion")}
    let savedMap = try arena.map(epoch: 9)
    XCTAssertEqual(savedMap.epoch, 9)
    XCTAssertNotNil(savedMap.reference)
    XCTAssertEqual(savedMap.worldMapBytes, Data([7, 8, 9]))
    let lifecycle = await camera.lifecycle
    XCTAssertEqual(Array(lifecycle.suffix(3)), ["mapping-ended", "stop", "stopped"])
    XCTAssertFalse(setup.frame.permitsSpatialFire())
    await setup.stop()
    let stops = await camera.stops
    XCTAssertEqual(stops, 1, "The view disappearing after completion must not stop the next owner")
  }

  func testCancelWaitsForNonCooperativeCameraStartThenStopsBeforeCompleting() async throws {
    let gate = ArenaSetupGate(), camera = ArenaSetupCamera(startGate: nil)
    await camera.setStartGate(gate)
    let setup = ArenaSetupController(targeting: camera, store: ArenaSetupStore())
    let starting = Task {await setup.start()}
    try await until {await gate.entered}
    let cancelling = Task {await setup.cancel()}
    try await until {setup.phase == .stopping}
    XCTAssertNil(setup.completion)
    let stopsBeforeStart = await camera.stops
    XCTAssertEqual(stopsBeforeStart, 0)
    await gate.release()
    await cancelling.value
    await starting.value
    XCTAssertEqual(setup.completion, .cancelled)
    let running = await camera.running, mappings = await camera.mappings
    XCTAssertFalse(running)
    XCTAssertEqual(mappings, 0, "A late camera start cannot begin an invalidated scan")
  }

  func testBackgroundDuringReferenceCaptureRejectsLateCallbackAndRequiresRestart() async throws {
    let gate = ArenaSetupGate(), camera = ArenaSetupCamera(referenceGate: nil)
    await camera.setReferenceGate(gate)
    let store = ArenaSetupStore(), setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    let capturing = Task {await setup.captureReference()}
    try await until {await gate.entered}
    let backgrounding = Task {await setup.setSceneActive(false)}
    try await until {await camera.stops == 1}
    XCTAssertNil(setup.completion)
    await gate.release()
    await capturing.value
    await backgrounding.value
    XCTAssertEqual(setup.phase, .paused)
    XCTAssertEqual(setup.referenceState, .unavailable)
    XCTAssertNil(setup.referenceImageData)
    let writes = await store.savedNames
    XCTAssertTrue(writes.isEmpty)
    await setup.setSceneActive(true)
    XCTAssertEqual(setup.phase, .paused, "Returning to foreground does not restart the camera")
    await setup.restart()
    let starts = await camera.starts
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(setup.frame.stage, .mapping)
    XCTAssertFalse(setup.canSave)
    await setup.cancel()
  }

  func testCancelDuringMapCaptureCannotPersistItsLateResult() async throws {
    let gate = ArenaSetupGate(), camera = ArenaSetupCamera(mapGate: nil)
    await camera.setMapGate(gate)
    let store = ArenaSetupStore(), setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    await setup.captureReference()
    setup.name = "Garden"
    let saving = Task {await setup.save()}
    try await until {await gate.entered}
    let cancelling = Task {await setup.cancel()}
    try await until {await camera.stops == 1}
    XCTAssertNil(setup.completion)
    await gate.release()
    await cancelling.value
    await saving.value
    XCTAssertEqual(setup.completion, .cancelled)
    let calls = await store.saveCalls
    XCTAssertEqual(calls, 0)
  }

  func testBackgroundDuringStorageCancelsPublicationAndNavigation() async throws {
    let gate = ArenaSetupGate(), camera = ArenaSetupCamera()
    let store = ArenaSetupStore(saveGate: gate), setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    await setup.captureReference()
    setup.name = "Garden"
    let saving = Task {await setup.save()}
    try await until {await gate.entered}
    let backgrounding = Task {await setup.setSceneActive(false)}
    try await until {await camera.stops == 1}
    XCTAssertNil(setup.completion)
    await gate.release()
    await backgrounding.value
    await saving.value
    let writes = await store.savedNames
    XCTAssertTrue(writes.isEmpty)
    XCTAssertEqual(setup.phase, .paused)
    XCTAssertNil(setup.completion)
    XCTAssertFalse(setup.canSave)
    await setup.cancel()
  }

  func testStorageFailureRetainsReferenceForRetryAndReportsRecovery() async throws {
    let camera = ArenaSetupCamera(), store = ArenaSetupStore(failure: .libraryFull)
    let setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    await setup.captureReference()
    setup.name = "Living room"
    await setup.save()
    XCTAssertEqual(setup.phase, .scanning)
    XCTAssertTrue(setup.canSave)
    XCTAssertTrue(setup.message?.contains("12 saved arenas") == true)
    XCTAssertNil(setup.completion)
    await store.setFailure(nil)
    await setup.save()
    guard case .saved = setup.completion else {return XCTFail("Retry did not complete")}
    let calls = await store.saveCalls
    XCTAssertEqual(calls, 2)
  }

  func testSaveRequiresCapturedReferenceAndValidNameWithoutGrantingAlignment() async throws {
    let camera = ArenaSetupCamera(), store = ArenaSetupStore()
    let setup = ArenaSetupController(targeting: camera, store: store)
    try await prepare(setup, camera: camera)
    setup.name = "Living room"
    await setup.save()
    XCTAssertFalse(setup.canSave)
    await setup.captureReference()
    setup.name = " \n "
    await setup.save()
    setup.name = String(repeating: "a", count: 61)
    await setup.save()
    let calls = await store.saveCalls
    XCTAssertEqual(calls, 0)
    setup.name = "Garden"
    XCTAssertTrue(setup.canSave)
    XCTAssertFalse(setup.frame.permitsSpatialFire())
    await setup.cancel()
  }

  func testOverlappingExitsShareTeardownBeforeAnExplicitRestart() async throws {
    let gate = ArenaSetupGate(), camera = ArenaSetupCamera()
    await camera.setStopGate(gate)
    let setup = ArenaSetupController(targeting: camera, store: ArenaSetupStore())
    try await prepare(setup, camera: camera)
    let stopping = Task {await setup.stop()}
    try await until {await gate.entered}
    let backgrounding = Task {await setup.setSceneActive(false)}
    // Ensure the background exit is waiting on the already pending camera stop.
    for _ in 0..<10 {await Task.yield()}
    let stops = await camera.stops
    XCTAssertEqual(stops, 1)
    await gate.release()
    await backgrounding.value
    XCTAssertEqual(setup.phase, .paused)
    await setup.setSceneActive(true)
    await setup.restart()
    await stopping.value
    XCTAssertEqual(setup.phase, .scanning)
    let running = await camera.running
    XCTAssertTrue(running)
    await setup.cancel()
    XCTAssertEqual(setup.completion, .cancelled)
    let finalRunning = await camera.running
    XCTAssertFalse(finalRunning)
  }

  private func prepare(_ setup: ArenaSetupController, camera: ArenaSetupCamera) async throws {
    await setup.start()
    XCTAssertEqual(setup.phase, .scanning)
    camera.emitMapped()
    try await until {setup.frame.stage == .mapReady}
  }

  private func until(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await predicate()), Date() < deadline {try await Task.sleep(for: .milliseconds(5))}
    let satisfied = await predicate()
    XCTAssertTrue(satisfied, "Expected lifecycle transition within two seconds")
  }
}

/// Deliberately ignores task cancellation, like camera permission and callback APIs.
private actor ArenaSetupGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var entered = false
  func wait() async {
    entered = true
    if released {return}
    await withCheckedContinuation {continuation = $0}
  }
  func release() {released = true; continuation?.resume(); continuation = nil}
}

private actor ArenaSetupCamera: TargetingSession, DuelFrameSessionDriving {
  nonisolated let availability = TargetingAvailability.available
  nonisolated let currentSnapshot = TargetingSnapshot.unavailable()
  nonisolated let observations = DuelFrameObservationHub()
  private var startGate: ArenaSetupGate?, stopGate: ArenaSetupGate?
  private var referenceGate: ArenaSetupGate?, mapGate: ArenaSetupGate?
  private(set) var starts = 0, stops = 0, mappings = 0
  private(set) var running = false
  private(set) var lifecycle: [String] = []

  init(startGate: ArenaSetupGate? = nil, stopGate: ArenaSetupGate? = nil,
    referenceGate: ArenaSetupGate? = nil, mapGate: ArenaSetupGate? = nil) {
    self.startGate = startGate; self.stopGate = stopGate
    self.referenceGate = referenceGate; self.mapGate = mapGate
  }
  func setStartGate(_ gate: ArenaSetupGate) {startGate = gate}
  func setStopGate(_ gate: ArenaSetupGate) {stopGate = gate}
  func setReferenceGate(_ gate: ArenaSetupGate) {referenceGate = gate}
  func setMapGate(_ gate: ArenaSetupGate) {mapGate = gate}
  nonisolated func snapshots() -> AsyncStream<TargetingSnapshot> {AsyncStream {$0.finish()}}
  nonisolated func duelFrameObservations() -> AsyncStream<DuelFrameObservation> {observations.stream()}
  nonisolated func emitMapped() {
    observations.yield(.init(epoch: 1, frameID: nil, phase: .mapping, tracking: .normal,
      isMapped: true, pose: nil, observedAt: Date(), failure: nil))
  }
  func start() async throws {
    starts += 1; lifecycle.append("start")
    await startGate?.wait()
    running = true; lifecycle.append("started")
  }
  func stop() async {
    stops += 1; lifecycle.append("stop")
    await stopGate?.wait()
    running = false; lifecycle.append("stopped")
  }
  func beginFrameMapping(epoch: UInt16) async throws {mappings += 1; lifecycle.append("mapping")}
  func endFrameMapping() async {lifecycle.append("mapping-ended")}
  func captureFrameMap(epoch: UInt16) async throws -> Data {
    await mapGate?.wait()
    return Data([7, 8, 9])
  }
  func captureFrameReference(epoch: UInt16) async throws -> DuelFrameReference {
    await referenceGate?.wait()
    return try .init(imageData: Data([1, 2, 3]), widthMeters: 1, heightMeters: 0.6,
      mapFromImage: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      sampleCount: 3, maximumCornerDeviationMeters: 0)
  }
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws {
    throw DuelFrameFailure.unsupported
  }
}

private actor ArenaSetupStore: SavedArenaStoring {
  private let saveGate: ArenaSetupGate?
  private var failure: SavedArenaFailure?
  private(set) var saveCalls = 0
  private(set) var savedNames: [String] = []
  init(saveGate: ArenaSetupGate? = nil, failure: SavedArenaFailure? = nil) {
    self.saveGate = saveGate; self.failure = failure
  }
  func setFailure(_ failure: SavedArenaFailure?) {self.failure = failure}
  func list() async throws -> [SavedArenaSummary] {[]}
  func save(name: String, bytes: Data) async throws -> SavedArenaBundle {
    saveCalls += 1
    await saveGate?.wait()
    // Mirrors the storage contract's cancellation check before atomic publication.
    try Task.checkCancellation()
    if let failure {throw failure}
    let map = try DuelFrameMap(epoch: 1, bytes: bytes)
    savedNames.append(name)
    return .init(summary: .init(id: UUID(), name: name, createdAt: Date(),
      frameID: map.frameID, byteCount: bytes.count), bytes: bytes)
  }
  func load(id: UUID) async throws -> SavedArenaBundle {throw SavedArenaFailure.notFound}
  func delete(id: UUID) async throws {}
}
