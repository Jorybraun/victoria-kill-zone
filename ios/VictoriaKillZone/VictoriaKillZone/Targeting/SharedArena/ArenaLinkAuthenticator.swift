import CryptoKit
import Foundation

/// Mutual PSK challenge-response for the TCP fallback before any
/// `ArenaLinkMessage` is accepted.
struct ArenaLinkAuthenticator: Sendable {
  static let nonceLength = 32
  static let proofLength = 32
  private static let domain = Data("vkz-arena-tcp-auth-1".utf8)

  let localNonce: Data
  private let key: SymmetricKey
  private let role: ArenaRole

  init(
    preSharedKey: Data,
    role: ArenaRole,
    localNonce: Data = ArenaLinkAuthenticator.randomNonce()
  ) {
    precondition(localNonce.count == Self.nonceLength)
    key = SymmetricKey(data: preSharedKey)
    self.role = role
    self.localNonce = localNonce
  }

  static func randomNonce() -> Data {
    Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max) })
  }

  func proof(peerNonce: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(
      for: message(role: role, localNonce: localNonce, peerNonce: peerNonce),
      using: key
    ))
  }

  func verify(peerProof: Data, peerNonce: Data) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(
      peerProof,
      authenticating: message(
        role: role == .host ? .guest : .host,
        localNonce: peerNonce,
        peerNonce: localNonce
      ),
      using: key
    )
  }

  private func message(
    role: ArenaRole,
    localNonce: Data,
    peerNonce: Data
  ) -> Data {
    var data = Self.domain
    data.append(role == .host ? 1 : 2)
    data.append(localNonce)
    data.append(peerNonce)
    return data
  }
}
