import Foundation
import XCTest

@testable import CombatTransport

final class MatchScopeTests: XCTestCase {
  func testScopeAndTXTEntriesAreDeterministicAndScoped() {
    let scope = MatchScope(matchId: "match-a")
    XCTAssertEqual(scope.scopeId.count, 32)
    XCTAssertTrue(scope.scopeId.allSatisfy {
      ("0"..."9").contains($0) || ("a"..."f").contains($0)
    })
    XCTAssertNotEqual(scope.scopeId, MatchScope(matchId: "match-b").scopeId)
    XCTAssertEqual(scope.serviceToken, "vkz-\(scope.scopeId)")
    XCTAssertTrue(scope.accepts(txtEntries: scope.txtEntries.merging(["extra": "ok"]) { _, new in new }))
    XCTAssertFalse(scope.accepts(txtEntries: [MatchScope.txtMatchKey: scope.scopeId]))
    XCTAssertFalse(scope.accepts(txtEntries: [
      MatchScope.txtMatchKey: "wrong",
      MatchScope.txtProtocolKey: MatchScope.protocolVersion,
    ]))
    XCTAssertFalse(scope.accepts(txtEntries: [
      MatchScope.txtMatchKey: scope.scopeId,
      MatchScope.txtProtocolKey: "wrong",
    ]))
  }

  func testPSKChangesWithMatchAndJoinSecret() {
    let scope = MatchScope(matchId: "match-a")
    XCTAssertEqual(scope.preSharedKey(joinSecret: "1234").count, 32)
    XCTAssertNotEqual(
      scope.preSharedKey(joinSecret: "1234"),
      scope.preSharedKey(joinSecret: "5678")
    )
    XCTAssertNotEqual(
      scope.preSharedKey(joinSecret: "1234"),
      MatchScope(matchId: "match-b").preSharedKey(joinSecret: "1234")
    )
  }

  func testMatchHelloCodecIsStrict() throws {
    let hello = MatchHello(
      scopeId: "0123456789abcdef0123456789abcdef",
      playerId: "player",
      protocolVersion: MatchScope.protocolVersion
    )
    let encoded = try MatchHelloCodec.encode(hello)
    XCTAssertEqual(try MatchHelloCodec.decode(encoded), hello)
    XCTAssertThrowsError(try MatchHelloCodec.decode(encoded.dropLast()))
    XCTAssertThrowsError(try MatchHelloCodec.decode(encoded + Data([0])))
    XCTAssertThrowsError(try MatchHelloCodec.decode(Data([99])))
    XCTAssertThrowsError(try MatchHelloCodec.encode(MatchHello(
      scopeId: String(repeating: "x", count: 65),
      playerId: "player",
      protocolVersion: MatchScope.protocolVersion
    )))
  }

  func testWrongMatchPSKRejectsSlotClaimWhileMatchingPSKBounds() throws {
    let hostScope = MatchScope(matchId: "A")
    let otherScope = MatchScope(matchId: "B")
    var host = try PeerLinkStateMachine(
      role: .host,
      localSlot: 0,
      playerCount: 2,
      preSharedKey: hostScope.preSharedKey(joinSecret: "1234")
    )
    try host.acceptConnection(.init(1))
    let wrongClaim = PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: otherScope.preSharedKey(joinSecret: "1234"),
      nonce: 1,
      claimedSlot: 1
    )
    guard case .rejected(_, .authenticationFailed) = try host.receive(
      .slotClaim(wrongClaim),
      on: .init(1)
    ).first
    else {
      return XCTFail("wrong match should be rejected")
    }

    try host.acceptConnection(.init(2))
    let wrongSecretClaim = PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: hostScope.preSharedKey(joinSecret: "5678"),
      nonce: 2,
      claimedSlot: 1
    )
    guard case .rejected(_, .authenticationFailed) = try host.receive(
      .slotClaim(wrongSecretClaim),
      on: .init(2)
    ).first
    else {
      return XCTFail("wrong join secret should be rejected")
    }

    var matchingHost = try PeerLinkStateMachine(
      role: .host,
      localSlot: 0,
      playerCount: 2,
      preSharedKey: hostScope.preSharedKey(joinSecret: "1234")
    )
    try matchingHost.acceptConnection(.init(1))
    let matchingClaim = PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: hostScope.preSharedKey(joinSecret: "1234"),
      nonce: 1,
      claimedSlot: 1
    )
    XCTAssertEqual(
      try matchingHost.receive(.slotClaim(matchingClaim), on: .init(1)),
      [.bound(connection: .init(1), slot: 1)]
    )
  }
}
