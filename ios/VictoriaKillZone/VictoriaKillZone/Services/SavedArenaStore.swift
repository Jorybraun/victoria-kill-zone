import Foundation
#if os(iOS) && canImport(ARKit)
import ARKit
#endif

/// One application-owned actor serializes the local library. A complete arena
/// directory is published with a rename, so interruption cannot publish half a
/// scan. Metadata listing never opens the larger camera/map payloads.
actor LocalSavedArenaStore: SavedArenaStoring {
  static let maximumArenas = 12
  private static let maximumMetadataBytes = 4_096
  private static let metadataName = "metadata.json"
  private static let payloadName = "map.bin"

  private struct Manifest: Codable {
    let version: Int
    let summary: SavedArenaSummary
  }

  private let rootDirectory: URL?
  private let validateWorldMap: @Sendable (Data) throws -> Void
  private let files: FileManager
  private var preparedRoot: URL?

  init(rootDirectory: URL? = nil) {
    self.rootDirectory = rootDirectory
    files = .default
    validateWorldMap = { try LocalSavedArenaStore.decodeWorldMap($0) }
  }

  /// Explicit fixture-only injection; the application's default initializer
  /// always uses secure ARWorldMap decoding.
  init(rootDirectory: URL, validateWorldMap: @escaping @Sendable (Data) throws -> Void,
    files: FileManager = .default) {
    self.rootDirectory = rootDirectory
    self.validateWorldMap = validateWorldMap
    self.files = files
  }

  func list() async throws -> [SavedArenaSummary] {
    try perform {
      try Task.checkCancellation()
      let root = try prepareRoot()
      return try entries(in: root).map { entry in
        try Task.checkCancellation()
        // Preserve the UUID even when metadata is damaged, so the user can
        // delete that entry and continue using every other saved arena.
        return (try? readSummary(at: entry.url, id: entry.id))
          ?? SavedArenaSummary(id: entry.id, name: "Unreadable arena", createdAt: .distantPast,
            frameID: "", byteCount: 0)
      }.sorted {
        if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
        return $0.createdAt > $1.createdAt
      }
    }
  }

  func save(name: String, bytes: Data) async throws -> SavedArenaBundle {
    try perform {
      try Task.checkCancellation()
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 60 else { throw SavedArenaFailure.invalidName }
      guard bytes.count <= DuelFrameMap.maximumBytes else { throw SavedArenaFailure.arenaTooLarge }
      let map: DuelFrameMap
      do { map = try DuelFrameMap(epoch: 1, bytes: bytes) }
      catch { throw SavedArenaFailure.invalidArena }
      guard map.reference != nil else { throw SavedArenaFailure.incompatibleArena }
      try validateWorldMap(map.worldMapBytes)
      try Task.checkCancellation()
      let summary = SavedArenaSummary(id: UUID(), name: name, createdAt: Date(),
        frameID: map.frameID, byteCount: bytes.count)
      let metadata = try JSONEncoder().encode(Manifest(version: 1, summary: summary))
      guard metadata.count <= Self.maximumMetadataBytes else { throw SavedArenaFailure.invalidName }
      let root = try prepareRoot()
      guard try entries(in: root).count < Self.maximumArenas else { throw SavedArenaFailure.libraryFull }
      let staging = root.appendingPathComponent(".staging-\(summary.id.uuidString)", isDirectory: true)
      defer { try? files.removeItem(at: staging) }
      try createPrivateDirectory(at: staging)
      try writePrivate(bytes, to: staging.appendingPathComponent(Self.payloadName))
      try writePrivate(metadata, to: staging.appendingPathComponent(Self.metadataName))
      // Cancellation after capture/background must not publish a late result.
      // Once the atomic rename completes, the saved scan is intentionally kept.
      try Task.checkCancellation()
      try files.moveItem(at: staging, to: arenaURL(id: summary.id, root: root))
      return SavedArenaBundle(summary: summary, bytes: bytes)
    }
  }

  func load(id: UUID) async throws -> SavedArenaBundle {
    try perform {
      try Task.checkCancellation()
      let directory = arenaURL(id: id, root: try prepareRoot())
      guard try entryExists(at: directory) else { throw SavedArenaFailure.notFound }
      let summary = try readSummary(at: directory, id: id)
      let bytes = try readBounded(directory.appendingPathComponent(Self.payloadName),
        maximumBytes: DuelFrameMap.maximumBytes)
      let bundle = SavedArenaBundle(summary: summary, bytes: bytes)
      let map = try bundle.map(epoch: 1)
      try validateWorldMap(map.worldMapBytes)
      try Task.checkCancellation()
      return bundle
    }
  }

  func delete(id: UUID) async throws {
    try perform {
      try Task.checkCancellation()
      let root = try prepareRoot()
      let directory = arenaURL(id: id, root: root)
      // Delete is idempotent and does not decode potentially damaged metadata.
      guard try entryExists(at: directory) else { return }
      let removing = root.appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
      try files.moveItem(at: directory, to: removing)
      try files.removeItem(at: removing)
    }
  }

  private func prepareRoot() throws -> URL {
    if let preparedRoot { return preparedRoot }
    let root: URL
    if let rootDirectory { root = rootDirectory }
    else {
      let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      root = support.appendingPathComponent("VictoriaKillZone", isDirectory: true)
        .appendingPathComponent("SavedArenas", isDirectory: true)
    }
    try createPrivateDirectory(at: root)
    // Only our generated unpublished/tombstone names are eligible for cleanup.
    // A crash during save/delete must not leave unbounded hidden map payloads.
    for child in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      let name = child.lastPathComponent
      let prefix = name.hasPrefix(".staging-") ? ".staging-" : ".deleting-"
      if name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil {
        try? files.removeItem(at: child)
      }
    }
    preparedRoot = root
    return root
  }

  private func entries(in root: URL) throws -> [(id: UUID, url: URL)] {
    try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      .compactMap { url in
        guard let id = UUID(uuidString: url.lastPathComponent), url.lastPathComponent == id.uuidString else { return nil }
        return (id, url)
      }
  }

  private func arenaURL(id: UUID, root: URL) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private func entryExists(at url: URL) throws -> Bool {
    do { _ = try files.attributesOfItem(atPath: url.path); return true }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
  }

  private func readSummary(at directory: URL, id: UUID) throws -> SavedArenaSummary {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw SavedArenaFailure.invalidArena }
    let data = try readBounded(directory.appendingPathComponent(Self.metadataName),
      maximumBytes: Self.maximumMetadataBytes)
    let manifest: Manifest
    do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
    catch { throw SavedArenaFailure.invalidArena }
    guard manifest.version == 1 else { throw SavedArenaFailure.incompatibleArena }
    guard manifest.summary.id == id, manifest.summary.isValid else { throw SavedArenaFailure.invalidArena }
    return manifest.summary
  }

  private func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
    let values: URLResourceValues
    do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
    catch { throw SavedArenaFailure.invalidArena }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, (1...maximumBytes).contains(size) else { throw SavedArenaFailure.invalidArena }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    // Bound the read itself as well as stat: a replaced/growing file cannot
    // force allocation of an unbounded payload or metadata document.
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard !data.isEmpty, data.count <= maximumBytes else { throw SavedArenaFailure.invalidArena }
    return data
  }

  private func createPrivateDirectory(at url: URL) throws {
    if files.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw SavedArenaFailure.storageUnavailable }
    } else {
      try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try protect(url, permissions: 0o700)
  }

  private func writePrivate(_ data: Data, to url: URL) throws {
    #if os(iOS)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    #else
    try data.write(to: url, options: .atomic)
    #endif
    try protect(url, permissions: 0o600)
  }

  private func protect(_ url: URL, permissions: Int) throws {
    var attributes: [FileAttributeKey: Any] = [.posixPermissions: permissions]
    #if os(iOS)
    attributes[.protectionKey] = FileProtectionType.complete.rawValue
    #endif
    try files.setAttributes(attributes, ofItemAtPath: url.path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private func perform<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch let error as SavedArenaFailure { throw error }
    catch is CancellationError { throw CancellationError() }
    catch { throw SavedArenaFailure.storageUnavailable }
  }

  private static func decodeWorldMap(_ bytes: Data) throws {
    #if os(iOS) && canImport(ARKit)
    guard !bytes.isEmpty, bytes.count <= DuelFrameMap.maximumBytes,
      (try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes)) != nil
    else { throw SavedArenaFailure.invalidArena }
    #else
    // The shipping iOS path always securely decodes ARWorldMap. Non-AR hosts
    // require an explicit fixture validator; they cannot silently accept bytes.
    throw SavedArenaFailure.incompatibleArena
    #endif
  }
}
