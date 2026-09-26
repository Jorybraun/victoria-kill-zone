import Foundation

struct LocalSurfaceTelemetrySample: Codable, Equatable, Sendable {
  let elapsedMs: Int64
  let frames: Int
  let planeCount: Int
  let boundaryVertexTotal: Int
  let planeAdds: Int
  let planeUpdates: Int
  let planeRemoves: Int
  let thermalState: String
}

/// Bounded per-second telemetry for the local-surfaces debug path. Sanitized:
/// counts only — no anchor IDs, positions or device identifiers.
struct LocalSurfaceTelemetry: Equatable, Sendable {
  static let maximumSamples = 20_000
  static let maximumEvents = 256
  static let csvHeader = "elapsed_ms,frames,fps,plane_count,boundary_vertices,plane_adds,plane_updates,plane_removes,thermal_state"

  private(set) var startedAt: Date
  private(set) var samples: [LocalSurfaceTelemetrySample] = []
  private(set) var planeAdds = 0
  private(set) var planeUpdates = 0
  private(set) var planeRemoves = 0
  private(set) var timeToFirstFloorMs: Int64?
  private(set) var timeToFirstWallMs: Int64?
  private(set) var events: [DuelFrameDiagnosticEvent] = []

  private var framesInCurrentSecond = 0
  private var currentSecondIndex = -1
  private var latestPlaneCount = 0
  private var latestBoundaryVertexTotal = 0
  private var latestThermalState = ""

  init(startedAt: Date) { self.startedAt = startedAt }

  mutating func reset(at: Date) {
    startedAt = at
    samples = []
    planeAdds = 0
    planeUpdates = 0
    planeRemoves = 0
    timeToFirstFloorMs = nil
    timeToFirstWallMs = nil
    events = []
    framesInCurrentSecond = 0
    currentSecondIndex = -1
    latestPlaneCount = 0
    latestBoundaryVertexTotal = 0
    latestThermalState = ""
  }

  mutating func recordFrame(at: Date, planeCount: Int, boundaryVertexTotal: Int, thermalState: String) {
    guard at >= startedAt else { return }
    let secondIndex = Int(at.timeIntervalSince(startedAt))
    if currentSecondIndex < 0 { currentSecondIndex = secondIndex }
    if secondIndex > currentSecondIndex {
      appendSample(forSecond: currentSecondIndex)
      currentSecondIndex = secondIndex
      framesInCurrentSecond = 0
    }
    latestPlaneCount = planeCount
    latestBoundaryVertexTotal = boundaryVertexTotal
    latestThermalState = thermalState
    framesInCurrentSecond += 1
  }

  mutating func recordPlaneAdded(_ plane: LocalSurfacePlane, at: Date) {
    planeAdds += 1
    let elapsedMs = Self.elapsedMs(since: startedAt, at: at)
    if timeToFirstFloorMs == nil,
      plane.classification == .floor
        || (plane.alignment == .horizontal && [.none, .unknown].contains(plane.classification)) {
      timeToFirstFloorMs = elapsedMs
    }
    if timeToFirstWallMs == nil,
      plane.classification == .wall
        || (plane.alignment == .vertical && [.none, .unknown].contains(plane.classification)) {
      timeToFirstWallMs = elapsedMs
    }
    recordEvent("surface",
      "add align=\(plane.alignment.rawValue) class=\(plane.classification.rawValue) verts=\(plane.boundaryVertexCount)",
      at: at)
  }

  mutating func recordPlaneUpdated(_ plane: LocalSurfacePlane, at: Date) {
    planeUpdates += 1
  }

  mutating func recordPlaneRemoved(id: UUID, at: Date) {
    planeRemoves += 1
    recordEvent("surface", "remove", at: at)
  }

  mutating func recordCapability(_ report: DeviceCapabilityReport, at: Date) {
    recordEvent("capability", report.summary, at: at)
  }

  mutating func recordEvent(_ kind: String, _ detail: String, at: Date) {
    events.append(DuelFrameDiagnosticEvent(
      elapsedMs: Self.elapsedMs(since: startedAt, at: at), kind: kind, detail: detail))
    if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
  }

  func csv() -> String {
    var lines = [Self.csvHeader]
    for sample in samples {
      let fps = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(sample.frames))
      lines.append([
        String(sample.elapsedMs), String(sample.frames), fps, String(sample.planeCount),
        String(sample.boundaryVertexTotal), String(sample.planeAdds), String(sample.planeUpdates),
        String(sample.planeRemoves), sample.thermalState,
      ].joined(separator: ","))
    }
    return lines.joined(separator: "\n")
  }

  func summaryDetail() -> String {
    "adds=\(planeAdds) updates=\(planeUpdates) removes=\(planeRemoves) firstFloorMs=\(timeToFirstFloorMs.map(String.init) ?? "-") firstWallMs=\(timeToFirstWallMs.map(String.init) ?? "-") samples=\(samples.count)"
  }

  private mutating func appendSample(forSecond secondIndex: Int) {
    guard samples.count < Self.maximumSamples else { return }
    samples.append(LocalSurfaceTelemetrySample(
      elapsedMs: Int64(secondIndex + 1) * 1000,
      frames: framesInCurrentSecond,
      planeCount: latestPlaneCount,
      boundaryVertexTotal: latestBoundaryVertexTotal,
      planeAdds: planeAdds,
      planeUpdates: planeUpdates,
      planeRemoves: planeRemoves,
      thermalState: latestThermalState))
  }

  private static func elapsedMs(since startedAt: Date, at: Date) -> Int64 {
    Int64(at.timeIntervalSince(startedAt) * 1000)
  }
}
