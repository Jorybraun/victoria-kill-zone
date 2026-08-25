import Foundation

/// One Phone Pose Sample on the synchronized match clock (spatial-hit.v1 vocabulary).
public struct PoseSample: Equatable, Sendable, Codable {
  public let timestampMs: Int64
  public let position: Vector3
  public let tracking: TrackingState

  public init(timestampMs: Int64, position: Vector3, tracking: TrackingState = .normal) {
    self.timestampMs = timestampMs
    self.position = position
    self.tracking = tracking
  }
}

/// Tracking quality attached to a pose sample. Anything other than `normal`
/// locks that player out of verdicts; stale transforms are never reused.
public enum TrackingState: String, Equatable, Sendable, Codable {
  case normal
  case lost
}

/// Fixed-capacity, monotonic ring buffer of pose samples for one player.
/// Samples that do not advance the clock are dropped so replaying the same
/// input log always reproduces the same buffer contents.
public struct PoseHistoryRingBuffer: Equatable, Sendable {
  public let capacity: Int
  private var samples: [PoseSample]
  private var nextIndex = 0
  private var storedCount = 0

  public init(capacity: Int) {
    precondition(capacity > 0, "pose history capacity must be positive")
    self.capacity = capacity
    self.samples = []
    self.samples.reserveCapacity(capacity)
  }

  public var count: Int {
    storedCount
  }

  public var latest: PoseSample? {
    guard storedCount > 0 else { return nil }
    let index = (nextIndex - 1 + capacity) % capacity
    return samples[index]
  }

  /// Records a sample if it is strictly newer than the latest stored sample.
  /// Returns whether the sample was stored.
  @discardableResult
  public mutating func record(_ sample: PoseSample) -> Bool {
    if let latest, sample.timestampMs <= latest.timestampMs {
      return false
    }
    if samples.count < capacity {
      samples.append(sample)
    } else {
      samples[nextIndex] = sample
    }
    nextIndex = (nextIndex + 1) % capacity
    storedCount = min(storedCount + 1, capacity)
    return true
  }

  /// The most recent sample at or before `timestampMs`, or nil when every
  /// stored sample is newer or the buffer is empty.
  public func sample(atOrBefore timestampMs: Int64) -> PoseSample? {
    var best: PoseSample?
    for offset in 0..<storedCount {
      let index = (nextIndex - 1 - offset + 2 * capacity) % capacity
      let candidate = samples[index]
      if candidate.timestampMs <= timestampMs {
        best = candidate
        break
      }
    }
    return best
  }
}
