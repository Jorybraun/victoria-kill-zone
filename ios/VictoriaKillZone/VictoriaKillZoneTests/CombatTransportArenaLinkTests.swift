import CombatTransport
import Foundation
import XCTest

@testable import VictoriaKillZone

final class CombatTransportArenaLinkTests: XCTestCase {
  func testBothAdaptersReachConnected() {
    let pair = makePair()
    let hostConnected = expectation(description: "host connected")
    let guestConnected = expectation(description: "guest connected")
    pair.host.onStateChange = { state in
      pair.hostRecorder.recordState(state)
      if state == .connected { hostConnected.fulfill() }
    }
    pair.guest.onStateChange = { state in
      pair.guestRecorder.recordState(state)
      if state == .connected { guestConnected.fulfill() }
    }

    pair.host.start(role: .host)
    pair.guest.start(role: .guest)
    pump(pair.fabric, until: {
      pair.hostRecorder.contains(state: .connected) &&
        pair.guestRecorder.contains(state: .connected)
    })

    wait(for: [hostConnected, guestConnected], timeout: 1)
    XCTAssertTrue(pair.hostRecorder.contains(state: .connected))
    XCTAssertTrue(pair.guestRecorder.contains(state: .connected))
  }

  func testShotsTravelInBothDirections() throws {
    let pair = makeConnectedPair()
    let hostShot = try tracer(shotId: "host#1", shooter: "host")
    let guestShot = try tracer(shotId: "guest#1", shooter: "guest")
    let hostMessage = expectation(description: "host receives guest shot")
    let guestMessage = expectation(description: "guest receives host shot")
    pair.host.onMessage = { message, _ in
      pair.hostRecorder.recordMessage(message)
      if pair.hostRecorder.containsShot(guestShot) { hostMessage.fulfill() }
    }
    pair.guest.onMessage = { message, _ in
      pair.guestRecorder.recordMessage(message)
      if pair.guestRecorder.containsShot(hostShot) { guestMessage.fulfill() }
    }

    pair.guest.send(.shotTracer(guestShot))
    pair.host.send(.shotTracer(hostShot))
    waitUntil {
      pair.guest.stats.bytesOut > 0 && pair.host.stats.bytesOut > 0
    }
    pump(pair.fabric, until: {
      pair.hostRecorder.containsShot(guestShot) &&
        pair.guestRecorder.containsShot(hostShot)
    })

    wait(for: [hostMessage, guestMessage], timeout: 1)
    XCTAssertTrue(pair.hostRecorder.containsShot(guestShot))
    XCTAssertTrue(pair.guestRecorder.containsShot(hostShot))
  }

  func testShotRetractionTravels() throws {
    let pair = makeConnectedPair()
    let received = expectation(description: "guest receives retraction")
    pair.guest.onMessage = { message, _ in
      pair.guestRecorder.recordMessage(message)
      if message == .shotRetracted(shotId: "host#1") { received.fulfill() }
    }

    pair.host.send(.shotRetracted(shotId: "host#1"))
    waitUntil { pair.host.stats.bytesOut > 0 }
    pump(pair.fabric, until: {
      pair.guestRecorder.contains(message: .shotRetracted(shotId: "host#1"))
    })

    wait(for: [received], timeout: 1)
    XCTAssertTrue(pair.guestRecorder.contains(message: .shotRetracted(shotId: "host#1")))
  }

  func testWorldMapArrivesByteIdentically() {
    let pair = makeConnectedPair()
    let worldMap = Data((0..<200 * 1024).map { UInt8($0 % 251) })
    let received = expectation(description: "guest receives world map")
    pair.guest.onMessage = { message, _ in
      pair.guestRecorder.recordMessage(message)
      if message == .worldMap(worldMap) { received.fulfill() }
    }

    pair.host.send(.worldMap(worldMap))
    waitUntil { pair.host.stats.bytesOut > 0 }
    pump(pair.fabric, until: {
      pair.guestRecorder.contains(message: .worldMap(worldMap))
    })

    wait(for: [received], timeout: 1)
    XCTAssertTrue(pair.guestRecorder.contains(message: .worldMap(worldMap)))
  }

  func testWrongMatchFailsHostAndDropsSubsequentMessages() throws {
    let fabric = LoopbackFabric(playerCount: 2)
    let hostRecorder = Recorder()
    let guestRecorder = Recorder()
    let host = CombatTransportArenaLink(
      matchId: "match",
      playerId: "host",
      joinSecret: "secret",
      linkFactory: { _ in fabric.host }
    )
    let guest = CombatTransportArenaLink(
      matchId: "other-match",
      playerId: "guest",
      joinSecret: "secret",
      linkFactory: { _ in fabric.client(slot: 1) }
    )
    host.onStateChange = { hostRecorder.recordState($0) }
    host.onMessage = { message, _ in hostRecorder.recordMessage(message) }
    guest.onStateChange = { guestRecorder.recordState($0) }
    guest.start(role: .guest)
    host.start(role: .host)
    pump(fabric, until: {
      hostRecorder.contains(state: .failed("peer belongs to another match"))
    })

    guest.send(.shotTracer(try tracer(shotId: "guest#1", shooter: "guest")))
    pump(fabric, until: { hostRecorder.messageCount > 0 || fabric.nowMs >= 500 })

    XCTAssertTrue(hostRecorder.contains(state: .failed("peer belongs to another match")))
    XCTAssertEqual(hostRecorder.messageCount, 0)
  }

  func testHappyPathStatsCountTransportBytesWithoutFramingErrors() throws {
    let pair = makeConnectedPair()
    let received = expectation(description: "host receives shot")
    pair.host.onMessage = { message, _ in
      pair.hostRecorder.recordMessage(message)
      if case .shotTracer = message { received.fulfill() }
    }
    pair.guest.send(.shotTracer(try tracer(shotId: "guest#1", shooter: "guest")))
    waitUntil { pair.guest.stats.bytesOut > 0 }
    pump(pair.fabric, until: { pair.hostRecorder.messageCount > 0 })
    wait(for: [received], timeout: 1)

    XCTAssertGreaterThan(pair.guest.stats.bytesOut, 0)
    XCTAssertGreaterThan(pair.host.stats.bytesIn, 0)
    XCTAssertEqual(pair.guest.stats.framingErrors, 0)
    XCTAssertEqual(pair.host.stats.framingErrors, 0)
  }

  private func makeConnectedPair() -> Pair {
    let pair = makePair()
    pair.host.start(role: .host)
    pair.guest.start(role: .guest)
    pump(pair.fabric, until: {
      pair.hostRecorder.contains(state: .connected) &&
        pair.guestRecorder.contains(state: .connected)
    })
    return pair
  }

  private func makePair() -> Pair {
    let fabric = LoopbackFabric(playerCount: 2)
    let hostRecorder = Recorder()
    let guestRecorder = Recorder()
    let host = CombatTransportArenaLink(
      matchId: "match",
      playerId: "host",
      joinSecret: "secret",
      linkFactory: { _ in fabric.host }
    )
    let guest = CombatTransportArenaLink(
      matchId: "match",
      playerId: "guest",
      joinSecret: "secret",
      linkFactory: { _ in fabric.client(slot: 1) }
    )
    host.onStateChange = { hostRecorder.recordState($0) }
    guest.onStateChange = { guestRecorder.recordState($0) }
    return Pair(
      fabric: fabric,
      host: host,
      guest: guest,
      hostRecorder: hostRecorder,
      guestRecorder: guestRecorder
    )
  }

  private func pump(
    _ fabric: LoopbackFabric,
    until predicate: @escaping () -> Bool
  ) {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !predicate() && Date() < deadline {
      fabric.advance(to: fabric.nowMs + 1)
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
  }

  private func tracer(shotId: String, shooter: String) throws -> ArenaShotTracer {
    ArenaShotTracer(
      shotId: shotId,
      shooterPlayerId: shooter,
      ray: try ArenaShotRay(
        origin: ArenaVector3(x: 0.2, y: 1.4, z: 0.1),
        direction: ArenaVector3(x: 0, y: 0, z: -1),
        firedAtMs: 42
      )
    )
  }

  private struct Pair {
    let fabric: LoopbackFabric
    let host: CombatTransportArenaLink
    let guest: CombatTransportArenaLink
    let hostRecorder: Recorder
    let guestRecorder: Recorder
  }

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ArenaPeerLinkState] = []
    private var messages: [ArenaLinkMessage] = []

    var messageCount: Int {
      lock.withLock { messages.count }
    }

    func recordState(_ state: ArenaPeerLinkState) {
      lock.withLock { states.append(state) }
    }

    func recordMessage(_ message: ArenaLinkMessage) {
      lock.withLock { messages.append(message) }
    }

    func contains(state: ArenaPeerLinkState) -> Bool {
      lock.withLock { states.contains(state) }
    }

    func contains(message: ArenaLinkMessage) -> Bool {
      lock.withLock { messages.contains(message) }
    }

    func containsShot(_ expected: ArenaShotTracer) -> Bool {
      lock.withLock {
        messages.contains { message in
          guard case let .shotTracer(actual) = message else { return false }
          return actual.shotId == expected.shotId &&
            actual.shooterPlayerId == expected.shooterPlayerId &&
            actual.firedAtMs == expected.firedAtMs &&
            abs(actual.ray.origin.x - expected.ray.origin.x) < 1e-6 &&
            abs(actual.ray.origin.y - expected.ray.origin.y) < 1e-6 &&
            abs(actual.ray.origin.z - expected.ray.origin.z) < 1e-6 &&
            abs(actual.ray.direction.x - expected.ray.direction.x) < 1e-6 &&
            abs(actual.ray.direction.y - expected.ray.direction.y) < 1e-6 &&
            abs(actual.ray.direction.z - expected.ray.direction.z) < 1e-6
        }
      }
    }
  }
}
