import Foundation
import XCTest

@testable import VictoriaKillZone

final class DuelFrameDiagnosticsTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  func testRingBufferKeepsNewestEventsWithMonotonicElapsedTime() {
    var log = DuelFrameDiagnostics(startedAt: base)
    for index in 0..<300 {
      log.record("tracking", "event \(index)", at: base.addingTimeInterval(Double(index)))
    }
    XCTAssertEqual(log.events.count, DuelFrameDiagnostics.capacity)
    XCTAssertEqual(log.events.first?.detail, "event \(300 - DuelFrameDiagnostics.capacity)")
    XCTAssertEqual(log.events.last?.detail, "event 299")
    XCTAssertTrue(zip(log.events, log.events.dropFirst()).allSatisfy { $0.elapsedMs <= $1.elapsedMs })
  }

  func testResetClearsEventsAndRestartsTheClock() {
    var log = DuelFrameDiagnostics(startedAt: base)
    log.record("stage", "first", at: base.addingTimeInterval(1))
    log.reset(at: base.addingTimeInterval(2))
    log.record("stage", "second", at: base.addingTimeInterval(3))
    XCTAssertEqual(log.events.count, 1)
    XCTAssertEqual(log.events.first?.detail, "second")
    XCTAssertEqual(log.events.first?.elapsedMs, 1_000)
  }

  func testExportWritesDecodableJSONWithOwnerOnlyPermissions() throws {
    var log = DuelFrameDiagnostics(startedAt: base)
    log.record("stage", "unaligned -> mapping", at: base.addingTimeInterval(0.5))
    log.record("tracking", "normal mapped=true phase=mapping", at: base.addingTimeInterval(0.6))
    let url = try log.export()
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([DuelFrameDiagnosticEvent].self,
      from: Data(contentsOf: url))
    XCTAssertEqual(decoded, log.events)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }
}

@MainActor
final class DuelFrameProviderDiagnosticsTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  func testSetupTransitionsAndFailureAreRecordedWithoutIdentifiers() async throws {
    let driver = DiagnosticsDriver()
    let clock = DiagnosticsClock(date: base)
    let provider = DuelFrameProvider(targeting: driver, now: {clock.date})
    try await provider.beginCalibration(epoch: 3)
    for _ in 0..<100 where provider.snapshot.stage != .mapReady {
      driver.emit(epoch: 3, phase: .mapping, tracking: .normal, mapped: true, at: clock.date)
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(provider.snapshot.stage, .mapReady)
    provider.invalidate(reason: .backgrounded)

    let events = try decodedEvents(provider)
    XCTAssertTrue(events.contains { $0.kind == "stage" && $0.detail.contains("beginCalibration epoch=3") })
    XCTAssertTrue(events.contains { $0.kind == "stage" && $0.detail.contains("-> mapReady") })
    XCTAssertTrue(events.contains { $0.kind == "timing" && $0.detail.contains("mapReady after") })
    XCTAssertTrue(events.contains { $0.kind == "tracking" && $0.detail.contains("normal") })
    XCTAssertTrue(events.contains { $0.kind == "failure" && $0.detail == "backgrounded" })

    let json = String(decoding: try Data(contentsOf: provider.exportDiagnostics()), as: UTF8.self)
    XCTAssertFalse(json.contains("frameID"), "Setup logs must not carry frame identifiers")
    await provider.stop()
  }

  func testRepeatedIdenticalTrackingStatesProduceOneEntry() async throws {
    let driver = DiagnosticsDriver()
    let clock = DiagnosticsClock(date: base)
    let provider = DuelFrameProvider(targeting: driver, now: {clock.date})
    try await provider.beginCalibration(epoch: 1)
    driver.emit(epoch: 1, phase: .mapping, tracking: .limited, mapped: false, at: clock.date)
    var trackingEntries = try decodedEvents(provider).filter { $0.kind == "tracking" }
    for _ in 0..<100 where trackingEntries.isEmpty {
      try await Task.sleep(for: .milliseconds(1))
      driver.emit(epoch: 1, phase: .mapping, tracking: .limited, mapped: false, at: clock.date)
      trackingEntries = try decodedEvents(provider).filter { $0.kind == "tracking" }
    }
    XCTAssertEqual(trackingEntries.count, 1)
    for _ in 0..<10 {
      driver.emit(epoch: 1, phase: .mapping, tracking: .limited, mapped: false, at: clock.date)
      try await Task.sleep(for: .milliseconds(2))
    }
    trackingEntries = try decodedEvents(provider).filter { $0.kind == "tracking" }
    XCTAssertEqual(trackingEntries.count, 1)
    await provider.stop()
  }

  func testReferenceCaptureRecordsOutcomeDetails() async throws {
    let driver = DiagnosticsDriver()
    let clock = DiagnosticsClock(date: base)
    let provider = DuelFrameProvider(targeting: driver, now: {clock.date})
    try await provider.beginCalibration(epoch: 1)
    for _ in 0..<100 where provider.snapshot.stage != .mapReady {
      driver.emit(epoch: 1, phase: .mapping, tracking: .normal, mapped: true, at: clock.date)
      try await Task.sleep(for: .milliseconds(1))
    }
    _ = try await provider.captureReference()
    let referenceEntries = try decodedEvents(provider).filter { $0.kind == "reference" }
    XCTAssertTrue(referenceEntries.contains { $0.detail == "capturing" })
    XCTAssertTrue(referenceEntries.contains {
      $0.detail.contains("captured") && $0.detail.contains("w=1.000m") && $0.detail.contains("samples=3")
    })
    await provider.stop()
  }

  private func decodedEvents(_ provider: DuelFrameProvider) throws -> [DuelFrameDiagnosticEvent] {
    let url = try provider.exportDiagnostics()
    defer { try? FileManager.default.removeItem(at: url) }
    return try JSONDecoder().decode([DuelFrameDiagnosticEvent].self, from: Data(contentsOf: url))
  }
}

@MainActor
private final class DiagnosticsClock {
  var date: Date
  init(date: Date) { self.date = date }
}

private final class DiagnosticsDriver: DuelFrameSessionDriving, @unchecked Sendable {
  let hub = DuelFrameObservationHub()
  func duelFrameObservations() -> AsyncStream<DuelFrameObservation> { hub.stream() }
  func beginFrameMapping(epoch: UInt16, mode: DuelFrameAlignmentMode) async throws {}
  func captureFrameMap(epoch: UInt16) async throws -> Data { Data([1, 2, 3]) }
  func captureFrameReference(epoch: UInt16) async throws -> DuelFrameReference {
    try DuelFrameReference(imageData: Data([1, 2, 3]), widthMeters: 1, heightMeters: 0.6,
      mapFromImage: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      sampleCount: 3, maximumCornerDeviationMeters: 0)
  }
  func installFrameMap(_ map: DuelFrameMap, phase: DuelFrameSessionPhase) async throws {}
  func endFrameMapping() async {}

  func emit(epoch: UInt16, phase: DuelFrameSessionPhase, tracking: DuelFrameTracking,
    mapped: Bool, at: Date = Date()) {
    hub.yield(DuelFrameObservation(epoch: epoch, frameID: nil, phase: phase, tracking: tracking,
      isMapped: mapped, pose: nil, observedAt: at, failure: nil))
  }
}
