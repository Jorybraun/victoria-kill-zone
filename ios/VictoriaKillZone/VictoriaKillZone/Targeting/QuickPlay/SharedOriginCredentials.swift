import CryptoKit
import Foundation

/// Per-run authentication material. Never include this value in logs or evidence.
struct SharedOriginCredentials: Equatable, Sendable {
  let runID: UUID
  let joinSecret: String

  static func create() -> Self {try! Self(code: UUID().uuidString)}

  init(code: String) throws {
    guard let id = UUID(uuidString: code.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw SharedOriginFailure.invalidCode
    }
    joinSecret = id.uuidString.lowercased()
    // Public discovery scope is distinct from the manually shared random secret.
    let bytes = Array(SHA256.hash(data: Data(("vkz-shared-origin-v1:" + joinSecret).utf8)).prefix(16))
    runID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}
