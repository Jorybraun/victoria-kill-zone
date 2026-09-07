import Foundation
import XCTest
@testable import VictoriaKillZone

final class SavedArenaStoreTests: XCTestCase {
  func testRoundTripAfterRestartAndDeletePreservesOtherArena() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try arenaBytes()
    let first = try await fixtureStore(root).save(name: "  Living room \n", bytes: bytes)
    let second = try await fixtureStore(root).save(name: "Living room", bytes: bytes)
    XCTAssertEqual(first.summary.name, "Living room")
    XCTAssertNotEqual(first.summary.id, second.summary.id)
    XCTAssertEqual(first.summary.byteCount, bytes.count)
    XCTAssertTrue(first.summary.isValid)

    let restarted = fixtureStore(root)
    let summaries = try await restarted.list()
    XCTAssertEqual(summaries.map(\.id), [second.summary.id, first.summary.id])
    let loaded = try await restarted.load(id: first.summary.id)
    XCTAssertEqual(loaded, first)
    try await restarted.delete(id: first.summary.id)
    try await restarted.delete(id: first.summary.id)
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [second.summary])
    await assertFailure(.notFound) { try await restarted.load(id: first.summary.id) }
  }

  func testSavedBytesRebindToNewEpochWithoutAlignmentEvidence() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await fixtureStore(root).save(name: "Hall", bytes: arenaBytes())
    let map = try saved.map(epoch: 7)
    XCTAssertEqual(map.epoch, 7)
    XCTAssertEqual(map.bytes, saved.bytes)
    XCTAssertEqual(map.frameID, saved.summary.frameID)
    XCTAssertNotNil(map.reference)
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: map.epoch, captureRequired: false)
    try policy.beginInstall(map, at: Date())
    XCTAssertEqual(policy.snapshot.stage, .relocalizingWorld)
    XCTAssertNil(policy.snapshot.localPose)
    XCTAssertNil(policy.snapshot.residual)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire())
    XCTAssertThrowsError(try saved.map(epoch: 0)) { XCTAssertEqual($0 as? DuelFrameFailure, .invalidEpoch) }
    let metadata = try Data(contentsOf: metadataURL(root, saved.summary.id))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
    let summary = try XCTUnwrap(object["summary"] as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["version", "summary"])
    XCTAssertEqual(Set(summary.keys), ["id", "name", "createdAt", "frameID", "byteCount"])
  }

  func testListingReadsMetadataLazilyAndCorruptEntriesRemainDeletable() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let healthy = try await store.save(name: "Good room", bytes: arenaBytes())
    let badMetadata = try await store.save(name: "Bad metadata", bytes: arenaBytes())
    let missingPayload = try await store.save(name: "Missing map", bytes: arenaBytes())
    try Data("broken".utf8).write(to: metadataURL(root, badMetadata.summary.id))
    try FileManager.default.removeItem(at: payloadURL(root, missingPayload.summary.id))
    let listed = try await store.list()
    XCTAssertEqual(listed.count, 3)
    XCTAssertEqual(listed.first { $0.id == healthy.summary.id }, healthy.summary)
    XCTAssertEqual(listed.first { $0.id == missingPayload.summary.id }, missingPayload.summary,
      "Listing must not read the map archive")
    XCTAssertEqual(listed.first { $0.id == badMetadata.summary.id }?.name, "Unreadable arena")
    await assertFailure(.invalidArena) { try await store.load(id: badMetadata.summary.id) }
    await assertFailure(.invalidArena) { try await store.load(id: missingPayload.summary.id) }
    try await store.delete(id: badMetadata.summary.id)
    try await store.delete(id: missingPayload.summary.id)
    let remaining = try await store.list()
    XCTAssertEqual(remaining, [healthy.summary])
  }

  func testMalformedOversizedMismatchedAndFutureMetadataFailIndividually() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let saved = try await store.save(name: "Room", bytes: arenaBytes())
    let url = metadataURL(root, saved.summary.id)
    let original = try Data(contentsOf: url)
    try Data(repeating: 32, count: 4_097).write(to: url)
    await assertFailure(.invalidArena) { try await store.load(id: saved.summary.id) }
    try original.write(to: url)
    try changeManifest(at: url) { $0["version"] = 2 }
    await assertFailure(.incompatibleArena) { try await store.load(id: saved.summary.id) }
    try original.write(to: url)
    try changeManifest(at: url) { manifest in
      var summary = manifest["summary"] as! [String: Any]
      summary["id"] = UUID().uuidString
      manifest["summary"] = summary
    }
    await assertFailure(.invalidArena) { try await store.load(id: saved.summary.id) }
    try await store.delete(id: saved.summary.id)
    let remaining = try await store.list()
    XCTAssertTrue(remaining.isEmpty)
  }

  func testPayloadHashAndByteCountAreRecheckedBeforeUse() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let saved = try await store.save(name: "Room", bytes: arenaBytes())
    var changed = saved.bytes
    changed[changed.count - 1] ^= 1
    try changed.write(to: payloadURL(root, saved.summary.id))
    await assertFailure(.invalidArena) { try await store.load(id: saved.summary.id) }
    let forged = SavedArenaBundle(summary: saved.summary, bytes: changed)
    XCTAssertThrowsError(try forged.map(epoch: 2)) { XCTAssertEqual($0 as? SavedArenaFailure, .invalidArena) }
    try saved.bytes.dropLast().write(to: payloadURL(root, saved.summary.id))
    await assertFailure(.invalidArena) { try await store.load(id: saved.summary.id) }
  }

  func testMissingOrMalformedReferenceCannotBeSaved() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    await assertFailure(.incompatibleArena) { try await store.save(name: "Legacy", bytes: Data([1, 2, 3])) }
    await assertFailure(.invalidArena) { try await store.save(name: "Empty", bytes: Data()) }
    var malformed = try arenaBytes()
    malformed[16] = 0 // Corrupt the reference JSON inside the otherwise complete envelope.
    let invalidBytes = malformed
    await assertFailure(.invalidArena) { try await store.save(name: "No reference", bytes: invalidBytes) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Validation must precede writes")
  }

  func testArchiveValidatorRunsOnSaveAndAgainAfterRestart() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try arenaBytes(worldMap: Data([7, 8, 9]))
    let validator = ArchiveValidationProbe(expected: Data([7, 8, 9]))
    let writer = LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    let saved = try await writer.save(name: "Room", bytes: bytes)
    XCTAssertEqual(validator.count, 1)
    let reader = LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { try validator.validate($0) })
    _ = try await reader.list()
    XCTAssertEqual(validator.count, 1, "Listing must not decode AR archives")
    _ = try await reader.load(id: saved.summary.id)
    XCTAssertEqual(validator.count, 2)
    let rejecting = LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { _ in throw SavedArenaFailure.invalidArena })
    await assertFailure(.invalidArena) { try await rejecting.load(id: saved.summary.id) }
    await assertFailure(.invalidArena) { try await rejecting.save(name: "Invalid archive", bytes: bytes) }
    let remaining = try await reader.list()
    XCTAssertEqual(remaining, [saved.summary])
  }

  func testDefaultValidatorNeverAcceptsFixtureAsSecureARWorldMap() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSavedArenaStore(rootDirectory: root)
    #if os(iOS) && canImport(ARKit)
    let failure = SavedArenaFailure.invalidArena
    #else
    let failure = SavedArenaFailure.incompatibleArena
    #endif
    await assertFailure(failure) { try await store.save(name: "Fake archive", bytes: self.arenaBytes()) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testCapacityCountsUnreadableEntriesAndDeletionMakesRoom() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let bytes = try arenaBytes()
    var saved: [SavedArenaBundle] = []
    for index in 0..<12 { saved.append(try await store.save(name: "Room \(index)", bytes: bytes)) }
    try Data("broken".utf8).write(to: metadataURL(root, saved[0].summary.id))
    await assertFailure(.libraryFull) { try await store.save(name: "Room 13", bytes: bytes) }
    let full = try await store.list()
    XCTAssertEqual(full.count, 12)
    try await store.delete(id: saved[0].summary.id)
    _ = try await store.save(name: "Replacement", bytes: bytes)
    let replacement = try await fixtureStore(root).list()
    XCTAssertEqual(replacement.count, 12)
    XCTAssertFalse(replacement.contains { $0.id == saved[0].summary.id })
  }

  func testNameAndEightMiBBounds() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = fixtureStore(root)
    let bytes = try arenaBytes()
    await assertFailure(.invalidName) { try await store.save(name: " \n", bytes: bytes) }
    await assertFailure(.invalidName) { try await store.save(name: String(repeating: "A", count: 61), bytes: bytes) }
    let sixty = String(repeating: "🌲", count: 60)
    let named = try await store.save(name: sixty, bytes: bytes)
    XCTAssertEqual(named.summary.name, sixty)
    let emptyOverhead = try arenaBytes(worldMap: Data([0])).count - 1
    let maximum = try arenaBytes(worldMap: Data(repeating: 1, count: DuelFrameMap.maximumBytes - emptyOverhead))
    XCTAssertEqual(maximum.count, 8 * 1024 * 1024)
    _ = try await store.save(name: "Full map", bytes: maximum)
    await assertFailure(.arenaTooLarge) {
      try await store.save(name: "Too large", bytes: Data(count: DuelFrameMap.maximumBytes + 1))
    }
  }

  func testCancellationDuringValidationNeverPublishesAndKeepsExistingArena() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try arenaBytes()
    let existing = try await fixtureStore(root).save(name: "Existing", bytes: bytes)
    let cancelling = LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { _ in
      withUnsafeCurrentTask { $0?.cancel() }
    })
    let task = Task { try await cancelling.save(name: "Cancelled", bytes: bytes) }
    do { _ = try await task.value; XCTFail("A cancelled save must not publish") }
    catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    let remaining = try await fixtureStore(root).list()
    XCTAssertEqual(remaining, [existing.summary])
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertEqual(files, [existing.summary.id.uuidString])
  }

  func testInterruptedUnpublishedDirectoriesAreCleanedWithoutTouchingPublishedScans() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = try await fixtureStore(root).save(name: "Saved", bytes: arenaBytes())
    let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
    let deleting = root.appendingPathComponent(".deleting-\(UUID().uuidString)")
    let unrelated = root.appendingPathComponent(".staging-not-an-arena")
    for url in [staging, deleting, unrelated] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data([1]).write(to: url.appendingPathComponent("partial"))
    }
    let restarted = fixtureStore(root)
    let remaining = try await restarted.list()
    XCTAssertEqual(remaining, [existing.summary])
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deleting.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    let loaded = try await restarted.load(id: existing.summary.id)
    XCTAssertEqual(loaded, existing)
  }

  func testSavedFilesArePrivateAndExcludedFromBackup() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = try await fixtureStore(root).save(name: "Private room", bytes: arenaBytes())
    let directory = root.appendingPathComponent(saved.summary.id.uuidString)
    for (url, mode) in [(root, 0o700), (directory, 0o700),
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
    let saved = try await fixtureStore(root).save(name: "Protected room", bytes: arenaBytes())
    for url in [root, root.appendingPathComponent(saved.summary.id.uuidString),
      metadataURL(root, saved.summary.id), payloadURL(root, saved.summary.id)] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      // Foundation returns NSString. Missing or weaker protection fails on a
      // physical device; a successful simulator request is not this evidence.
      XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }
    #else
    throw XCTSkip("Requires a physical iOS device. Our iOS 26.5 Simulator returns no protection attribute; request verification does not prove device data protection.")
    #endif
  }

  #if os(iOS)
  func testSaveRequestsCompleteProtectionForEveryFileAndDirectory() async throws {
    let root = temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ProtectionRecordingFileManager()
    let store = LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { _ in }, files: files)
    _ = try await store.save(name: "Protected room", bytes: arenaBytes())
    // Foundation may also set permissions while creating directories. Keep
    // recording those calls, but validate the store's explicit protection writes.
    let requests = files.requests.filter { $0.protection != nil }
    XCTAssertEqual(requests.count, 4, "Protect the library, staged arena, metadata and map")
    XCTAssertEqual(Set(requests.map(\.path)).count, 4)
    XCTAssertEqual(requests.compactMap(\.permissions).sorted(), [0o600, 0o600, 0o700, 0o700])
    for request in requests {
      XCTAssertEqual(request.protection, FileProtectionType.complete.rawValue,
        "Every actual FileManager write must request Complete protection")
    }
    // This proves the request reached Foundation and writes succeeded. Device
    // readback above and a locked-device check remain separate acceptance.
  }
  #endif

  func testSymlinkPayloadIsRejectedAndDeletingSymlinkEntryDoesNotFollowIt() async throws {
    let root = temporaryLibrary(), outside = temporaryLibrary()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let store = fixtureStore(root)
    let saved = try await store.save(name: "Room", bytes: arenaBytes())
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let externalMap = outside.appendingPathComponent("map.bin")
    try saved.bytes.write(to: externalMap)
    let payload = payloadURL(root, saved.summary.id)
    try FileManager.default.removeItem(at: payload)
    try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: externalMap)
    await assertFailure(.invalidArena) { try await store.load(id: saved.summary.id) }
    let linkID = UUID()
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(linkID.uuidString), withDestinationURL: outside)
    await assertFailure(.invalidArena) { try await store.load(id: linkID) }
    try await store.delete(id: linkID)
    XCTAssertEqual(try Data(contentsOf: externalMap), saved.bytes)
    try await store.delete(id: saved.summary.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: externalMap.path))
  }

  func testStorageErrorsAreTypedAndDoNotExposePaths() async throws {
    // This fixture is deliberately a regular file, not a directory URL with
    // a trailing slash (which Foundation rejects differently on Simulator).
    let root = URL(fileURLWithPath: temporaryLibrary().path, isDirectory: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root)
    let store = fixtureStore(root)
    await assertFailure(.storageUnavailable) { try await store.list() }
    await assertFailure(.storageUnavailable) { try await store.save(name: "Room", bytes: self.arenaBytes()) }
    XCTAssertFalse(SavedArenaFailure.storageUnavailable.localizedDescription.contains(root.path))
    XCTAssertEqual(try Data(contentsOf: root), Data([1]))
  }

  private func temporaryLibrary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("saved-arena-test-\(UUID().uuidString)", isDirectory: true)
  }

  private func fixtureStore(_ root: URL) -> LocalSavedArenaStore {
    LocalSavedArenaStore(rootDirectory: root, validateWorldMap: { _ in })
  }

  private func arenaBytes(worldMap: Data = Data([10, 20, 30])) throws -> Data {
    let reference = try DuelFrameReference(imageData: Data([1, 2, 3]), widthMeters: 0.8, heightMeters: 0.6,
      mapFromImage: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      sampleCount: 3, maximumCornerDeviationMeters: 0.005)
    return try DuelFrameCalibrationBundle.encode(worldMap: worldMap, reference: reference)
  }

  private func metadataURL(_ root: URL, _ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString).appendingPathComponent("metadata.json")
  }

  private func payloadURL(_ root: URL, _ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString).appendingPathComponent("map.bin")
  }

  private func changeManifest(at url: URL, change: (inout [String: Any]) -> Void) throws {
    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    change(&value)
    try JSONSerialization.data(withJSONObject: value).write(to: url)
  }

  private func assertFailure<T>(_ expected: SavedArenaFailure,
    file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? SavedArenaFailure, expected, file: file, line: line) }
  }
}

#if os(iOS)
private final class ProtectionRecordingFileManager: FileManager, @unchecked Sendable {
  struct Request {
    let path: String
    let permissions: Int?
    let protection: String?
  }
  private let lock = NSLock()
  private var recorded: [Request] = []
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

  override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
    // Forward to the real filesystem; this is an observation point, not a
    // replacement that could make failed or omitted protection writes pass.
    try super.setAttributes(attributes, ofItemAtPath: path)
    let request = Request(path: path, permissions: attributes[.posixPermissions] as? Int,
      protection: attributes[.protectionKey] as? String)
    lock.lock(); defer { lock.unlock() }
    recorded.append(request)
  }
}
#endif

private final class ArchiveValidationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let expected: Data
  private var validations = 0
  init(expected: Data) { self.expected = expected }
  var count: Int { lock.lock(); defer { lock.unlock() }; return validations }
  func validate(_ bytes: Data) throws {
    lock.lock(); defer { lock.unlock() }
    guard bytes == expected else { throw SavedArenaFailure.invalidArena }
    validations += 1
  }
}
