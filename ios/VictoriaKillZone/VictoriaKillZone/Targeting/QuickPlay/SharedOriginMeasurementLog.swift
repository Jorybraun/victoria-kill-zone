#if DEBUG
import Foundation

/// Sanitized bounded measurement export: no run IDs, peer IDs, codes, images or AR archives.
struct SharedOriginMeasurementLog {
  private(set) var lines = ["elapsed_ms,phase,local_origin_observed,local_x_m,local_y_m,local_z_m,phone_distance_m,peer_receipt_age_ms,peer_reported_source_age_ms,bytes_in,bytes_out"]
  private var lastElapsedMs: Int64 = -100

  mutating func append(_ snapshot: SharedArenaSnapshot) {
    guard lines.count < 20_001, snapshot.elapsedMs - lastElapsedMs >= 100 else {return}
    lastElapsedMs = snapshot.elapsedMs
    let position = snapshot.localArenaPosition
    lines.append([String(snapshot.elapsedMs), snapshot.phase.rawValue, snapshot.originObserved ? "1" : "0",
      number(position?.x), number(position?.y), number(position?.z), number(snapshot.interPhoneDistanceMeters),
      number(snapshot.peerReceiptAgeMs), number(snapshot.peerSourceAgeMs), String(snapshot.bytesIn), String(snapshot.bytesOut)].joined(separator: ","))
  }

  func export() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-origin-measurements-\(UUID().uuidString).csv")
    try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  private func number(_ value: Double?) -> String {
    guard let value, value.isFinite else {return ""}
    return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
  }
}
#endif
