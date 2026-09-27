import Foundation
import XCTest

@testable import VictoriaKillZone

final class MatchDiagnosticsTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  func testRingBufferKeepsNewestEventsWithMonotonicElapsedTime() {
    var log = MatchDiagnostics(startedAt: base)
    for index in 0..<300 {
      log.record("tracking", "event \(index)", at: base.addingTimeInterval(Double(index)))
    }
    XCTAssertEqual(log.events.count, MatchDiagnostics.capacity)
    XCTAssertEqual(log.events.first?.detail, "event \(300 - MatchDiagnostics.capacity)")
    XCTAssertEqual(log.events.last?.detail, "event 299")
    XCTAssertTrue(zip(log.events, log.events.dropFirst()).allSatisfy { $0.elapsedMs <= $1.elapsedMs })
  }

  func testResetClearsEventsAndRestartsTheClock() {
    var log = MatchDiagnostics(startedAt: base)
    log.record("stage", "first", at: base.addingTimeInterval(1))
    log.reset(at: base.addingTimeInterval(2))
    log.record("stage", "second", at: base.addingTimeInterval(3))
    XCTAssertEqual(log.events.count, 1)
    XCTAssertEqual(log.events.first?.detail, "second")
    XCTAssertEqual(log.events.first?.elapsedMs, 1_000)
  }

  func testExportWritesDecodableJSONWithOwnerOnlyPermissions() throws {
    var log = MatchDiagnostics(startedAt: base)
    log.record("stage", "connecting", at: base.addingTimeInterval(0.5))
    log.record("tracking", "normal", at: base.addingTimeInterval(0.6))
    let url = try log.export()
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([MatchDiagnosticEvent].self,
      from: Data(contentsOf: url))
    XCTAssertEqual(decoded, log.events)
    XCTAssertTrue(url.lastPathComponent.hasPrefix("match-diagnostics-"))
    XCTAssertTrue(url.lastPathComponent.hasSuffix(".json"))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testPersistedPathIsMatchSpecific() {
    XCTAssertEqual(MatchDiagnostics.persistedURL.deletingLastPathComponent().lastPathComponent,
      "com.victoriakillzone")
    XCTAssertEqual(MatchDiagnostics.persistedURL.lastPathComponent, "match-diagnostics.json")
  }

  func testExportMergingAppendsExtraEvents() throws {
    var log = MatchDiagnostics(startedAt: base)
    log.record("stage", "connecting", at: base.addingTimeInterval(0.5))
    let extra = [
      MatchDiagnosticEvent(elapsedMs: 800, kind: "capability", detail: "model=x ios=1"),
      MatchDiagnosticEvent(elapsedMs: 900, kind: "surface", detail: "add align=horizontal class=floor verts=6"),
    ]
    let url = try log.export(merging: extra)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([MatchDiagnosticEvent].self,
      from: Data(contentsOf: url))
    XCTAssertEqual(decoded, log.events + extra)
  }

  func testExportMergingExtraAloneDoesNotFallBackToPersisted() throws {
    let log = MatchDiagnostics(startedAt: base)
    let extra = [MatchDiagnosticEvent(elapsedMs: 10, kind: "surface", detail: "remove")]
    let url = try log.export(merging: extra)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([MatchDiagnosticEvent].self,
      from: Data(contentsOf: url))
    XCTAssertEqual(decoded, extra)
  }

  func testExportMergingTelemetryCsvEventRoundTrips() throws {
    let log = MatchDiagnostics(startedAt: base)
    let csv = "elapsed_ms,frames\n1000,30"
    let extra = [MatchDiagnosticEvent(elapsedMs: 0, kind: "telemetryCsv", detail: csv)]
    let url = try log.export(merging: extra)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([MatchDiagnosticEvent].self,
      from: Data(contentsOf: url))
    let event = decoded.first(where: { $0.kind == "telemetryCsv" })
    XCTAssertNotNil(event)
    XCTAssertTrue(event?.detail.contains(LocalSurfaceTelemetry.csvHeader.components(separatedBy: ",").first ?? "elapsed_ms") ?? false)
    XCTAssertTrue(event?.detail.contains("elapsed_ms,frames") ?? false)
  }

  func testExportEmptyStillServesPersistedFallback() throws {
    let prior = [MatchDiagnosticEvent(elapsedMs: 5, kind: "stage", detail: "prior")]
    let persisted = try JSONEncoder().encode(prior)
    try FileManager.default.createDirectory(
      at: MatchDiagnostics.persistedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: MatchDiagnostics.persistedURL) }
    try persisted.write(to: MatchDiagnostics.persistedURL, options: .atomic)
    let log = MatchDiagnostics(startedAt: base)
    let url = try log.export()
    defer { try? FileManager.default.removeItem(at: url) }
    let decoded = try JSONDecoder().decode([MatchDiagnosticEvent].self,
      from: Data(contentsOf: url))
    XCTAssertEqual(decoded, prior)
  }
}
