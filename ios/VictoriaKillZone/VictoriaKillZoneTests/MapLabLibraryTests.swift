import Foundation
import XCTest
@testable import VictoriaKillZone

@MainActor
final class MapLabLibraryTests: XCTestCase {
  func testSavedScanSurvivesFreshLibraryAndDiskStoreThenLoadsIntoRecognition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("map-lab-reopen-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let camera = MapLabTestDriver()
    // The store writes real files; only AR map encoding/recognition uses fixture data.
    let original = MapLabLibrary(store: LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }), makeDriver: { camera })
    await original.refresh(); original.newScan()
    let capture = try XCTUnwrap(original.activeSession)
    await capture.start(); capture.name = "Living room"
    camera.emit(.scanning(feedback: .ready, canSave: true))
    await capture.save(); await original.sessionFinished(capture.id)
    XCTAssertEqual(original.savedScanName, "Living room")
    let saved = try XCTUnwrap(original.scans.first)
    await original.close()

    let recognitionCamera = MapLabTestDriver()
    let reopened = MapLabLibrary(store: LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }),
      makeDriver: { recognitionCamera })
    await reopened.refresh()
    XCTAssertEqual(reopened.scans, [saved]); XCTAssertNil(reopened.savedScanName)
    await reopened.testScan(saved.id)
    let recognition = try XCTUnwrap(reopened.activeSession)
    await recognition.start()
    XCTAssertEqual(recognitionCamera.recognitionBytes, [camera.bytes])
    XCTAssertEqual(recognition.state, .recognizing, "Loading saved bytes alone cannot claim that the room was recognized")
    await reopened.close()
  }

  func testCancelledScanNeverShowsSaveConfirmation() async throws {
    let library = MapLabLibrary(store: MapLabTestStore(), makeDriver: { MapLabTestDriver() })
    await library.refresh(); library.newScan()
    let session = try XCTUnwrap(library.activeSession)
    await session.start(); await session.close(); await library.sessionFinished(session.id)
    XCTAssertNil(library.savedScanName); XCTAssertTrue(library.scans.isEmpty)
    await library.close()
  }

  func testOfflineNewScanNeedsOnlyLocalStoreAndDriverThenRefreshesAfterSave() async throws {
    let camera = MapLabTestDriver(), store = MapLabTestStore()
    let library = MapLabLibrary(store: store, makeDriver: { camera })
    await library.refresh(); XCTAssertTrue(library.scans.isEmpty)
    library.newScan()
    let session = try XCTUnwrap(library.activeSession)
    await session.start(); session.name = "Study"
    camera.emit(.scanning(feedback: .ready, canSave: true))
    await session.save(); await library.sessionFinished(session.id)
    XCTAssertNil(library.activeSession); XCTAssertEqual(library.scans.map(\.name), ["Study"])
    XCTAssertFalse(camera.running)
    await library.close()
  }

  func testInvalidLoadDoesNotConstructCameraAndRemainsDeletable() async throws {
    let valid = mapLabTestBundle(), invalid = MapLabBundle(summary: valid.summary, bytes: Data([7]))
    let store = MapLabTestStore(bundles: [invalid])
    var madeCameras = 0
    let library = MapLabLibrary(store: store, makeDriver: { madeCameras += 1; return MapLabTestDriver() })
    await library.refresh(); await library.testScan(valid.summary.id)
    XCTAssertEqual(madeCameras, 0); XCTAssertNil(library.activeSession)
    XCTAssertEqual(library.message, MapLabFailure.invalidMap.errorDescription)
    await library.delete(valid.summary.id)
    XCTAssertTrue(library.scans.isEmpty)
    await library.close()
  }

  func testCloseWhileLoadingCannotOpenLateRecognition() async throws {
    let bundle = mapLabTestBundle(), gate = MapLabTestGate()
    let store = MapLabTestStore(loadGate: gate, bundles: [bundle])
    var madeCameras = 0
    let library = MapLabLibrary(store: store, makeDriver: { madeCameras += 1; return MapLabTestDriver() })
    await library.refresh()
    let opening = Task { await library.testScan(bundle.summary.id) }
    try await until { await gate.entered }
    await library.close(); await gate.release(); await opening.value
    XCTAssertEqual(madeCameras, 0); XCTAssertNil(library.activeSession)
    library.newScan(); XCTAssertNil(library.activeSession)
  }

  func testLibraryCloseAwaitsCameraTeardownBeforeReturningToRoot() async throws {
    let camera = MapLabTestDriver(), gate = MapLabTestGate()
    camera.stopGate = gate
    let library = MapLabLibrary(store: MapLabTestStore(), makeDriver: { camera })
    library.newScan()
    let session = try XCTUnwrap(library.activeSession)
    await session.start()
    var returnedToRoot = false
    let closing = Task { await library.close(); returnedToRoot = true }
    try await until { await gate.entered }
    XCTAssertFalse(returnedToRoot); XCTAssertNotNil(library.activeSession)
    await gate.release(); await closing.value
    XCTAssertTrue(returnedToRoot); XCTAssertNil(library.activeSession); XCTAssertFalse(camera.running)
  }

  func testFullLibraryOffersDeletionBeforeAnotherCapture() async {
    let bundles = (0..<12).map { mapLabTestBundle(name: "Room \($0)") }
    var madeCameras = 0
    let library = MapLabLibrary(store: MapLabTestStore(bundles: bundles), makeDriver: { madeCameras += 1; return MapLabTestDriver() })
    await library.refresh(); library.newScan()
    XCTAssertEqual(madeCameras, 0); XCTAssertEqual(library.message, MapLabFailure.libraryFull.errorDescription)
    await library.delete(bundles[0].summary.id); library.newScan()
    XCTAssertEqual(madeCameras, 1)
    await library.close()
  }

  private func until(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { XCTFail("Expected controlled suspension was not reached"); throw MapLabFailure.timedOut }
      await Task.yield()
    }
  }
}
