import XCTest

@testable import VictoriaKillZone

final class DuelInviteLinkTests: XCTestCase {
  func testURLRoundTripsThroughCode() {
    let url = DuelInviteLink.url(for: "ABC123")

    XCTAssertEqual(DuelInviteLink.code(from: url), "ABC123")
    XCTAssertEqual(DuelInviteLink.code(from: url.absoluteString), "ABC123")
  }

  func testLowercaseURLNormalizesCode() {
    XCTAssertEqual(DuelInviteLink.code(from: "pewpew://join/abc123"), "ABC123")
  }

  func testRawCodePayloadWorks() {
    XCTAssertEqual(DuelInviteLink.code(from: "abc123"), "ABC123")
  }

  func testInvalidPayloadsAreRejected() {
    XCTAssertNil(DuelInviteLink.code(from: "https://join/ABC123"))
    XCTAssertNil(DuelInviteLink.code(from: "pewpew://other/ABC123"))
    XCTAssertNil(DuelInviteLink.code(from: "pewpew://join/ABCDE"))
    XCTAssertNil(DuelInviteLink.code(from: ""))
  }

  @MainActor
  func testOpenInviteLinkFromHomeShowsJoinForm() {
    let store = LobbyStore(environment: .phaseZeroShell)

    store.openInviteLink(DuelInviteLink.url(for: "ABC123"))

    XCTAssertEqual(store.joinCode, "ABC123")
    XCTAssertEqual(store.route, .join)
  }
}
