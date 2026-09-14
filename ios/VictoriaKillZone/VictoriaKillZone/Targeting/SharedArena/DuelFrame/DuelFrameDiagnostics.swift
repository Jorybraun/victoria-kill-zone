import Foundation

struct DuelFrameDiagnosticEvent: Codable, Equatable, Sendable {
  let elapsedMs: Int64
  let kind: String
  let detail: String
}

/// Sanitized bounded setup log: no frame IDs, peer IDs, codes, images or AR archives.
struct DuelFrameDiagnostics: Sendable {
  static let capacity = 256
  private(set) var events: [DuelFrameDiagnosticEvent] = []
  private var startedAt: Date

  init(startedAt: Date) { self.startedAt = startedAt }

  mutating func reset(at: Date) {
    events = []
    startedAt = at
  }

  mutating func record(_ kind: String, _ detail: String, at: Date) {
    events.append(DuelFrameDiagnosticEvent(elapsedMs: Int64(at.timeIntervalSince(startedAt) * 1000),
      kind: kind, detail: detail))
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
  }

  func export() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("duel-frame-setup-\(UUID().uuidString).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(events).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }
}
