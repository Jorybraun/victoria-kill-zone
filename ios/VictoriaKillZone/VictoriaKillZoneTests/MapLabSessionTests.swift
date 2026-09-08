import Combine
import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class MapLabSessionTests: XCTestCase {
  func testInactivePermissionPromptDoesNotAbandonCameraStartup() async throws {
    let gate = MapLabTestGate(), camera = MapLabTestDriver()
    camera.startGate = gate
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: MapLabTestStore())
    // A view can first appear during the system's inactive transition.
    await controller.setScenePhase(.inactive)
    let starting = Task { await controller.start() }
    try await until { await gate.entered }
    await controller.setScenePhase(.inactive)
    XCTAssertEqual(controller.phase, .starting)
    XCTAssertEqual(camera.stops, 0)
    await controller.setScenePhase(.active)
    await gate.release(); await starting.value
    XCTAssertEqual(controller.phase, .live)
    XCTAssertTrue(camera.running); XCTAssertNil(controller.message)
    await controller.close()
  }

  func testInactiveOverlayDuringCapturePreservesSaveButBackgroundStillCancels() async throws {
    for background in [false, true] {
      let gate = MapLabTestGate(), camera = MapLabTestDriver(), store = MapLabTestStore()
      camera.captureGate = gate
      let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
      await ready(controller, camera)
      let saving = Task { await controller.save() }
      try await until { await gate.entered }
      await controller.setScenePhase(.inactive)
      XCTAssertEqual(controller.phase, .saving)
      XCTAssertEqual(camera.stops, 0)
      let transition = Task { await controller.setScenePhase(background ? .background : .active) }
      if background { try await until { camera.stops == 1 } }
      await gate.release(); await saving.value; await transition.value
      let names = await store.savedNames
      XCTAssertEqual(names, background ? [] : ["Room"])
      if background {
        XCTAssertEqual(controller.phase, .paused); XCTAssertNil(controller.completion)
      } else {
        guard case .saved = controller.completion else { return XCTFail("Inactive transition discarded the saved scan") }
      }
      await controller.close()
    }
  }

  func testCaptureSaveReturnsOnlyAfterCameraHasStopped() async throws {
    let camera = MapLabTestDriver(), store = MapLabTestStore()
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
    await controller.start()
    camera.emit(.scanning(feedback: .ready, canSave: true)); controller.name = "  Kitchen  "
    let stop = MapLabTestGate(); camera.stopGate = stop
    let saving = Task { await controller.save() }
    try await until { await stop.entered }
    XCTAssertNil(controller.completion)
    XCTAssertEqual(controller.phase, .stopping)
    await stop.release(); await saving.value
    guard case .saved(let bundle) = controller.completion else { return XCTFail("Expected saved scan") }
    XCTAssertEqual(bundle.bytes, camera.bytes)
    XCTAssertEqual(bundle.summary.name, "Kitchen")
    XCTAssertFalse(camera.running)
    await controller.stop()
    XCTAssertEqual(camera.stops, 1, "Disappearance cannot stop a subsequent camera owner")
  }

  func testCloseAwaitsNonCooperativeCameraStartBeforeFinalStop() async throws {
    let start = MapLabTestGate(), camera = MapLabTestDriver()
    camera.startGate = start
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: MapLabTestStore())
    let starting = Task { await controller.start() }
    try await until { await start.entered }
    let closing = Task { await controller.close() }
    try await until { controller.phase == .stopping }
    XCTAssertNil(controller.completion); XCTAssertEqual(camera.stops, 0)
    await start.release(); await starting.value; await closing.value
    XCTAssertEqual(controller.completion, .closed)
    XCTAssertEqual(camera.stops, 1); XCTAssertFalse(camera.running)
    XCTAssertEqual(controller.state, .idle)
  }

  func testBackgroundDuringCaptureDropsLateResultAndRequiresExplicitRetry() async throws {
    let capture = MapLabTestGate(), camera = MapLabTestDriver(), store = MapLabTestStore()
    camera.captureGate = capture
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
    await ready(controller, camera)
    let saving = Task { await controller.save() }
    try await until { await capture.entered }
    let background = Task { await controller.setSceneActive(false) }
    try await until { camera.stops == 1 }
    XCTAssertNil(controller.completion); XCTAssertFalse(controller.canSave)
    await capture.release(); await saving.value; await background.value
    let writes = await store.savedNames
    XCTAssertTrue(writes.isEmpty); XCTAssertEqual(controller.phase, .paused)
    await controller.setSceneActive(true)
    XCTAssertEqual(camera.starts, 1)
    XCTAssertEqual(controller.phase, .paused)
    camera.captureGate = nil
    await controller.restart()
    XCTAssertEqual(camera.starts, 2)
    XCTAssertEqual(controller.state, .scanning(feedback: .mapping, canSave: false))
    await controller.close()
  }

  func testBackgroundDuringSavePreventsPublicationAndLateCommittedSaveCannotNavigate() async throws {
    for commitBeforeWaiting in [false, true] {
      let gate = MapLabTestGate(), camera = MapLabTestDriver()
      let store = MapLabTestStore(saveGate: gate, commitBeforeWaiting: commitBeforeWaiting)
      let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
      await ready(controller, camera)
      let saving = Task { await controller.save() }
      try await until { await gate.entered }
      let background = Task { await controller.setSceneActive(false) }
      try await until { camera.stops == 1 }
      await gate.release(); await saving.value; await background.value
      let writes = await store.savedNames
      XCTAssertEqual(writes.count, commitBeforeWaiting ? 1 : 0)
      XCTAssertNil(controller.completion)
      XCTAssertEqual(controller.phase, .paused)
      await controller.close()
    }
  }

  func testInterruptedCaptureCannotSaveOrReviveFromLateSuccess() async throws {
    let gate = MapLabTestGate(), camera = MapLabTestDriver(), store = MapLabTestStore()
    camera.captureGate = gate
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
    await ready(controller, camera)
    let saving = Task { await controller.save() }
    try await until { await gate.entered }
    camera.emit(.interrupted)
    XCTAssertEqual(controller.phase, .paused)
    camera.emit(.scanning(feedback: .ready, canSave: true))
    await gate.release(); await saving.value
    XCTAssertEqual(controller.state, .interrupted)
    XCTAssertEqual(controller.phase, .paused); XCTAssertNil(controller.completion)
    let writes = await store.savedNames; XCTAssertTrue(writes.isEmpty)
    await controller.close()
  }

  func testRecognitionStartsFromSavedBytesAndNeverEnablesSaving() async throws {
    let bundle = mapLabTestBundle(), camera = MapLabTestDriver()
    let controller = MapLabSessionController(mode: .recognition(bundle), driver: camera, store: MapLabTestStore())
    await controller.start()
    XCTAssertEqual(camera.recognitionBytes, [bundle.bytes])
    XCTAssertEqual(controller.state, .recognizing)
    camera.emit(.recognized)
    XCTAssertEqual(controller.state, .recognized); XCTAssertFalse(controller.canSave)
    await controller.setSceneActive(false)
    XCTAssertEqual(controller.state, .idle)
    camera.emit(.recognized)
    XCTAssertEqual(controller.state, .idle, "Paused screens reject late recognition")
    await controller.setSceneActive(true); await controller.restart()
    XCTAssertEqual(controller.state, .recognizing)
    await controller.close()
  }

  func testInvalidSavedBundleCannotStartCameraAndTimeoutCanRetry() async {
    let valid = mapLabTestBundle(), camera = MapLabTestDriver()
    let invalid = MapLabBundle(summary: valid.summary, bytes: Data([9]))
    let controller = MapLabSessionController(mode: .recognition(invalid), driver: camera, store: MapLabTestStore())
    await controller.start()
    XCTAssertEqual(camera.starts, 0); XCTAssertEqual(controller.phase, .paused)
    XCTAssertEqual(controller.message, MapLabFailure.invalidMap.errorDescription)
    await controller.close()
    let capture = MapLabSessionController(mode: .capture, driver: camera, store: MapLabTestStore())
    await capture.start(); camera.emit(.failed(.timedOut))
    XCTAssertEqual(capture.phase, .paused)
    XCTAssertTrue(capture.message?.contains("usable scan") == true)
    await capture.restart()
    XCTAssertEqual(capture.phase, .live); XCTAssertNil(capture.message)
    await capture.close()
  }

  func testConcurrentBackgroundAndCloseShareStopAndPublishOnlyLatestExit() async throws {
    let gate = MapLabTestGate(), camera = MapLabTestDriver()
    camera.stopGate = gate
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: MapLabTestStore())
    await controller.start()
    var stopTransitions = 0
    let observation = controller.$phase.sink { if $0 == .stopping { stopTransitions += 1 } }
    defer { observation.cancel() }
    let background = Task { await controller.setSceneActive(false) }
    try await until { await gate.entered }
    let closing = Task { await controller.close() }
    try await until { stopTransitions == 2 }
    XCTAssertNil(controller.completion)
    await gate.release(); await background.value; await closing.value
    XCTAssertEqual(camera.stops, 1); XCTAssertEqual(controller.completion, .closed)
    XCTAssertEqual(controller.phase, .finished)
  }

  func testDriverFailureDuringStartCanCloseOrRetryWithoutRevivingOldCallbacks() async {
    let camera = MapLabTestDriver()
    camera.startFailure = .cameraDenied
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: MapLabTestStore())
    await controller.start()
    XCTAssertEqual(controller.phase, .paused)
    XCTAssertEqual(controller.message, MapLabFailure.cameraDenied.errorDescription)
    camera.emit(.scanning(feedback: .ready, canSave: true))
    XCTAssertEqual(controller.state, .failed(.cameraDenied))
    camera.startFailure = nil
    await controller.restart()
    XCTAssertEqual(camera.starts, 2); XCTAssertEqual(camera.stops, 1)
    XCTAssertEqual(controller.phase, .live)
    await controller.close()
    camera.emit(.recognized)
    XCTAssertEqual(controller.phase, .finished); XCTAssertEqual(controller.state, .idle)
    XCTAssertEqual(controller.completion, .closed)
    await controller.restart()
    XCTAssertEqual(camera.starts, 2)
  }

  func testDriverFailureDuringCaptureFencesPendingArchiveAndCanClose() async throws {
    let gate = MapLabTestGate(), camera = MapLabTestDriver(), store = MapLabTestStore()
    camera.captureGate = gate
    let controller = MapLabSessionController(mode: .capture, driver: camera, store: store)
    await ready(controller, camera)
    let saving = Task { await controller.save() }
    try await until { await gate.entered }
    camera.emit(.failed(.timedOut))
    XCTAssertEqual(controller.phase, .paused)
    let closing = Task { await controller.close() }
    try await until { camera.stops == 1 }
    await gate.release(); await saving.value; await closing.value
    let writes = await store.savedNames
    XCTAssertTrue(writes.isEmpty); XCTAssertEqual(controller.completion, .closed)
    camera.emit(.scanning(feedback: .ready, canSave: true))
    XCTAssertEqual(controller.state, .idle); XCTAssertFalse(controller.canSave)
  }

  private func ready(_ controller: MapLabSessionController, _ camera: MapLabTestDriver) async {
    await controller.start(); camera.emit(.scanning(feedback: .ready, canSave: true)); controller.name = "Room"
  }
  private func until(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { XCTFail("Expected controlled suspension was not reached"); throw MapLabFailure.timedOut }
      await Task.yield()
    }
  }
}

actor MapLabTestGate {
  private(set) var entered = false
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

@MainActor
final class MapLabTestDriver: MapLabDriving {
  var state: MapLabSessionState = .idle
  var onStateChange: ((MapLabSessionState) -> Void)?
  var startGate: MapLabTestGate?
  var captureGate: MapLabTestGate?
  var stopGate: MapLabTestGate?
  var startFailure: MapLabFailure?
  var starts = 0, stops = 0
  var running = false
  var recognitionBytes: [Data] = []
  let bytes = Data([1, 2, 3])
  func startCapture() async throws {
    starts += 1
    await startGate?.wait()
    if let startFailure { emit(.failed(startFailure)); throw startFailure }
    running = true; emit(.scanning(feedback: .mapping, canSave: false))
  }
  func startRecognition(bytes: Data) async throws {
    starts += 1; recognitionBytes.append(bytes)
    await startGate?.wait()
    running = true; emit(.recognizing)
  }
  func capture() async throws -> Data { await captureGate?.wait(); return bytes }
  func stop() async { stops += 1; await stopGate?.wait(); running = false; emit(.idle) }
  func emit(_ next: MapLabSessionState) { state = next; onStateChange?(next) }
}

actor MapLabTestStore: MapLabStoring {
  private let saveGate: MapLabTestGate?
  private let commitBeforeWaiting: Bool
  private let loadGate: MapLabTestGate?
  private var bundles: [UUID: MapLabBundle]
  private(set) var savedNames: [String] = []
  init(saveGate: MapLabTestGate? = nil, commitBeforeWaiting: Bool = false,
    loadGate: MapLabTestGate? = nil, bundles: [MapLabBundle] = []) {
    self.saveGate = saveGate; self.commitBeforeWaiting = commitBeforeWaiting; self.loadGate = loadGate
    self.bundles = Dictionary(uniqueKeysWithValues: bundles.map { ($0.summary.id, $0) })
  }
  func list() async throws -> [MapLabSummary] { bundles.values.map(\.summary) }
  func load(id: UUID) async throws -> MapLabBundle {
    await loadGate?.wait()
    guard let result = bundles[id] else { throw MapLabFailure.notFound }
    return result
  }
  func save(name: String, bytes: Data) async throws -> MapLabBundle {
    let bundle = mapLabTestBundle(name: name, bytes: bytes)
    if commitBeforeWaiting { bundles[bundle.summary.id] = bundle; savedNames.append(name) }
    await saveGate?.wait()
    if !commitBeforeWaiting {
      try Task.checkCancellation()
      bundles[bundle.summary.id] = bundle; savedNames.append(name)
    }
    return bundle
  }
  func delete(id: UUID) async throws { bundles[id] = nil }
}

func mapLabTestBundle(name: String = "Room", bytes: Data = Data([1, 2, 3])) -> MapLabBundle {
  MapLabBundle(summary: MapLabSummary(id: UUID(), name: name, createdAt: Date(),
    byteCount: bytes.count, checksum: MapLabBundle.checksum(bytes)), bytes: bytes)
}
