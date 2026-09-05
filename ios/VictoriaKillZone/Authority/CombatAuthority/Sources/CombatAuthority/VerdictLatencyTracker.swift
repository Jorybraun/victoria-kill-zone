import Foundation

public struct VerdictLatencyReport: Equatable, Sendable, Codable {
  public let count: Int
  public let p50Ms: Int64?
  public let p95Ms: Int64?
  public let p99Ms: Int64?
  public let maxMs: Int64?

  public init(
    count: Int,
    p50Ms: Int64?,
    p95Ms: Int64?,
    p99Ms: Int64?,
    maxMs: Int64?
  ) {
    self.count = count
    self.p50Ms = p50Ms
    self.p95Ms = p95Ms
    self.p99Ms = p99Ms
    self.maxMs = maxMs
  }
}

public struct VerdictLatencyTracker: Equatable, Sendable {
  private static let capacity = 4_096
  private var samples: [Int64] = []

  public init() {}

  public var count: Int {
    samples.count
  }

  public mutating func record(latencyMs: Int64) {
    if samples.count == Self.capacity {
      samples.removeFirst()
    }
    samples.append(latencyMs)
  }

  public func percentile(_ p: Double) -> Int64? {
    guard !samples.isEmpty, p > 0, p <= 1 else { return nil }
    let sorted = samples.sorted()
    let rank = max(1, Int(ceil(p * Double(sorted.count))))
    return sorted[rank - 1]
  }

  public var report: VerdictLatencyReport {
    VerdictLatencyReport(
      count: count,
      p50Ms: percentile(0.50),
      p95Ms: percentile(0.95),
      p99Ms: percentile(0.99),
      maxMs: samples.max()
    )
  }
}
