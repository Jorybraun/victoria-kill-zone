import Foundation

public enum TransportChannel: String, Codable, CaseIterable, Sendable {
  case pose
  case reliable
}

public struct TransportChannelSnapshot: Codable, Equatable, Sendable {
  public let channel: TransportChannel
  public let sent: Int
  public let received: Int
  public let accepted: Int
  public let discarded: Int
  public let duplicate: Int
  public let buffered: Int
  public let sequenceGapLossPercent: Double
  public let jitterP50Ms: Double
  public let jitterP95Ms: Double
  public let sendToReceiveP50Ms: Double
  public let sendToReceiveP95Ms: Double

  public init(
    channel: TransportChannel,
    sent: Int,
    received: Int,
    accepted: Int,
    discarded: Int,
    duplicate: Int,
    buffered: Int,
    sequenceGapLossPercent: Double,
    jitterP50Ms: Double,
    jitterP95Ms: Double,
    sendToReceiveP50Ms: Double,
    sendToReceiveP95Ms: Double
  ) {
    self.channel = channel
    self.sent = sent
    self.received = received
    self.accepted = accepted
    self.discarded = discarded
    self.duplicate = duplicate
    self.buffered = buffered
    self.sequenceGapLossPercent = sequenceGapLossPercent
    self.jitterP50Ms = jitterP50Ms
    self.jitterP95Ms = jitterP95Ms
    self.sendToReceiveP50Ms = sendToReceiveP50Ms
    self.sendToReceiveP95Ms = sendToReceiveP95Ms
  }
}

public struct TransportSlotSnapshot: Codable, Equatable, Sendable {
  public let slot: UInt8
  public let sent: Int
  public let received: Int
  public let accepted: Int
  public let discarded: Int
  public let duplicate: Int
  public let buffered: Int

  public init(
    slot: UInt8,
    sent: Int,
    received: Int,
    accepted: Int,
    discarded: Int,
    duplicate: Int,
    buffered: Int
  ) {
    self.slot = slot
    self.sent = sent
    self.received = received
    self.accepted = accepted
    self.discarded = discarded
    self.duplicate = duplicate
    self.buffered = buffered
  }
}

public struct TransportStatsSnapshot: Codable, Equatable, Sendable {
  public let schema: String
  public let clockSource: String
  public let channels: [TransportChannelSnapshot]
  public let slots: [TransportSlotSnapshot]
  public let disconnectCount: Int
  public let recoveryCount: Int
  public let fireLockedMilliseconds: Int64

  public init(
    schema: String = "transport-stats.v0",
    clockSource: String = "virtual-match-ms",
    channels: [TransportChannelSnapshot],
    slots: [TransportSlotSnapshot],
    disconnectCount: Int,
    recoveryCount: Int,
    fireLockedMilliseconds: Int64
  ) {
    self.schema = schema
    self.clockSource = clockSource
    self.channels = channels
    self.slots = slots
    self.disconnectCount = disconnectCount
    self.recoveryCount = recoveryCount
    self.fireLockedMilliseconds = fireLockedMilliseconds
  }
}

public struct TransportStats: Equatable, Sendable {
  private struct Counters: Equatable, Sendable {
    var sent = 0
    var received = 0
    var accepted = 0
    var discarded = 0
    var duplicate = 0
    var buffered = 0
    var expectedSequences = 0
    var missingSequences = 0
    var previousArrivalMs: Int64?
    var interArrival: SampleRing
    var sendToReceive: SampleRing

    init() {
      interArrival = SampleRing()
      sendToReceive = SampleRing()
    }
  }

  private var channelCounters: [TransportChannel: Counters] = {
    Dictionary(uniqueKeysWithValues: TransportChannel.allCases.map { ($0, Counters()) })
  }()
  private var slotCounters: [UInt8: Counters] = [:]
  public private(set) var disconnectCount = 0
  public private(set) var recoveryCount = 0
  public private(set) var fireLockedMilliseconds: Int64 = 0
  private var fireLockStartedAtMs: Int64?

  public init() {}

  public mutating func recordSent(channel: TransportChannel, slot: UInt8) {
    channelCounters[channel]!.sent += 1
    slotCounters[slot, default: Counters()].sent += 1
  }

  public mutating func recordReceived(
    channel: TransportChannel,
    slot: UInt8,
    accepted: Bool,
    duplicate: Bool = false,
    buffered: Bool = false,
    arrivalMs: Int64? = nil,
    sentAtMs: Int64? = nil
  ) {
    var channelValue = channelCounters[channel]!
    var slotValue = slotCounters[slot, default: Counters()]
    channelValue.received += 1
    slotValue.received += 1
    if accepted {
      channelValue.accepted += 1
      slotValue.accepted += 1
    } else {
      channelValue.discarded += 1
      slotValue.discarded += 1
    }
    if duplicate {
      channelValue.duplicate += 1
      slotValue.duplicate += 1
    }
    if buffered {
      channelValue.buffered += 1
      slotValue.buffered += 1
    }
    if let arrivalMs {
      if let previous = channelValue.previousArrivalMs {
        channelValue.interArrival.append(abs(arrivalMs - previous))
      }
      channelValue.previousArrivalMs = arrivalMs
      if let sentAtMs {
        channelValue.sendToReceive.append(max(0, arrivalMs - sentAtMs))
      }
    }
    channelCounters[channel] = channelValue
    slotCounters[slot] = slotValue
  }

  public mutating func recordSequence(expected: Int, missing: Int, channel: TransportChannel) {
    channelCounters[channel]!.expectedSequences += max(0, expected)
    channelCounters[channel]!.missingSequences += max(0, missing)
  }

  public mutating func recordDisconnect() {
    disconnectCount += 1
  }

  public mutating func recordRecovery() {
    recoveryCount += 1
  }

  public mutating func setFireLocked(_ locked: Bool, at nowMs: Int64) {
    if locked, fireLockStartedAtMs == nil {
      fireLockStartedAtMs = nowMs
    } else if !locked, let started = fireLockStartedAtMs {
      fireLockedMilliseconds += max(0, nowMs - started)
      fireLockStartedAtMs = nil
    }
  }

  public func sanitizedSnapshot(nowMs: Int64? = nil) -> TransportStatsSnapshot {
    var lockedDuration = fireLockedMilliseconds
    if let started = fireLockStartedAtMs, let nowMs {
      lockedDuration += max(0, nowMs - started)
    }
    let channels = TransportChannel.allCases.map { channel in
      let value = channelCounters[channel]!
      let denominator = value.expectedSequences + value.missingSequences
      return TransportChannelSnapshot(
        channel: channel,
        sent: value.sent,
        received: value.received,
        accepted: value.accepted,
        discarded: value.discarded,
        duplicate: value.duplicate,
        buffered: value.buffered,
        sequenceGapLossPercent: denominator == 0
          ? 0
          : Double(value.missingSequences) / Double(denominator) * 100,
        jitterP50Ms: value.interArrival.percentile(0.50),
        jitterP95Ms: value.interArrival.percentile(0.95),
        sendToReceiveP50Ms: value.sendToReceive.percentile(0.50),
        sendToReceiveP95Ms: value.sendToReceive.percentile(0.95)
      )
    }
    let slots = slotCounters.keys.sorted().map { slot in
      let value = slotCounters[slot]!
      return TransportSlotSnapshot(
        slot: slot,
        sent: value.sent,
        received: value.received,
        accepted: value.accepted,
        discarded: value.discarded,
        duplicate: value.duplicate,
        buffered: value.buffered
      )
    }
    return TransportStatsSnapshot(
      channels: channels,
      slots: slots,
      disconnectCount: disconnectCount,
      recoveryCount: recoveryCount,
      fireLockedMilliseconds: lockedDuration
    )
  }

  public func sanitizedSnapshotData(nowMs: Int64? = nil) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(sanitizedSnapshot(nowMs: nowMs))
  }
}

private struct SampleRing: Equatable, Sendable {
  private var values: [Int64] = []
  private let capacity = 128

  mutating func append(_ value: Int64) {
    if values.count == capacity {
      values.removeFirst()
    }
    values.append(value)
  }

  func percentile(_ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
    return Double(sorted[index])
  }
}
