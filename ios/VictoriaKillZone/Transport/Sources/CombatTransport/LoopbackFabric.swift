import Foundation

public struct FaultProfile: Equatable, Sendable {
  public var poseLossPercent: Int
  public var jitterMs: Int
  public var reliableReorderPercent: Int
  public var reliableDuplicatePercent: Int
  public var baseLatencyMs: Int

  public init(
    poseLossPercent: Int = 0,
    jitterMs: Int = 0,
    reliableReorderPercent: Int = 0,
    reliableDuplicatePercent: Int = 0,
    baseLatencyMs: Int = 0
  ) {
    self.poseLossPercent = min(100, max(0, poseLossPercent))
    self.jitterMs = max(0, jitterMs)
    self.reliableReorderPercent = min(100, max(0, reliableReorderPercent))
    self.reliableDuplicatePercent = min(100, max(0, reliableDuplicatePercent))
    self.baseLatencyMs = max(0, baseLatencyMs)
  }
}

public final class LoopbackEndpoint: PeerLink, @unchecked Sendable {
  public let slot: UInt8
  public var remoteSlot: UInt8 { slot }
  private let fabric: LoopbackFabric

  fileprivate init(slot: UInt8, fabric: LoopbackFabric) {
    self.slot = slot
    self.fabric = fabric
  }

  public func send(_ frame: PoseFrame) throws {
    try fabric.schedule(.pose(frame))
  }

  public func send(_ frame: ReliableEventFrame) throws {
    try fabric.schedule(.reliable(frame))
  }

  public func send(_ frame: TransportFrame) throws {
    switch frame {
    case let .pose(value, _):
      try send(value)
    case let .reliable(value, _):
      try send(value)
    }
  }

  public func start() {}

  public func stop() {}

  public func latestPose(for senderSlot: UInt8) -> PoseFrame? {
    fabric.latestPose(for: senderSlot)
  }

  public func deliveredReliableEvents(for senderSlot: UInt8) -> [ReliableEventFrame] {
    fabric.deliveredReliableEvents(for: senderSlot)
  }
}

public final class LoopbackFabric {
  fileprivate enum Payload {
    case pose(PoseFrame)
    case reliable(ReliableEventFrame)
  }

  private struct Scheduled {
    let dueMs: Int64
    let ordinal: UInt64
    let payload: Payload
    let sentAtMs: Int64
  }

  private var random: SeededRandom
  private let profile: FaultProfile
  private var scheduled: [Scheduled] = []
  private var ordinal: UInt64 = 0
  private(set) public var nowMs: Int64 = 0
  public private(set) var hostCore: CombatTransportCore
  public let playerCount: Int

  public init(
    playerCount: Int,
    faultProfile: FaultProfile = FaultProfile(),
    seed: UInt64 = 1
  ) {
    self.playerCount = playerCount
    self.profile = faultProfile
    self.random = SeededRandom(seed: seed)
    hostCore = CombatTransportCore(slot: HostRelayTopology.hostSlot)
  }

  public var host: LoopbackEndpoint {
    LoopbackEndpoint(slot: HostRelayTopology.hostSlot, fabric: self)
  }

  public func client(slot: UInt8) -> LoopbackEndpoint {
    LoopbackEndpoint(slot: slot, fabric: self)
  }

  fileprivate func schedule(_ payload: Payload) throws {
    switch payload {
    case .pose:
      if random.nextInt(100) < profile.poseLossPercent { return }
    case .reliable:
      break
    }
    let jitter = profile.jitterMs == 0 ? 0 : random.nextInt(profile.jitterMs + 1)
    let reorder = {
      guard profile.reliableReorderPercent > 0 else { return 0 }
      return random.nextInt(100) < profile.reliableReorderPercent
        ? random.nextInt(profile.jitterMs + 1)
        : 0
    }()
    let delay = profile.baseLatencyMs + jitter + reorder
    ordinal += 1
    let sentAt = nowMs
    scheduled.append(
      Scheduled(
        dueMs: nowMs + Int64(delay),
        ordinal: ordinal,
        payload: payload,
        sentAtMs: sentAt
      )
    )
    if case let .reliable(frame) = payload,
       profile.reliableDuplicatePercent > 0,
       random.nextInt(100) < profile.reliableDuplicatePercent {
      ordinal += 1
      scheduled.append(
        Scheduled(
          dueMs: nowMs + Int64(delay + 1),
          ordinal: ordinal,
          payload: .reliable(frame),
          sentAtMs: sentAt
        )
      )
    }
  }

  public func advance(to targetMs: Int64) {
    guard targetMs >= nowMs else { return }
    nowMs = targetMs
    while let index = scheduled.enumerated()
      .filter({ $0.element.dueMs <= nowMs })
      .min(by: {
        if $0.element.dueMs == $1.element.dueMs {
          return $0.element.ordinal < $1.element.ordinal
        }
        return $0.element.dueMs < $1.element.dueMs
      })?.offset {
      let event = scheduled.remove(at: index)
      switch event.payload {
      case let .pose(frame):
        _ = hostCore.receivePose(frame, receivedAtMs: nowMs, sentAtMs: event.sentAtMs)
      case let .reliable(frame):
        _ = hostCore.receiveReliable(frame, receivedAtMs: nowMs, sentAtMs: event.sentAtMs)
      }
    }
  }

  public func latestPose(for senderSlot: UInt8) -> PoseFrame? {
    hostCore.latestPose(for: senderSlot)
  }

  public func deliveredReliableEvents(for senderSlot: UInt8) -> [ReliableEventFrame] {
    hostCore.deliveredReliableEvents(for: senderSlot)
  }

  public func sanitizedStatsSnapshot() -> TransportStatsSnapshot {
    hostCore.stats.sanitizedSnapshot(nowMs: nowMs)
  }

  public func sanitizedStatsSnapshotData() throws -> Data {
    try hostCore.stats.sanitizedSnapshotData(nowMs: nowMs)
  }
}

private struct SeededRandom: Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
  }

  mutating func nextInt(_ upperBound: Int) -> Int {
    state = state &* 2862933555777941757 &+ 3037000493
    return Int((state >> 33) % UInt64(max(1, upperBound)))
  }
}
