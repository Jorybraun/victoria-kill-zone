import CryptoKit
import Foundation

/// Offline world-map experiments. This type cannot become a combat calibration
/// bundle and deliberately contains no player, epoch, pose or readiness state.
struct MapLabSummary: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let name: String
  let createdAt: Date
  let byteCount: Int
  let checksum: String

  var isValid: Bool {
    !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
      && name.count <= 60 && createdAt.timeIntervalSince1970.isFinite
      && (1...MapLabBundle.maximumBytes).contains(byteCount)
      && checksum.utf8.count == 64
      && checksum.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

struct MapLabBundle: Equatable, Sendable {
  static let maximumBytes = 8 * 1024 * 1024
  static let maximumMaps = 12
  let summary: MapLabSummary
  let bytes: Data

  func validate() throws {
    guard summary.isValid, bytes.count == summary.byteCount,
      bytes.count <= Self.maximumBytes, Self.checksum(bytes) == summary.checksum
    else { throw MapLabFailure.invalidMap }
  }

  static func checksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

protocol MapLabStoring: Sendable {
  func list() async throws -> [MapLabSummary]
  func save(name: String, bytes: Data) async throws -> MapLabBundle
  func load(id: UUID) async throws -> MapLabBundle
  func delete(id: UUID) async throws
}

enum MapLabFeedback: Equatable, Sendable {
  case starting, moveSlowly, findDetail, mapping, ready
}

enum MapLabSessionState: Equatable, Sendable {
  case idle, starting
  case scanning(feedback: MapLabFeedback, canSave: Bool)
  case recognizing, recognized, interrupted
  case failed(MapLabFailure)
}

/// Owns one camera session, exclusively, until awaited stop completes. A test
/// result means ARKit relocalized this phone; it is never multiplayer admission.
@MainActor
protocol MapLabDriving: AnyObject {
  var state: MapLabSessionState { get }
  var onStateChange: ((MapLabSessionState) -> Void)? { get set }
  func startCapture() async throws
  func startRecognition(bytes: Data) async throws
  func capture() async throws -> Data
  func stop() async
}

enum MapLabFailure: Error, Equatable, Sendable, LocalizedError {
  case unsupported, cameraDenied, interrupted, timedOut, notReady
  case invalidName, libraryFull, mapTooLarge, invalidMap, notFound, storageUnavailable

  var errorDescription: String? {
    switch self {
    case .unsupported: "Room scanning is unavailable on this device."
    case .cameraDenied: "Allow camera access in Settings to scan your surroundings."
    case .interrupted: "Scanning stopped. Restart when you are ready."
    case .timedOut: "This scan could not be recognized. Try the original location or make a new scan."
    case .notReady: "Move slowly around nearby details before saving."
    case .invalidName: "Give this scan a name of up to 60 characters."
    case .libraryFull: "Your phone has 12 saved scans. Delete one to save another."
    case .mapTooLarge: "This scan is too large. Try scanning a smaller area."
    case .invalidMap: "This scan could not be read. Delete it and scan again."
    case .notFound: "This scan is no longer on this phone."
    case .storageUnavailable: "Scans are unavailable. Unlock your phone, check its free space and try again."
    }
  }
}
