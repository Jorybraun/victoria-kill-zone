import Foundation
import XCTest

@testable import VictoriaKillZone

@MainActor
final class NearbyRendezvousTests: XCTestCase {
  private var clock: Date!
  private var driver: FakeNearbyDriver!
  private var coordinator: NearbyRendezvousCoordinator!

  override func setUp() async throws {
    clock = Date(timeIntervalSince1970: 1000)
    driver = FakeNearbyDriver()
    coordinator = NearbyRendezvousCoordinator(driver: driver, now: { [unowned self] in self.clock },
      retryFacingAfter: 0.05)
  }

  func testNilDriverReportsUnsupported() async {
    let coordinator = NearbyRendezvousCoordinator(driver: nil)
    await coordinator.start(peerIDs: ["p2"])
    XCTAssertEqual(coordinator.phase, .unsupported)
    XCTAssertTrue(coordinator.diagnostics.contains {$0.kind == "niSession" && $0.detail == "unsupported"})
  }

  func testDeniedPermissionSurfacesSettingsRecovery() async {
    driver.startError = NearbyRendezvousFailure.permissionDenied
    await coordinator.start(peerIDs: ["p2", "p3"])
    XCTAssertEqual(coordinator.phase, .permissionDenied)
    XCTAssertTrue(coordinator.needsSettings)
    XCTAssertTrue(coordinator.diagnostics.contains {$0.kind == "niPermission" && $0.detail == "denied"})
  }

  func testTokenExchangeAndRitualPhases() async throws {
    var localToken: Data?
    coordinator.onLocalToken = {localToken = $0}
    await coordinator.start(peerIDs: ["p2", "p3"])
    XCTAssertEqual(localToken, driver.localDiscoveryToken)
    XCTAssertEqual(coordinator.phase, .awaitingTokens(received: 0, expected: 2))

    coordinator.receivePeerToken(playerID: "p2", data: Data([1]))
    coordinator.receivePeerToken(playerID: "p3", data: Data([2]))
    XCTAssertEqual(driver.acceptedTokens.map(\.playerID), ["p2", "p3"])
    // Token acceptance alone does not leave awaitingTokens; the driver's
    // sessionState events are the signal that each NI session runs.
    XCTAssertEqual(coordinator.phase, .awaitingTokens(received: 0, expected: 2))

    driver.emit(.sessionState(playerID: "p2", state: .running))
    try await until {self.coordinator.phase == .awaitingTokens(received: 1, expected: 2)}
    driver.emit(.sessionState(playerID: "p3", state: .running))
    try await until {self.coordinator.phase == .pointing(solved: 0, expected: 2)}

    // The pointing window elapses with p3 still reporting no direction sample;
    // p2 has already ranged with direction, so only p3 is pending.
    driver.emit(.sample(.init(playerID: "p2", distanceMeters: 2.0, hasDirection: true, capturedAt: clock)))
    clock = clock.addingTimeInterval(1)
    try await until {
      if case .retryFacing(let pending) = self.coordinator.phase {return pending == 1}
      return false
    }

    driver.emit(.sample(.init(playerID: "p3", distanceMeters: 2.4, hasDirection: true, capturedAt: clock)))
    driver.emit(.sample(.init(playerID: "p2", distanceMeters: 2.1, hasDirection: true, capturedAt: clock)))
    driver.emit(.transformSolved(.init(playerID: "p2", residualMeters: 0.12, residualDegrees: 1.5, solvedAt: clock)))
    driver.emit(.transformSolved(.init(playerID: "p3", residualMeters: 0.2, residualDegrees: 2.0, solvedAt: clock)))
    try await until {self.coordinator.phase == .solved(count: 2)}
  }

  func testRosterChangesKeepSessionsInStep() async {
    await coordinator.start(peerIDs: ["p2"])
    coordinator.updatePeers(["p2", "p4"])
    XCTAssertEqual(Set(coordinator.peers.keys), ["p2", "p4"])
    coordinator.updatePeers(["p4"])
    XCTAssertEqual(driver.removedPeers, ["p2"])
    XCTAssertEqual(Set(coordinator.peers.keys), ["p4"])
  }

  func testDerivePhaseIsPure() {
    let now = Date()
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: [:], startedPointingAt: nil,
      now: now, retryAfter: 3), .awaitingTokens(received: 0, expected: 0))
    var peers = ["a": NearbyPeerStatus(), "b": NearbyPeerStatus()]
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers, startedPointingAt: nil,
      now: now, retryAfter: 3), .awaitingTokens(received: 0, expected: 2))
    for state in [NearbyPeerSessionState.idle, .suspended, .invalidated] {
      peers["a"]?.sessionState = state
      XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers, startedPointingAt: nil,
        now: now, retryAfter: 3), .awaitingTokens(received: 0, expected: 2),
        "\(state) must not count toward received")
    }
    peers["a"]?.sessionState = .running
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers, startedPointingAt: nil,
      now: now, retryAfter: 3), .awaitingTokens(received: 1, expected: 2))
    peers["b"]?.sessionState = .running
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers, startedPointingAt: now,
      now: now, retryAfter: 3), .pointing(solved: 0, expected: 2))
    peers["a"]?.directionSamples = 2
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers,
      startedPointingAt: now.addingTimeInterval(-4), now: now, retryAfter: 3), .retryFacing(pending: 1))
    peers["b"]?.solution = NearbyTransformSolution(playerID: "b", residualMeters: 0.1,
      residualDegrees: 1, solvedAt: now)
    peers["a"]?.solution = NearbyTransformSolution(playerID: "a", residualMeters: 0.1,
      residualDegrees: 1, solvedAt: now)
    XCTAssertEqual(NearbyRendezvousCoordinator.derivePhase(peers: peers, startedPointingAt: now,
      now: now, retryAfter: 3), .solved(count: 2))
  }

  func testDiagnosticsNeverContainPlayerIDs() async throws {
    await coordinator.start(peerIDs: ["alpha-player", "bravo-player"])
    coordinator.receivePeerToken(playerID: "alpha-player", data: Data([1]))
    driver.emit(.sessionState(playerID: "alpha-player", state: .running))
    for _ in 0..<10 {
      driver.emit(.sample(.init(playerID: "alpha-player", distanceMeters: 2,
        hasDirection: true, capturedAt: clock)))
    }
    driver.emit(.transformSolved(.init(playerID: "alpha-player", residualMeters: 0.1,
      residualDegrees: 1, solvedAt: clock)))
    try await until {self.coordinator.diagnostics.contains {$0.kind == "niTransform"}}
    for event in coordinator.diagnostics {
      XCTAssertFalse(event.detail.contains("alpha-player"))
      XCTAssertFalse(event.detail.contains("bravo-player"))
    }
  }

  func testExportSetupLogAppendsAfterFrameEvents() async throws {
    await coordinator.start(peerIDs: ["p2"])
    let frameEvent = DuelFrameDiagnosticEvent(elapsedMs: 5, kind: "frame", detail: "frame-detail")
    let encoder = JSONEncoder()
    let frameURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frame-\(UUID().uuidString).json")
    try encoder.encode([frameEvent]).write(to: frameURL)
    let merged = try coordinator.exportSetupLog(merging: frameURL)
    let events = try JSONDecoder().decode([DuelFrameDiagnosticEvent].self,
      from: Data(contentsOf: merged))
    XCTAssertEqual(events.first, frameEvent)
    XCTAssertGreaterThan(events.count, 1)
    XCTAssertTrue(events.dropFirst().allSatisfy {$0.kind.hasPrefix("ni")})
    let permissions = try FileManager.default.attributesOfItem(atPath: merged.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }

  func testExportSetupLogThrowsOnUndecodableFrameLog() async throws {
    await coordinator.start(peerIDs: ["p2"])
    let frameURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("frame-\(UUID().uuidString).json")
    try Data("not json".utf8).write(to: frameURL)
    XCTAssertThrowsError(try coordinator.exportSetupLog(merging: frameURL))
  }

  func testStaleStartCannotPublishAfterStop() async {
    driver.suspendStart = true
    var localToken: Data?
    coordinator.onLocalToken = {localToken = $0}
    let startTask = Task {await coordinator.start(peerIDs: ["p2"])}
    try? await Task.sleep(for: .milliseconds(50))
    await coordinator.stop()
    driver.resumeStart()
    await startTask.value
    XCTAssertEqual(coordinator.phase, .inactive)
    XCTAssertNil(localToken)
    XCTAssertFalse(coordinator.diagnostics.contains {$0.detail == "start"})
  }

  func testSessionInvalidationSurfacesRetryNotSettings() async throws {
    await coordinator.start(peerIDs: ["p2"])
    driver.emit(.failed(.sessionInvalidated))
    try await until {self.coordinator.phase == .sessionLost}
    XCTAssertFalse(coordinator.needsSettings)
    await coordinator.retry()
    XCTAssertEqual(driver.startCalls, 2)
    try await until {self.coordinator.phase == .awaitingTokens(received: 0, expected: 1)}
  }

  func testFailedStartMapsSessionInvalidationToSessionLost() async {
    driver.startError = NearbyRendezvousFailure.sessionInvalidated
    await coordinator.start(peerIDs: ["p2"])
    XCTAssertEqual(coordinator.phase, .sessionLost)
    XCTAssertFalse(coordinator.needsSettings)
  }

  func testStopClearsSessionButKeepsDiagnostics() async {
    await coordinator.start(peerIDs: ["p2"])
    XCTAssertFalse(coordinator.diagnostics.isEmpty)
    await coordinator.stop()
    XCTAssertEqual(coordinator.phase, .inactive)
    XCTAssertTrue(coordinator.peers.isEmpty)
    XCTAssertEqual(driver.stopCalls, 1)
    XCTAssertFalse(coordinator.diagnostics.isEmpty)
  }

  private func until(timeout: TimeInterval = 2, file: StaticString = #filePath,
    line: UInt = #line, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {try await Task.sleep(for: .milliseconds(10))}
    XCTAssertTrue(predicate(), "Expected rendezvous state did not arrive", file: file, line: line)
    if !predicate() {throw NearbyRendezvousFailure.sessionInvalidated}
  }
}

@MainActor
private final class FakeNearbyDriver: NearbyRendezvousDriving {
  var localDiscoveryToken: Data? = Data([1, 2, 3])
  var startError: Error?
  var acceptedTokens: [(playerID: String, data: Data)] = []
  var removedPeers: [String] = []
  var startCalls = 0
  var stopCalls = 0
  var suspendStart = false
  private var startGate: CheckedContinuation<Void, Never>?
  private var continuation: AsyncStream<NearbyRendezvousEvent>.Continuation?
  private var stream: AsyncStream<NearbyRendezvousEvent>?

  func events() -> AsyncStream<NearbyRendezvousEvent> {
    if let stream {return stream}
    let pair = AsyncStream<NearbyRendezvousEvent>.makeStream()
    continuation = pair.continuation; stream = pair.stream
    return pair.stream
  }

  func emit(_ event: NearbyRendezvousEvent) {continuation?.yield(event)}
  func resumeStart() {startGate?.resume(); startGate = nil}
  func start() async throws {
    startCalls += 1
    if suspendStart {await withCheckedContinuation {startGate = $0}}
    if let startError {throw startError}
  }
  func acceptPeerToken(playerID: String, data: Data) throws {acceptedTokens.append((playerID, data))}
  func removePeer(playerID: String) {removedPeers.append(playerID)}
  func stop() async {stopCalls += 1}
}
