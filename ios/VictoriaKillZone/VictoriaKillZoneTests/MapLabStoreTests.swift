import Foundation
import XCTest
@testable import VictoriaKillZone

final class MapLabStoreTests: XCTestCase {
  func testRawMapRoundTripAfterRestartAndDeletePreservesOtherScan() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([10, 20, 30])
    let first = try await fixtureStore(root).save(name: "  Living room \n", bytes: bytes)
    let second = try await fixtureStore(root).save(name: "Living room", bytes: bytes)
    XCTAssertEqual(first.summary.name, "Living room")
    XCTAssertNotEqual(first.summary.id, second.summary.id)
    XCTAssertEqual(first.summary.byteCount, bytes.count)
    XCTAssertEqual(first.summary.checksum, MapLabBundle.checksum(bytes))
    XCTAssertTrue(first.summary.isValid)
    XCTAssertEqual(try Data(contentsOf: payloadURL(root, first.summary.id)), bytes,
      "MapLab stores the raw archive without a reference calibration envelope")
    let restarted = fixtureStore(root)
    let listed = try await restarted.list()
    XCTAssertEqual(Set(listed.map(\.id)), [first.summary.id, second.summary.id])
    XCTAssertEqual(listed.map(\.createdAt), listed.map(\.createdAt).sorted(by: >))
    let loaded = try await restarted.load(id: first.summary.id)
    XCTAssertEqual(loaded, first)
    try await restarted.delete(id: first.summary.id)
    try await restarted.delete(id: first.summary.id)
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [second.summary])
    await assertFailure(.notFound) { try await restarted.load(id: first.summary.id) }

    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
      Data(contentsOf: metadataURL(root, second.summary.id))) as? [String: Any])
    let summary = try XCTUnwrap(manifest["summary"] as? [String: Any])
    XCTAssertEqual(manifest["version"] as? Int, 1)
    XCTAssertEqual(Set(manifest.keys), ["version", "summary"])
    XCTAssertEqual(Set(summary.keys), ["id", "name", "createdAt", "byteCount", "checksum"])
  }

  func testListingDoesNotReadOrDecodePayloadsAndCorruptEntriesRemainDeletable() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let validator = MapLabValidationProbe(expected: Data([1, 2, 3]))
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    let healthy = try await store.save(name: "Good room", bytes: Data([1, 2, 3]))
    let badMetadata = try await store.save(name: "Bad metadata", bytes: Data([1, 2, 3]))
    let missingPayload = try await store.save(name: "Missing map", bytes: Data([1, 2, 3]))
    try Data("broken".utf8).write(to: metadataURL(root, badMetadata.summary.id))
    try FileManager.default.removeItem(at: payloadURL(root, missingPayload.summary.id))
    let listed = try await store.list()
    XCTAssertEqual(validator.count, 3, "Listing must not decode AR archives")
    XCTAssertEqual(listed.count, 3)
    XCTAssertEqual(listed.first { $0.id == healthy.summary.id }, healthy.summary)
    XCTAssertEqual(listed.first { $0.id == missingPayload.summary.id }, missingPayload.summary,
      "Listing must not open the map archive")
    let unreadable = try XCTUnwrap(listed.first { $0.id == badMetadata.summary.id })
    XCTAssertEqual(unreadable.name, "Unreadable scan")
    XCTAssertFalse(unreadable.isValid)
    await assertFailure(.invalidMap) { try await store.load(id: badMetadata.summary.id) }
    await assertFailure(.invalidMap) { try await store.load(id: missingPayload.summary.id) }
    try await store.delete(id: badMetadata.summary.id)
    try await store.delete(id: missingPayload.summary.id)
    let remaining = try await store.list()
    XCTAssertEqual(remaining, [healthy.summary])
  }

  func testOversizedFutureAndMismatchedMetadataFailIndividually() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let saved = try await store.save(name: "Room", bytes: Data([1, 2, 3]))
    let url = metadataURL(root, saved.summary.id)
    let original = try Data(contentsOf: url)
    try Data(repeating: 32, count: 4_097).write(to: url)
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    try original.write(to: url)
    try changeManifest(at: url) { $0["version"] = 2 }
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    for (key, value) in [("id", UUID().uuidString as Any), ("byteCount", 0),
      ("checksum", String(repeating: "X", count: 64)), ("name", " ")] {
      try original.write(to: url)
      try changeManifest(at: url) { manifest in
        var summary = manifest["summary"] as! [String: Any]
        summary[key] = value
        manifest["summary"] = summary
      }
      await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    }
    try await store.delete(id: saved.summary.id)
    let remaining = try await store.list()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testPayloadHashAndByteCountAreCheckedBeforeArchiveValidation() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([1, 2, 3])
    let validator = MapLabValidationProbe(expected: bytes)
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    let saved = try await store.save(name: "Room", bytes: bytes)
    let payload = payloadURL(root, saved.summary.id)
    try Data([1, 2, 4]).write(to: payload)
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    try Data([1, 2]).write(to: payload)
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    try bytes.write(to: payload)
    try changeManifest(at: metadataURL(root, saved.summary.id)) { manifest in
      var summary = manifest["summary"] as! [String: Any]
      summary["byteCount"] = 4
      manifest["summary"] = summary
    }
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    XCTAssertEqual(validator.count, 1, "Hash/count failures must not reach the AR decoder")
  }

  func testArchiveValidatorRunsOnSaveAndAgainAfterRestart() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([7, 8, 9])
    let validator = MapLabValidationProbe(expected: bytes)
    let writer = LocalMapLabStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    let saved = try await writer.save(name: "Room", bytes: bytes)
    XCTAssertEqual(validator.count, 1)
    let reader = LocalMapLabStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    _ = try await reader.list()
    XCTAssertEqual(validator.count, 1)
    _ = try await reader.load(id: saved.summary.id)
    XCTAssertEqual(validator.count, 2)
    let rejecting = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in throw MapLabFailure.invalidMap })
    await assertFailure(.invalidMap) { try await rejecting.load(id: saved.summary.id) }
    await assertFailure(.invalidMap) { try await rejecting.save(name: "Invalid archive", bytes: bytes) }
    let remaining = try await reader.list()
    XCTAssertEqual(remaining, [saved.summary])
  }

  func testDefaultValidatorRejectsRandomBytesAndSecureArchiveOfWrongRootClass() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalMapLabStore(rootDirectory: root)
    #if os(iOS) && canImport(ARKit)
    let failure = MapLabFailure.invalidMap
    #else
    let failure = MapLabFailure.unsupported
    #endif
    let wrongClass = try NSKeyedArchiver.archivedData(withRootObject: NSData(data: Data([1, 2, 3])),
      requiringSecureCoding: true)
    for bytes in [Data([1, 2, 3]), wrongClass] {
      await assertFailure(failure) { try await store.save(name: "Fake map", bytes: bytes) }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Decode must precede filesystem writes")
    let saved = try await fixtureStore(root).save(name: "Fixture", bytes: wrongClass)
    await assertFailure(failure) { try await store.load(id: saved.summary.id) }
  }

  func testCapacityCountsUnreadableEntriesAndDeletionMakesRoom() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    var saved: [MapLabBundle] = []
    for index in 0..<12 { saved.append(try await store.save(name: "Room \(index)", bytes: Data([1]))) }
    try Data("broken".utf8).write(to: metadataURL(root, saved[0].summary.id))
    await assertFailure(.libraryFull) { try await store.save(name: "Room 13", bytes: Data([1])) }
    let full = try await store.list()
    XCTAssertEqual(full.count, 12)
    try await store.delete(id: saved[0].summary.id)
    _ = try await store.save(name: "Replacement", bytes: Data([1]))
    let replacement = try await fixtureStore(root).list()
    XCTAssertEqual(replacement.count, 12)
    XCTAssertFalse(replacement.contains { $0.id == saved[0].summary.id })
  }

  func testNamesEmptyMapsAndEightMiBBounds() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    await assertFailure(.invalidName) { try await store.save(name: " \n", bytes: Data([1])) }
    await assertFailure(.invalidName) { try await store.save(name: String(repeating: "A", count: 61), bytes: Data([1])) }
    // One grapheme can have many UTF-8 bytes; the encoded manifest is bounded too.
    let unboundedGrapheme = "a" + String(repeating: "\u{0301}", count: 3_000)
    XCTAssertEqual(unboundedGrapheme.count, 1)
    await assertFailure(.invalidName) { try await store.save(name: unboundedGrapheme, bytes: Data([1])) }
    await assertFailure(.invalidMap) { try await store.save(name: "Empty", bytes: Data()) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    let sixty = String(repeating: "🌲", count: 60)
    let named = try await store.save(name: sixty, bytes: Data([1]))
    XCTAssertEqual(named.summary.name, sixty)
    let maximum = Data(repeating: 1, count: MapLabBundle.maximumBytes)
    XCTAssertEqual(maximum.count, 8 * 1024 * 1024)
    let full = try await store.save(name: "Full map", bytes: maximum)
    let reloaded = try await fixtureStore(root).load(id: full.summary.id)
    XCTAssertEqual(reloaded.bytes, maximum)
    await assertFailure(.mapTooLarge) {
      try await store.save(name: "Too large", bytes: Data(count: MapLabBundle.maximumBytes + 1))
    }
    try Data(count: MapLabBundle.maximumBytes + 1).write(to: payloadURL(root, full.summary.id))
    await assertFailure(.invalidMap) { try await store.load(id: full.summary.id) }
  }

  func testCancellationDuringValidationNeverPublishes() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = try await fixtureStore(root).save(name: "Existing", bytes: Data([1]))
    let cancelling = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in
      withUnsafeCurrentTask { $0?.cancel() }
    })
    let task = Task { try await cancelling.save(name: "Cancelled", bytes: Data([1])) }
    do { _ = try await task.value; XCTFail("A cancelled save must not publish") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [existing.summary])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [existing.summary.id.uuidString])
  }

  func testCancellationAfterStagedWritesPreventsPublicationAndCleansStaging() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = try await fixtureStore(root).save(name: "Existing", bytes: Data([1]))
    let recorder = MapLabFileOperationRecorder()
    let files = MapLabRecordingFileManager(recorder: recorder, cancelAfterMetadata: true)
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }, files: files)
    let task = Task { try await store.save(name: "Cancelled", bytes: Data([2])) }
    do { _ = try await task.value; XCTFail("Cancellation before rename must stop publication") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    XCTAssertTrue(recorder.requests.contains { $0.path.hasSuffix("/metadata.json") })
    XCTAssertTrue(recorder.requests.contains { $0.path.hasSuffix("/map.bin") })
    XCTAssertTrue(recorder.publications.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [existing.summary.id.uuidString])
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [existing.summary])
  }

  func testCompletedAtomicPublicationRemainsWhenCancellationArrivesAfterRename() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = MapLabFileOperationRecorder()
    let files = MapLabRecordingFileManager(recorder: recorder, cancelAfterPublication: true)
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }, files: files)
    let task = Task { try await store.save(name: "Committed", bytes: Data([1])) }
    let saved = try await task.value
    XCTAssertTrue(task.isCancelled)
    let publication = try XCTUnwrap(recorder.publications.first)
    XCTAssertEqual(recorder.publications.count, 1)
    XCTAssertEqual(Set(publication.stagedNames), ["map.bin", "metadata.json"])
    XCTAssertFalse(publication.destinationExisted)
    XCTAssertEqual(publication.destination.lastPathComponent, saved.summary.id.uuidString)
    let loaded = try await fixtureStore(root).load(id: saved.summary.id)
    XCTAssertEqual(loaded, saved)
  }

  func testFailedPublicationLeavesNoPartialMapAndPreservesExistingScan() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = try await fixtureStore(root).save(name: "Existing", bytes: Data([1]))
    let files = MapLabRecordingFileManager(failPublication: true)
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }, files: files)
    await assertFailure(.storageUnavailable) { try await store.save(name: "Disk full", bytes: Data([2])) }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [existing.summary.id.uuidString])
    let loaded = try await fixtureStore(root).load(id: existing.summary.id)
    XCTAssertEqual(loaded, existing)
  }

  func testRestartCleansOnlyGeneratedUnpublishedDirectories() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = try await fixtureStore(root).save(name: "Saved", bytes: Data([1]))
    let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    let deleting = root.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
    let unrelated = root.appendingPathComponent(".staging-not-a-map", isDirectory: true)
    for url in [staging, deleting, unrelated] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data([1]).write(to: url.appendingPathComponent("partial", isDirectory: false))
    }
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [existing.summary])
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deleting.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testSavedFilesArePrivateAndExcludedFromBackup() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await fixtureStore(root).save(name: "Private room", bytes: Data([1]))
    for (url, mode) in [(root, 0o700), (mapURL(root, saved.summary.id), 0o700),
      (metadataURL(root, saved.summary.id), 0o600), (payloadURL(root, saved.summary.id), 0o600)] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
      XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
  }

  func testSavedFilesReportCompleteProtectionOnPhysicalDevice() async throws {
    #if os(iOS) && !targetEnvironment(simulator)
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await fixtureStore(root).save(name: "Protected room", bytes: Data([1]))
    for url in [root, mapURL(root, saved.summary.id), metadataURL(root, saved.summary.id), payloadURL(root, saved.summary.id)] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
    #else
    throw XCTSkip("Complete protection readback requires a physical iOS device. Successful simulator requests do not prove device data protection.")
    #endif
  }

  #if os(iOS)
  func testSaveRequestsCompleteProtectionForEveryFileAndDirectory() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = MapLabFileOperationRecorder()
    let files = MapLabRecordingFileManager(recorder: recorder)
    let store = LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in }, files: files)
    _ = try await store.save(name: "Protected room", bytes: Data([1]))
    let requests = recorder.requests.filter { $0.protection != nil }
    XCTAssertEqual(requests.count, 4, "Protect the library, staging directory, metadata and map")
    XCTAssertEqual(Set(requests.map(\.path)).count, 4)
    XCTAssertEqual(requests.compactMap(\.permissions).sorted(), [0o600, 0o600, 0o700, 0o700])
    for request in requests {
      XCTAssertEqual(request.protection, FileProtectionType.complete.rawValue,
        "Assert the actual protection attribute passed through to Foundation")
    }
  }
  #endif

  func testSymlinkPayloadIsRejectedAndDeletingSymlinkEntryDoesNotFollowIt() async throws {
    let root = temporaryLibrary(), outside = temporaryLibrary()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let store = fixtureStore(root)
    let saved = try await store.save(name: "Room", bytes: Data([1, 2, 3]))
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let externalMap = outside.appendingPathComponent("map.bin", isDirectory: false)
    try saved.bytes.write(to: externalMap)
    let payload = payloadURL(root, saved.summary.id)
    try FileManager.default.removeItem(at: payload)
    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: externalMap)
    await assertFailure(.invalidMap) { try await store.load(id: saved.summary.id) }
    let linkID = UUID()
    try FileManager.default.createSymbolicLink(at: mapURL(root, linkID), withDestinationURL: outside)
    await assertFailure(.invalidMap) { try await store.load(id: linkID) }
    try await store.delete(id: linkID)
    try await store.delete(id: saved.summary.id)
    XCTAssertEqual(try Data(contentsOf: externalMap), saved.bytes)
  }

  func testSeparateMapLabRootLeavesLegacySavedArenasUntouched() async throws {
    let support = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: support) }
    let app = support.appendingPathComponent("VictoriaKillZone", isDirectory: true)
    let legacy = app.appendingPathComponent("SavedArenas", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let original = legacy.appendingPathComponent("legacy-marker", isDirectory: false)
    try Data([8, 9]).write(to: original)
    let root = app.appendingPathComponent("MapLab", isDirectory: true)
    let saved = try await fixtureStore(root).save(name: "New map", bytes: Data([1]))
    try await fixtureStore(root).delete(id: saved.summary.id)
    XCTAssertEqual(try Data(contentsOf: original), Data([8, 9]))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path), ["legacy-marker"])
  }

  func testStorageErrorsAreTypedAndPreserveRegularFileAtRootPath() async throws {
    // A regular-file URL must not include a directory hint/trailing slash.
    let root = URL(fileURLWithPath: temporaryLibrary().path, isDirectory: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root)
    let store = fixtureStore(root)
    await assertFailure(.storageUnavailable) { try await store.list() }
    await assertFailure(.storageUnavailable) { try await store.save(name: "Room", bytes: Data([1])) }
    XCTAssertFalse(MapLabFailure.storageUnavailable.localizedDescription.contains(root.path))
    XCTAssertEqual(try Data(contentsOf: root), Data([1]))
  }

  private func temporaryLibrary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("map-lab-test-\(UUID().uuidString)", isDirectory: true)
  }

  private func fixtureStore(_ root: URL) -> LocalMapLabStore {
    LocalMapLabStore(rootDirectory: root, validateWorldMap: { _ in })
  }

  private func mapURL(_ root: URL, _ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private func metadataURL(_ root: URL, _ id: UUID) -> URL {
    mapURL(root, id).appendingPathComponent("metadata.json", isDirectory: false)
  }

  private func payloadURL(_ root: URL, _ id: UUID) -> URL {
    mapURL(root, id).appendingPathComponent("map.bin", isDirectory: false)
  }

  private func changeManifest(at url: URL, change: (inout [String: Any]) -> Void) throws {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    change(&value)
    try JSONSerialization.data(withJSONObject: value).write(to: url)
  }

  private func assertFailure<T>(_ expected: MapLabFailure,
    file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? MapLabFailure, expected, file: file, line: line) }
  }
}

/// The FileManager itself transfers exclusively into the store actor. Only this
/// observer is shared: its complete mutable state is locked, and reads return
/// independent arrays containing immutable Sendable values.
private final class MapLabFileOperationRecorder: @unchecked Sendable {
  struct Request: Sendable {
    let path: String
    let permissions: Int?
    let protection: String?
  }
  struct Publication: Sendable {
    let stagedNames: [String]
    let destinationExisted: Bool
    let destination: URL
  }
  private let lock = NSLock()
  private var recorded: [Request] = []
  private var committed: [Publication] = []

  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
  var publications: [Publication] { lock.lock(); defer { lock.unlock() }; return committed }

  func record(_ request: Request) { lock.lock(); defer { lock.unlock() }; recorded.append(request) }
  func record(_ publication: Publication) { lock.lock(); defer { lock.unlock() }; committed.append(publication) }
}

private final class MapLabRecordingFileManager: FileManager {
  private let recorder: MapLabFileOperationRecorder
  private let cancelAfterMetadata: Bool
  private let failPublication: Bool
  private let cancelAfterPublication: Bool

  init(recorder: MapLabFileOperationRecorder = MapLabFileOperationRecorder(),
    cancelAfterMetadata: Bool = false, failPublication: Bool = false, cancelAfterPublication: Bool = false) {
    self.recorder = recorder
    self.cancelAfterMetadata = cancelAfterMetadata
    self.failPublication = failPublication
    self.cancelAfterPublication = cancelAfterPublication
    super.init()
  }

  override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
    // Record successful real Foundation requests, not a no-op replacement.
    try super.setAttributes(attributes, ofItemAtPath: path)
    #if os(iOS)
    let protection = attributes[.protectionKey] as? String
    #else
    let protection: String? = nil
    #endif
    recorder.record(.init(path: path, permissions: attributes[.posixPermissions] as? Int, protection: protection))
    if cancelAfterMetadata && path.hasSuffix("/metadata.json") {
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }

  override func moveItem(at source: URL, to destination: URL) throws {
    guard source.lastPathComponent.hasPrefix(".staging-") else {
      try super.moveItem(at: source, to: destination)
      return
    }
    let publication = MapLabFileOperationRecorder.Publication(stagedNames: try contentsOfDirectory(atPath: source.path),
      destinationExisted: fileExists(atPath: destination.path), destination: destination)
    if failPublication { throw CocoaError(.fileWriteOutOfSpace) }
    try super.moveItem(at: source, to: destination)
    recorder.record(publication)
    if cancelAfterPublication { withUnsafeCurrentTask { $0?.cancel() } }
  }
}

private final class MapLabValidationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let expected: Data
  private var validations = 0
  init(expected: Data) { self.expected = expected }
  var count: Int { lock.lock(); defer { lock.unlock() }; return validations }
  func validate(_ bytes: Data) throws {
    lock.lock(); defer { lock.unlock() }
    guard bytes == expected else { throw MapLabFailure.invalidMap }
    validations += 1
  }
}
