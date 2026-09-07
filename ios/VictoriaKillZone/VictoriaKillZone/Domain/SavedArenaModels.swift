import Foundation

struct SavedArenaSummary: Codable, Equatable, Sendable {
  let id: UUID
  let name: String
  let createdAt: Date
  let frameID: String
  let byteCount: Int

  var isValid: Bool {
    !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
      && name.count <= 60 && createdAt.timeIntervalSince1970.isFinite
      && (1...DuelFrameMap.maximumBytes).contains(byteCount)
      && frameID.utf8.count == 64
      && frameID.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

/// Contains only the immutable scan. Alignment, readiness and match credentials
/// are deliberately absent; callers supply the new match's current epoch.
struct SavedArenaBundle: Equatable, Sendable {
  let summary: SavedArenaSummary
  let bytes: Data

  /// The store securely decodes the AR archive off the main actor on save/load.
  /// This reconstructs the bounded transport value without restoring old proof.
  func map(epoch: UInt16) throws -> DuelFrameMap {
    guard summary.isValid, bytes.count == summary.byteCount else { throw SavedArenaFailure.invalidArena }
    let map: DuelFrameMap
    do { map = try DuelFrameMap(epoch: epoch, bytes: bytes, expectedFrameID: summary.frameID) }
    catch DuelFrameFailure.invalidEpoch { throw DuelFrameFailure.invalidEpoch }
    catch { throw SavedArenaFailure.invalidArena }
    guard map.reference != nil else { throw SavedArenaFailure.incompatibleArena }
    return map
  }
}

protocol SavedArenaStoring: Sendable {
  func list() async throws -> [SavedArenaSummary]
  func save(name: String, bytes: Data) async throws -> SavedArenaBundle
  func load(id: UUID) async throws -> SavedArenaBundle
  func delete(id: UUID) async throws
}

enum SavedArenaFailure: Error, Equatable, Sendable, LocalizedError {
  case invalidName, libraryFull, arenaTooLarge, invalidArena, incompatibleArena, notFound, storageUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidName: "Give this arena a name of up to 60 characters."
    case .libraryFull: "Your phone already has 12 saved arenas. Delete one before saving another."
    case .arenaTooLarge: "This scan is too large to save. Scan a smaller area and try again."
    case .invalidArena: "This arena could not be read. Delete it and scan the room again."
    case .incompatibleArena: "This arena is not compatible. Scan the room again on this phone."
    case .notFound: "This saved arena is no longer on this phone. Choose another or scan the room again."
    case .storageUnavailable: "Saved arenas are unavailable. Unlock your phone, check its free space, and try again."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .invalidName: "Use a short name so you can recognize this room later."
    case .libraryFull: "Deleting a saved arena removes only the copy on this phone."
    case .arenaTooLarge, .invalidArena, .incompatibleArena: "Return to Saved Arenas and scan this room again."
    case .notFound: "Return to Saved Arenas and choose an available arena."
    case .storageUnavailable: "Try again when local storage is available."
    }
  }
}
