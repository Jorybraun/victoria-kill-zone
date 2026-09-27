import Foundation
import XCTest
@testable import VictoriaKillZone

/// Round-trips contracts/fixtures/combat.v1.json through the production wire
/// types so the iOS codec cannot drift from the shared contract.
final class CombatContractFixtureTests: XCTestCase {
  private func fixtureData() throws -> Data {
    // #filePath: ios/VictoriaKillZone/VictoriaKillZoneTests/CombatContractFixtureTests.swift
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<3 {directory.deleteLastPathComponent()}
    return try Data(contentsOf: directory.appendingPathComponent("contracts/fixtures/combat.v1.json"))
  }
  private func dictionary(_ value: Any) throws -> [String: Any] {
    guard let result = value as? [String: Any] else {throw XCTSkip("fixture shape changed")}
    return result
  }
  /// Canonicalizes fixture JSON for NSDictionary comparison: numbers compare
  /// numerically across int/double, and explicit nulls are dropped because the
  /// production encoder omits absent optional keys.
  private func canonical(_ value: Any) -> Any {
    if value is NSNull {return NSNull()}
    if let object = value as? [String: Any] {
      return object.reduce(into: [String: Any]()) {result, pair in
        let v = canonical(pair.value)
        if !(v is NSNull) {result[pair.key] = v}
      }
    }
    if let array = value as? [Any] {return array.map(canonical)}
    return value
  }
  private func command(_ object: [String: Any]) throws -> CombatWire.Command {
    switch object["kind"] as? String {
    case "start": return .start
    case "reload": return .reload
    case "leave": return .leave
    case "fire":
      let observation = object["observation"] as? [String: Any]
      return .fire(
        shotId: object["shotId"] as! String,
        poseSequence: (object["poseSequence"] as! NSNumber).intValue,
        origin: object["origin"] as! [Double],
        direction: object["direction"] as! [Double],
        observation: observation.map {o in CombatWire.Observation(
          targetPlayerId: o["targetPlayerId"] as! String,
          capturedAtMs: (o["capturedAtMs"] as! NSNumber).doubleValue,
          associationConfidence: (o["associationConfidence"] as! NSNumber).doubleValue,
          uncertaintyMeters: (o["uncertaintyMeters"] as! NSNumber).doubleValue,
          colliders: (o["colliders"] as! [[String: Any]]).map {c in CombatWire.Collider(
            id: c["id"] as! String, kind: c["kind"] as! String,
            zone: HitZone(rawValue: c["zone"] as! String)!,
            center: c["center"] as? [Double], a: c["a"] as? [Double], b: c["b"] as? [Double],
            radius: (c["radius"] as! NSNumber).doubleValue)})})
    case "frameReady":
      return .frameReady(
        ready: object["ready"] as! Bool,
        residualMeters: (object["residualMeters"] as! NSNumber).doubleValue,
        residualDegrees: (object["residualDegrees"] as! NSNumber).doubleValue,
        clockUncertaintyMs: (object["clockUncertaintyMs"] as! NSNumber).doubleValue)
    case "shield":
      return .shield(active: object["active"] as! Bool, poseSequence: (object["poseSequence"] as! NSNumber).intValue)
    case "slowField":
      return .slowField(poseSequence: (object["poseSequence"] as! NSNumber).intValue)
    default:
      XCTFail("unhandled fixture command kind \(object["kind"] ?? "?")")
      return .leave
    }
  }
  func testSnapshotDecodesThroughTheProductionDecoder() throws {
    let fixture = try JSONSerialization.jsonObject(with: fixtureData()) as! [String: Any]
    let snapshot = try dictionary(fixture["snapshot"] as Any)
    let message = try JSONSerialization.data(withJSONObject: snapshot["message"] as Any)
    guard case .snapshot(let wire, let eventSequence, let clientSequence) =
      try JSONDecoder().decode(CombatWire.ServerMessage.self, from: message) else {
      return XCTFail("snapshot message did not decode as .snapshot")
    }
    XCTAssertEqual(eventSequence, 0)
    XCTAssertEqual(clientSequence, 0)
    XCTAssertEqual(wire.matchId, "fixture-match")
    XCTAssertEqual(wire.authorityEpoch, 1)
    XCTAssertEqual(wire.frameEpoch, 1)
    XCTAssertEqual(wire.phase, .calibrating)
    XCTAssertNil(wire.roundStartedAtMs)
    XCTAssertEqual(wire.rules.geometry, "sighting")
    XCTAssertEqual(wire.players.map(\.playerId), ["p-guest", "p-host"])
    XCTAssertEqual(wire.players[0].role, "player")
    XCTAssertFalse(wire.players[0].connected)
    XCTAssertEqual(wire.players[1].role, "host")
    XCTAssertTrue(wire.players[1].connected)
    XCTAssertTrue(wire.projectiles.isEmpty)
    XCTAssertTrue(wire.slowFields.isEmpty)
    XCTAssertTrue(wire.phonePoses.isEmpty)
  }
  func testCommandEnvelopesEncodeToTheFixtureWireShape() throws {
    let fixture = try JSONSerialization.jsonObject(with: fixtureData()) as! [String: Any]
    let protocolVersion = (fixture["protocolVersion"] as! NSNumber).intValue
    for entry in fixture["envelopes"] as! [[String: Any]] {
      let message = try dictionary(entry["message"] as Any)
      let expected = try dictionary(message["envelope"] as Any)
      let envelope = CombatWire.Envelope(
        commandId: expected["commandId"] as! String,
        clientSequence: (expected["clientSequence"] as! NSNumber).intValue,
        authorityEpoch: (expected["authorityEpoch"] as! NSNumber).intValue,
        frameEpoch: (expected["frameEpoch"] as! NSNumber).intValue,
        sentAtMs: (expected["sentAtMs"] as! NSNumber).doubleValue,
        command: try command(expected["command"] as! [String: Any]))
      XCTAssertEqual(envelope.v, protocolVersion, "\(entry["id"] ?? "?")")
      let encoded = try JSONEncoder().encode(envelope)
      let actual = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
      XCTAssertEqual(actual as NSDictionary, canonical(expected) as! NSDictionary, "\(entry["id"] ?? "?")")
    }
  }
}
