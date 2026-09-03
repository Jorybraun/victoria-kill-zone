import Foundation
import XCTest

@testable import VictoriaKillZone

final class ArenaShotTracerTests: XCTestCase {
  func testFireGateRequiresLockPoseAndCooldown() {
    var gate = ArenaTracerFireGate(cooldownMs: 400)
    XCTAssertEqual(
      gate.refusal(lockState: .aligning(.stabilizing), hasLocalPose: true, nowMs: 0),
      .spatialLockNotReady
    )
    XCTAssertEqual(
      gate.refusal(lockState: .trackingLost(.peerStale), hasLocalPose: true, nowMs: 0),
      .spatialLockNotReady
    )
    XCTAssertEqual(gate.refusal(lockState: .lockReady, hasLocalPose: false, nowMs: 0), .noLocalPose)
    XCTAssertNil(gate.refusal(lockState: .lockReady, hasLocalPose: true, nowMs: 0))

    XCTAssertEqual(gate.recordFire(nowMs: 1_000), 1)
    XCTAssertEqual(gate.refusal(lockState: .lockReady, hasLocalPose: true, nowMs: 1_399), .cooldown)
    XCTAssertNil(gate.refusal(lockState: .lockReady, hasLocalPose: true, nowMs: 1_400))
    XCTAssertEqual(gate.recordFire(nowMs: 1_400), 2)
    XCTAssertEqual(ArenaTracerFireGate.shotId(shooterPlayerId: "host-ab12", sequence: 2), "host-ab12#2")
  }

  func testDedupAdmitsEachIdentityOnceWithinABoundedWindow() {
    var dedup = ArenaTracerDedup(capacity: 2)
    XCTAssertTrue(dedup.admit("a"))
    XCTAssertFalse(dedup.admit("a"))
    XCTAssertTrue(dedup.admit("b"))
    XCTAssertTrue(dedup.admit("c"), "Evicts a")
    XCTAssertFalse(dedup.admit("b"))
    XCTAssertFalse(dedup.admit("c"))
    XCTAssertTrue(dedup.admit("a"), "Evicted identities are unknown again; the ledger, not dedup, bounds replay")
  }

  func testLedgerDrawsOneTracerPerIdentityAndDropsIncomingWhileUnlocked() throws {
    var ledger = ArenaTracerLedger()
    let shot = try tracer(id: "guest#1", at: 1_000)

    ledger.present(incoming: shot, lockState: .aligning(.awaitingMerge), nowMs: 1_010)
    XCTAssertEqual(ledger.droppedWhileUnlocked, 1)
    XCTAssertTrue(ledger.active.isEmpty)

    // The identity was consumed: a replay after lock must not draw it.
    ledger.present(incoming: shot, lockState: .lockReady, nowMs: 1_020)
    XCTAssertEqual(ledger.duplicatesIgnored, 1)
    XCTAssertEqual(ledger.incomingDrawn, 0)

    let second = try tracer(id: "guest#2", at: 1_100)
    ledger.present(incoming: second, lockState: .lockReady, nowMs: 1_110)
    ledger.present(incoming: second, lockState: .lockReady, nowMs: 1_120)
    XCTAssertEqual(ledger.incomingDrawn, 1)
    XCTAssertEqual(ledger.duplicatesIgnored, 2)
    XCTAssertEqual(ledger.active.map(\.shotId), ["guest#2"])
    XCTAssertEqual(ledger.active.first?.kind, .incoming)

    let own = try tracer(id: "host#1", at: 1_150)
    ledger.present(own: own, nowMs: 1_150)
    ledger.present(own: own, nowMs: 1_151)
    XCTAssertEqual(ledger.predictedDrawn, 1)
    XCTAssertEqual(ledger.active.count, 2)
    XCTAssertEqual(ledger.active.last?.kind, .predicted)
  }

  func testSegmentsSpanTheMaximumLaneAndExpireAfterDuration() throws {
    let shot = try ArenaShotTracer(
      shotId: "s",
      shooterPlayerId: "p",
      ray: ArenaShotRay(origin: ArenaVector3(x: 1, y: 1.5, z: 0), direction: ArenaVector3(x: 0, y: 0, z: -2), firedAtMs: 500)
    )
    let segment = ArenaTracerSegment(tracer: shot, kind: .predicted, spawnedAtMs: 500)
    XCTAssertEqual(segment.origin, ArenaVector3(x: 1, y: 1.5, z: 0))
    XCTAssertEqual(segment.end.z, -ArenaHitEvaluator.maximumLaneMeters, accuracy: 1e-9)
    XCTAssertTrue(segment.isAlive(nowMs: 500 + ArenaTracerSegment.durationMs - 1))
    XCTAssertFalse(segment.isAlive(nowMs: 500 + ArenaTracerSegment.durationMs))

    var ledger = ArenaTracerLedger()
    ledger.present(own: shot, nowMs: 500)
    ledger.present(own: try tracer(id: "t", at: 800), nowMs: 800)
    ledger.expire(nowMs: 900)
    XCTAssertEqual(ledger.active.map(\.shotId), ["t"])
  }

  func testTracerCodecRoundTripsAndRejectsBadRays() throws {
    let shot = try tracer(id: "host-1a2b#7", at: 1_700_000_000_000, direction: ArenaVector3(x: 3, y: 0, z: -4))
    let encoded = try ArenaShotTracerCodec.encode(shot)
    let decoded = try ArenaShotTracerCodec.decode(encoded)
    XCTAssertEqual(decoded, shot)
    XCTAssertEqual(decoded.ray.direction.length, 1, accuracy: 1e-12, "Direction is normalized on both ends")

    XCTAssertThrowsError(try ArenaShotTracerCodec.decode(encoded.dropLast()))
    XCTAssertThrowsError(try ArenaShotTracerCodec.decode(encoded + Data([1])))

    var zeroDirection = encoded
    let directionOffset = encoded.count - 3 * 8
    zeroDirection.replaceSubrange(directionOffset..<encoded.count, with: Data(count: 24))
    XCTAssertThrowsError(try ArenaShotTracerCodec.decode(zeroDirection)) { error in
      XCTAssertEqual(error as? ArenaPeerSampleCodecError, .invalidTransform(.invalidDirection))
    }
  }

  func testLinkCodecCarriesShotTracers() throws {
    let message = ArenaLinkMessage.shotTracer(try tracer(id: "guest-9f#3", at: 42))
    var buffer = try ArenaLinkCodec.encode(message)
    XCTAssertEqual(buffer[4], 6)
    XCTAssertEqual(try ArenaLinkCodec.drainFrames(from: &buffer), [message])
    XCTAssertTrue(buffer.isEmpty)
  }

  private func tracer(
    id: String,
    at firedAtMs: Int64,
    direction: ArenaVector3 = ArenaVector3(x: 0, y: 0, z: -1)
  ) throws -> ArenaShotTracer {
    ArenaShotTracer(
      shotId: id,
      shooterPlayerId: String(id.split(separator: "#").first ?? "p"),
      ray: try ArenaShotRay(origin: ArenaVector3(x: 0.2, y: 1.4, z: 0.1), direction: direction, firedAtMs: firedAtMs)
    )
  }
}
