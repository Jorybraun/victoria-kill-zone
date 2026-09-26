import Foundation

/// Debug-only hooks for the flagged local-surface path. All methods are no-ops
/// when the flag is off.
protocol LocalSurfaceDiagnosticsProviding: Sendable {
  /// Sanitized events (capability probe, plane add/remove, fire queries,
  /// summary) for the setup-log export.
  func localSurfaceDiagnosticEvents() -> [DuelFrameDiagnosticEvent]
  /// Telemetry CSV for BIO-36 rows B1/B3, or nil when the flag is off / nothing
  /// recorded.
  func localSurfaceTelemetryCSV() -> String?
  /// Called on each sighting fire; logs the local surface query against the
  /// body observation. Never affects the fire command.
  func recordSightingFire(skeleton: TargetingSkeleton?)
}
