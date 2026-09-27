import Foundation

/// Debug-only hooks for the flagged local-surface path. All methods are no-ops
/// when the flag is off.
protocol LocalSurfaceDiagnosticsProviding: Sendable {
  /// Sanitized events (capability probe, plane add/remove, fire queries,
  /// summary) for the match report.
  func localSurfaceDiagnosticEvents() -> [MatchDiagnosticEvent]
  /// Telemetry CSV for BIO-36 rows B1/B3, or nil when the flag is off / nothing
  /// recorded.
  func localSurfaceTelemetryCSV() -> String?
  /// Called on each sighting fire; logs the local surface query against the
  /// body observation. Never affects the fire command; `ray` is the exact ray
  /// the fire command carried.
  func recordSightingFire(ray: TargetingCameraRay, skeleton: TargetingSkeleton?)
}
