import Foundation
#if os(iOS) && canImport(ARKit)
import ARKit
#endif

/// Offline world maps have their own bounded library. Publishing one complete
/// private directory keeps interrupted saves invisible to readers.
actor LocalMapLabStore: MapLabStoring {
  private static let maximumMetadataBytes = 4_096
  private static let metadataName = "metadata.json"
  private static let payloadName = "map.bin"

  private struct Manifest: Codable {
    let version: Int
    let summary: MapLabSummary
  }

  private let rootDirectory: URL?
  private let validateWorldMap: @Sendable (Data) throws -> Void
  private let files: FileManager
  private var preparedRoot: URL?

  init(rootDirectory: URL? = nil) {
    self.rootDirectory = rootDirectory
    files = .default
    validateWorldMap = { try LocalMapLabStore.decodeWorldMap($0) }
  }

  /// Tests must explicitly opt into fixture archives. The application always
  /// uses the initializer above and secure ARWorldMap decoding.
  init(rootDirectory: URL, validateWorldMap: @escaping @Sendable (Data) throws -> Void,
    files: FileManager = .default) {
    self.rootDirectory = rootDirectory
    self.validateWorldMap = validateWorldMap
    self.files = files
  }

  func list() async throws -> [MapLabSummary] {
    try perform {
      try Task.checkCancellation()
      return try entries(in: prepareRoot()).map { entry in
        try Task.checkCancellation()
        // Keep an unreadable entry's generated ID available for deletion. The
        // larger map archive is read and decoded only when loading that entry.
        return (try? readSummary(at: entry.url, id: entry.id))
          ?? MapLabSummary(id: entry.id, name: "Unreadable scan", createdAt: .distantPast,
            byteCount: 0, checksum: "")
      }.sorted {
        if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
        return $0.createdAt > $1.createdAt
      }
    }
  }

  func save(name: String, bytes: Data) async throws -> MapLabBundle {
    try perform {
      try Task.checkCancellation()
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 60 else { throw MapLabFailure.invalidName }
      guard bytes.count <= MapLabBundle.maximumBytes else { throw MapLabFailure.mapTooLarge }
      guard !bytes.isEmpty else { throw MapLabFailure.invalidMap }
      try validateWorldMap(bytes)
      try Task.checkCancellation()
      let summary = MapLabSummary(id: UUID(), name: name, createdAt: Date(),
        byteCount: bytes.count, checksum: MapLabBundle.checksum(bytes))
      let metadata = try JSONEncoder().encode(Manifest(version: 1, summary: summary))
      guard metadata.count <= Self.maximumMetadataBytes else { throw MapLabFailure.invalidName }
      let root = try prepareRoot()
      guard try entries(in: root).count < MapLabBundle.maximumMaps else { throw MapLabFailure.libraryFull }
      let staging = root.appendingPathComponent(".staging-\(summary.id.uuidString)", isDirectory: true)
      defer { try? files.removeItem(at: staging) }
      try createPrivateDirectory(at: staging)
      try writePrivate(bytes, to: staging.appendingPathComponent(Self.payloadName, isDirectory: false))
      try writePrivate(metadata, to: staging.appendingPathComponent(Self.metadataName, isDirectory: false))
      // A cancelled capture may finish writing staging, but cannot publish a
      // late result. A completed atomic rename intentionally remains saved.
      try Task.checkCancellation()
      try files.moveItem(at: staging, to: mapURL(id: summary.id, root: root))
      return MapLabBundle(summary: summary, bytes: bytes)
    }
  }

  func load(id: UUID) async throws -> MapLabBundle {
    try perform {
      try Task.checkCancellation()
      let directory = mapURL(id: id, root: try prepareRoot())
      guard try entryExists(at: directory) else { throw MapLabFailure.notFound }
      let summary = try readSummary(at: directory, id: id)
      let bytes = try readBounded(directory.appendingPathComponent(Self.payloadName, isDirectory: false),
        maximumBytes: MapLabBundle.maximumBytes)
      let bundle = MapLabBundle(summary: summary, bytes: bytes)
      try bundle.validate()
      try validateWorldMap(bytes)
      try Task.checkCancellation()
      return bundle
    }
  }

  func delete(id: UUID) async throws {
    try perform {
      try Task.checkCancellation()
      let root = try prepareRoot()
      let directory = mapURL(id: id, root: root)
      // Deletion is idempotent and never decodes damaged metadata or archives.
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
        .appendingPathComponent("MapLab", isDirectory: true)
    }
    try createPrivateDirectory(at: root)
    // Clean only our generated unpublished/tombstone entries after interruption.
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

  private func mapURL(id: UUID, root: URL) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private func entryExists(at url: URL) throws -> Bool {
    do { _ = try files.attributesOfItem(atPath: url.path); return true }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
  }

  private func readSummary(at directory: URL, id: UUID) throws -> MapLabSummary {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { throw MapLabFailure.invalidMap }
    let data = try readBounded(directory.appendingPathComponent(Self.metadataName, isDirectory: false),
      maximumBytes: Self.maximumMetadataBytes)
    let manifest: Manifest
    do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
    catch { throw MapLabFailure.invalidMap }
    guard manifest.version == 1, manifest.summary.id == id, manifest.summary.isValid
    else { throw MapLabFailure.invalidMap }
    return manifest.summary
  }

  private func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
    let values: URLResourceValues
    do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
    catch { throw MapLabFailure.invalidMap }
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, (1...maximumBytes).contains(size) else { throw MapLabFailure.invalidMap }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    // Bound the read itself: a growing file cannot force an unbounded allocation.
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard !data.isEmpty, data.count <= maximumBytes else { throw MapLabFailure.invalidMap }
    return data
  }

  private func createPrivateDirectory(at url: URL) throws {
    if files.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { throw MapLabFailure.storageUnavailable }
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
    attributes[.protectionKey] = FileProtectionType.complete.rawValue as NSString
    #endif
    try files.setAttributes(attributes, ofItemAtPath: url.path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }

  private func perform<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch let error as MapLabFailure { throw error }
    catch is CancellationError { throw CancellationError() }
    catch { throw MapLabFailure.storageUnavailable }
  }

  private static func decodeWorldMap(_ bytes: Data) throws {
    #if os(iOS) && canImport(ARKit)
    guard !bytes.isEmpty, bytes.count <= MapLabBundle.maximumBytes,
      (try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes)) != nil
    else { throw MapLabFailure.invalidMap }
    #else
    // Unsupported hosts must explicitly inject a fixture validator to use maps.
    throw MapLabFailure.unsupported
    #endif
  }
}
