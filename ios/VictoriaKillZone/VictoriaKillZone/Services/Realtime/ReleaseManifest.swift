import Foundation

/// The client-compiled copy of release-manifest.json. scripts/ci/check-release-manifest.mjs
/// fails when any literal here drifts from the committed manifest.
enum ReleaseManifest {
  static let protocolVersion = 1
  static let rulesSchemaHash = "3d92c5b99943eb6705b2c0fc52e5c13d4841be2d38ee93c346f0834631e9d674"
  static let doClass = "CombatRoom"
  static let doMigrationTag = "v1"
  static let iosMinProtocol = 1
  static let iosMaxProtocol = 1
  static let convexMinProtocol = 1
  static let workerVersionTag = "vkz-combat-2026.09"
  static let releaseSha = "0000000000000000000000000000000000000000"

  /// Wire shape of the manifest the worker echoes in snapshots and /health.
  struct Summary: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var rulesSchemaHash: String
    var doClass: String
    var doMigrationTag: String
    var iosMinProtocol: Int
    var iosMaxProtocol: Int
    var convexMinProtocol: Int
    var workerVersionTag: String
    var releaseSha: String
  }
  static let summary = Summary(
    protocolVersion: protocolVersion, rulesSchemaHash: rulesSchemaHash, doClass: doClass,
    doMigrationTag: doMigrationTag, iosMinProtocol: iosMinProtocol, iosMaxProtocol: iosMaxProtocol,
    convexMinProtocol: convexMinProtocol, workerVersionTag: workerVersionTag, releaseSha: releaseSha)
}

/// One observed (authorityEpoch, frameEpoch) transition, newest last.
struct AuthorityEpochRecord: Encodable, Equatable, Sendable {
  var authorityEpoch: Int
  var frameEpoch: Int
  var eventSequence: Int
  var observedAtMs: Double
}
