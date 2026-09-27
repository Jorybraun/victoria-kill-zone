import Foundation
import os

struct MatchDiagnosticEvent: Codable, Equatable, Sendable {
  let elapsedMs: Int64
  let kind: String
  let detail: String
}

/// Sanitized bounded match log.
/// Every record also mirrors to unified logging in all builds so a phone on a
/// cable (or wireless debugging) streams live trials in Console.app.
struct MatchDiagnostics: Sendable {
  static let capacity = 256
  private static let logger = Logger(subsystem: "com.victoriakillzone.match", category: "match")
  /// Survives relaunch and crash so the previous session's log stays
  /// exportable; overwritten by the next session's first record.
  static let persistedURL: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("com.victoriakillzone/match-diagnostics.json")
  }()
  private(set) var events: [MatchDiagnosticEvent] = []
  private var startedAt: Date
  private var lastPersistedAt: Date?

  init(startedAt: Date) { self.startedAt = startedAt }

  mutating func reset(at: Date) {
    events = []
    startedAt = at
    lastPersistedAt = nil
  }

  mutating func record(_ kind: String, _ detail: String, at: Date) {
    let event = MatchDiagnosticEvent(elapsedMs: Int64(at.timeIntervalSince(startedAt) * 1000),
      kind: kind, detail: detail)
    events.append(event)
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
    Self.logger.info("\(event.elapsedMs)ms \(event.kind, privacy: .public): \(event.detail, privacy: .public)")
    if lastPersistedAt.map({ at.timeIntervalSince($0) >= 1 }) ?? true {
      lastPersistedAt = at
      try? persist()
    }
  }

  /// Flushes records that arrived inside the throttle window.
  mutating func flush() { try? persist() }

  private func persist() throws {
    let url = Self.persistedURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(events).write(to: url, options: .atomic)
  }

  /// Current session events, or the persisted previous session after relaunch.
  func export() throws -> URL { try export(merging: []) }

  /// Current session events plus `extra` events appended (e.g. the flagged
  /// local-surfaces log), or the persisted previous session when both are
  /// empty.
  func export(merging extra: [MatchDiagnosticEvent]) throws -> URL {
    let data: Data
    if events.isEmpty, extra.isEmpty, let persisted = try? Data(contentsOf: Self.persistedURL) {
      data = persisted
    } else {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      data = try encoder.encode(events + extra)
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("match-diagnostics-\(UUID().uuidString).json")
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }
}
