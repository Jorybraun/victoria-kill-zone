import Foundation
import XCTest
@testable import CombatTransport

final class SHA256DigestTests: XCTestCase {
  func testKnownAnswerVectors() {
    XCTAssertEqual(
      hex(SHA256Digest.portableHash(Data())),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    XCTAssertEqual(
      hex(SHA256Digest.portableHash(Data("abc".utf8))),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    XCTAssertEqual(
      hex(
        SHA256Digest.portableHash(
          Data(
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8
          )
        )
      ),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )
  }

  func testPortableHashMatchesPlatformHash() {
    let input = Data(repeating: 0x61, count: 200)
    XCTAssertEqual(SHA256Digest.portableHash(input), SHA256Digest.hash(input))
  }

  private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
