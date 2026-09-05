import Foundation
import XCTest

@testable import VictoriaKillZone

final class ArenaLinkAuthenticatorTests: XCTestCase {
  func testMutualProofsVerifyWithSharedKey() {
    let key = Data("shared-key".utf8)
    let host = ArenaLinkAuthenticator(
      preSharedKey: key,
      role: .host,
      localNonce: Data(repeating: 1, count: ArenaLinkAuthenticator.nonceLength)
    )
    let guest = ArenaLinkAuthenticator(
      preSharedKey: key,
      role: .guest,
      localNonce: Data(repeating: 2, count: ArenaLinkAuthenticator.nonceLength)
    )

    XCTAssertTrue(guest.verify(
      peerProof: host.proof(peerNonce: guest.localNonce),
      peerNonce: host.localNonce
    ))
    XCTAssertTrue(host.verify(
      peerProof: guest.proof(peerNonce: host.localNonce),
      peerNonce: guest.localNonce
    ))
  }

  func testWrongKeyFails() {
    let host = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .host,
      localNonce: Data(repeating: 1, count: ArenaLinkAuthenticator.nonceLength)
    )
    let guest = ArenaLinkAuthenticator(
      preSharedKey: Data("different-key".utf8),
      role: .guest,
      localNonce: Data(repeating: 2, count: ArenaLinkAuthenticator.nonceLength)
    )

    XCTAssertFalse(guest.verify(
      peerProof: host.proof(peerNonce: guest.localNonce),
      peerNonce: host.localNonce
    ))
  }

  func testReflectedProofFails() {
    let host = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .host,
      localNonce: Data(repeating: 1, count: ArenaLinkAuthenticator.nonceLength)
    )
    let guest = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .guest,
      localNonce: Data(repeating: 2, count: ArenaLinkAuthenticator.nonceLength)
    )

    XCTAssertFalse(host.verify(
      peerProof: host.proof(peerNonce: guest.localNonce),
      peerNonce: guest.localNonce
    ))
    XCTAssertFalse(host.verify(
      peerProof: host.proof(peerNonce: host.localNonce),
      peerNonce: host.localNonce
    ))
  }

  func testSameRoleFails() {
    let firstHost = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .host,
      localNonce: Data(repeating: 1, count: ArenaLinkAuthenticator.nonceLength)
    )
    let secondHost = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .host,
      localNonce: Data(repeating: 2, count: ArenaLinkAuthenticator.nonceLength)
    )

    XCTAssertFalse(secondHost.verify(
      peerProof: firstHost.proof(peerNonce: secondHost.localNonce),
      peerNonce: firstHost.localNonce
    ))
  }

  func testProofLengthAndNonceLength() {
    let authenticator = ArenaLinkAuthenticator(
      preSharedKey: Data("shared-key".utf8),
      role: .host,
      localNonce: Data(repeating: 1, count: ArenaLinkAuthenticator.nonceLength)
    )
    let peerNonce = Data(repeating: 2, count: ArenaLinkAuthenticator.nonceLength)

    XCTAssertEqual(authenticator.proof(peerNonce: peerNonce).count, ArenaLinkAuthenticator.proofLength)
    XCTAssertEqual(ArenaLinkAuthenticator.randomNonce().count, ArenaLinkAuthenticator.nonceLength)
    XCTAssertNotEqual(ArenaLinkAuthenticator.randomNonce(), ArenaLinkAuthenticator.randomNonce())
  }
}
