import Foundation

// MARK: - Peer-channel and lock metrics (KIL-20)
//
// Pure accumulator for the numbers the ticket asks the physical run to report:
// transform update interval p50/p95/p99, pose age, packet loss and out-of-order
// counts, and re-lock recovery time. Fed by the session adapter; rendered by the
// harness HUD and the CSV export. Every number is on the local phone's clock.

struct ArenaMetricsSummary: Equatable, Sendable {
  let samplesAccepted: Int
  let samplesOutOfOrder: Int
  let samplesLost: Int
  let updateIntervalP50Ms: Int64?
  let updateIntervalP95Ms: Int64?
  let updateIntervalP99Ms: Int64?
  let latestPoseAgeMs: Int64?
  let lockLosses: Int
  let recoveryMsMax: Int64?
  let recoveryMsMean: Int64?

  static let empty = ArenaMetricsSummary(
    samplesAccepted: 0,
    samplesOutOfOrder: 0,
    samplesLost: 0,
    updateIntervalP50Ms: nil,
    updateIntervalP95Ms: nil,
    updateIntervalP99Ms: nil,
    latestPoseAgeMs: nil,
    lockLosses: 0,
    recoveryMsMax: nil,
    recoveryMsMean: nil
  )
}

struct ArenaFrameMetrics: Equatable, Sendable {
  /// Bounded so a 20-minute run does not grow unbounded; percentiles are over
  /// the most recent window, which is what the operator wants to read anyway.
  static let intervalWindow = 2_000

  private(set) var samplesAccepted = 0
  private(set) var samplesOutOfOrder = 0
  private(set) var samplesLost = 0
  private(set) var lockLosses = 0
  private var intervalsMs: [Int64] = []
  private var recoveriesMs: [Int64] = []
  private var lastSequence: Int64?
  private var lastArrivalMs: Int64?

  /// Returns `true` when the sample advances the sequence and should be kept.
  @discardableResult
  mutating func recordPeerSample(sequence: Int64, arrivalMs: Int64) -> Bool {
    if let lastSequence {
      guard sequence > lastSequence else {
        samplesOutOfOrder += 1
        return false
      }
      let gap = sequence - lastSequence - 1
      if gap > 0 { samplesLost += Int(gap) }
    }
    if let lastArrivalMs {
      intervalsMs.append(max(0, arrivalMs - lastArrivalMs))
      if intervalsMs.count > Self.intervalWindow {
        intervalsMs.removeFirst(intervalsMs.count - Self.intervalWindow)
      }
    }
    lastSequence = sequence
    lastArrivalMs = arrivalMs
    samplesAccepted += 1
    return true
  }

  mutating func recordLockLoss() {
    lockLosses += 1
  }

  mutating func recordRecovery(ms: Int64) {
    recoveriesMs.append(max(0, ms))
  }

  /// Sequence continuity is per peer session; a peer that reconnects starts a
  /// fresh sequence and must not be counted as a giant loss burst.
  mutating func resetPeerSequence() {
    lastSequence = nil
    lastArrivalMs = nil
  }

  func summary(nowMs: Int64) -> ArenaMetricsSummary {
    let sorted = intervalsMs.sorted()
    let meanRecovery = recoveriesMs.isEmpty
      ? nil
      : recoveriesMs.reduce(0, +) / Int64(recoveriesMs.count)
    return ArenaMetricsSummary(
      samplesAccepted: samplesAccepted,
      samplesOutOfOrder: samplesOutOfOrder,
      samplesLost: samplesLost,
      updateIntervalP50Ms: Self.percentile(sorted, 50),
      updateIntervalP95Ms: Self.percentile(sorted, 95),
      updateIntervalP99Ms: Self.percentile(sorted, 99),
      latestPoseAgeMs: lastArrivalMs.map { max(0, nowMs - $0) },
      lockLosses: lockLosses,
      recoveryMsMax: recoveriesMs.max(),
      recoveryMsMean: meanRecovery
    )
  }

  /// Nearest-rank percentile over an ascending array.
  static func percentile(_ sorted: [Int64], _ p: Int) -> Int64? {
    guard !sorted.isEmpty else { return nil }
    let rank = Int((Double(p) / 100 * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
  }
}

// MARK: - Measurement log (docs/research/shared-arena-frame-options.md §6.3)

/// One CSV row of the per-run measurement log. Intentionally contains no device
/// identifiers, network addresses, or coordinates outside the arena frame.
struct ArenaLogRecord: Equatable, Sendable {
  let elapsedMs: Int64
  let role: ArenaRole
  let method: ArenaFrameMethod
  let localTracking: ArenaLocalTracking
  let mappingStatus: ArenaMappingStatus
  let lockState: ArenaLockState
  let peerSequence: Int64?
  let peerAgeMs: Int64?
  let interPhoneDistanceMeters: Double?
  let residual: ArenaAlignmentResidual?
  let bytesIn: Int
  let bytesOut: Int
  let thermalState: String

  static let csvHeader = [
    "elapsed_ms", "role", "method", "local_tracking", "mapping_status", "lock_state",
    "peer_seq", "peer_age_ms", "inter_phone_distance_m", "residual_translation_m",
    "residual_yaw_deg", "bytes_in", "bytes_out", "thermal_state",
  ].joined(separator: ",")

  var csvLine: String {
    var fields: [String] = []
    fields.append(String(elapsedMs))
    fields.append(role.rawValue)
    fields.append(method.rawValue)
    fields.append(localTracking.label)
    fields.append(mappingStatus.rawValue)
    fields.append(lockState.label)
    fields.append(peerSequence.map { String($0) } ?? "")
    fields.append(peerAgeMs.map { String($0) } ?? "")
    fields.append(interPhoneDistanceMeters.map(Self.format) ?? "")
    fields.append(residual.map { Self.format($0.translationMeters) } ?? "")
    fields.append(residual.map { Self.format($0.yawDegrees) } ?? "")
    fields.append(String(bytesIn))
    fields.append(String(bytesOut))
    fields.append(Self.escape(thermalState))
    return fields.joined(separator: ",")
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    return String(format: "%.4f", value)
  }

  private static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
