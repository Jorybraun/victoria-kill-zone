import Foundation
import XCTest

@testable import CombatTransport

final class CombatFireMessageCodecTests: XCTestCase {
  func testShotAndRetractionRoundTrip() throws {
    let shot = try CombatShotEvent(
      shotId: "shot-1",
      shooterPlayerId: "player-1",
      origin: SIMD3<Float>(1, 2, 3),
      direction: SIMD3<Float>(0, 0, -1),
      firedAtMs: 42
    )
    let encodedShot = try CombatFireMessageCodec.encode(.shot(shot))
    XCTAssertLessThan(encodedShot.count, TransportFrameCodec.maxPayloadLength)
    XCTAssertEqual(try CombatFireMessageCodec.decode(encodedShot), .shot(shot))

    let maximumShot = try CombatShotEvent(
      shotId: String(repeating: "s", count: 64),
      shooterPlayerId: String(repeating: "p", count: 64),
      origin: .zero,
      direction: SIMD3<Float>(0, 0, -1),
      firedAtMs: 42
    )
    XCTAssertEqual(
      try CombatFireMessageCodec.encode(.shot(maximumShot)).count,
      CombatFireMessageCodec.maxEncodedShotLength
    )

    let retraction = CombatShotRetraction(shotId: "shot-1")
    let encodedRetraction = try CombatFireMessageCodec.encode(.retracted(retraction))
    XCTAssertEqual(
      try CombatFireMessageCodec.decode(encodedRetraction),
      .retracted(retraction)
    )
  }

  func testCodecRejectsMalformedValues() throws {
    let shot = try CombatShotEvent(
      shotId: "shot-1",
      shooterPlayerId: "player-1",
      origin: SIMD3<Float>(1, 2, 3),
      direction: SIMD3<Float>(0, 0, -1),
      firedAtMs: 42
    )
    let encoded = try CombatFireMessageCodec.encode(.shot(shot))
    XCTAssertThrowsError(try CombatFireMessageCodec.decode(encoded.dropLast()))
    XCTAssertThrowsError(try CombatFireMessageCodec.decode(encoded + Data([0])))
    XCTAssertThrowsError(try CombatFireMessageCodec.decode(Data([99])))

    var nonFinite = encoded
    nonFinite.replaceSubrange(3..<7, with: Data([0, 0, 128, 127]))
    XCTAssertThrowsError(try CombatFireMessageCodec.decode(nonFinite))

    XCTAssertThrowsError(try CombatShotEvent(
      shotId: "",
      shooterPlayerId: "player-1",
      origin: .zero,
      direction: SIMD3<Float>(0, 0, -1),
      firedAtMs: 1
    ))
    XCTAssertThrowsError(try CombatShotEvent(
      shotId: "shot-1",
      shooterPlayerId: "player-1",
      origin: .zero,
      direction: .zero,
      firedAtMs: 1
    ))
  }
}
