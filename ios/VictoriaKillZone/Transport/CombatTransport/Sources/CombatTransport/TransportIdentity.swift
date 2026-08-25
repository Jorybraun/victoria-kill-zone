import Foundation
import Network
import Security

/// TLS credential for the QUIC peer session.
///
/// The pre-shared key authenticates slot claims at the application layer only;
/// it is never used as a TLS credential. Network.framework QUIC rejects an
/// external PSK (`-9858`), so the session is authenticated by a certificate
/// identity supplied by the embedding app and pinned by public key on clients.
public protocol TransportIdentityProvider: Sendable {
  /// Host-side identity presented during the QUIC handshake.
  func localIdentity() -> sec_identity_t?
  /// Public-key bytes (`SecKeyCopyExternalRepresentation`) clients pin.
  var pinnedPublicKey: Data { get }
}

public enum TransportSecurity {
  public static func publicKeyBytes(of certificate: SecCertificate) -> Data? {
    guard let key = SecCertificateCopyKey(certificate),
          let rep = SecKeyCopyExternalRepresentation(key, nil) as Data?
    else { return nil }
    return rep
  }

  static func applyHostIdentity(
    _ provider: TransportIdentityProvider,
    to options: NWProtocolQUIC.Options
  ) {
    guard let identity = provider.localIdentity() else { return }
    sec_protocol_options_set_local_identity(
      options.securityProtocolOptions,
      identity
    )
  }

  /// Pins the host's public key. Any other chain fails the handshake; there is
  /// deliberately no accept-anything path.
  static func applyClientPinning(
    _ provider: TransportIdentityProvider,
    to options: NWProtocolQUIC.Options,
    queue: DispatchQueue
  ) {
    let expected = provider.pinnedPublicKey
    sec_protocol_options_set_verify_block(
      options.securityProtocolOptions,
      { _, trustRef, complete in
        let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let presented = publicKeyBytes(of: leaf)
        else { return complete(false) }
        complete(presented == expected)
      },
      queue
    )
  }
}
