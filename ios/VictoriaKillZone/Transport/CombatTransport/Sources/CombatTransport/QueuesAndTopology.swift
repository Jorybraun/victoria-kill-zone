import Foundation

public enum PoseQueueEnqueueResult: Equatable, Sendable {
  case enqueued
  case droppedOldest
}

public struct PoseSendQueue: Equatable, Sendable {
  public let capacity: Int
  private var values: [PoseFrame] = []
  public private(set) var posesDroppedForFreshness = 0

  public init(capacity: Int = 3) {
    self.capacity = max(1, capacity)
  }

  @discardableResult
  public mutating func enqueue(_ frame: PoseFrame) -> PoseQueueEnqueueResult {
    if values.count == capacity {
      values.removeFirst()
      posesDroppedForFreshness += 1
      values.append(frame)
      return .droppedOldest
    }
    values.append(frame)
    return .enqueued
  }

  public mutating func dequeue() -> PoseFrame? {
    guard !values.isEmpty else { return nil }
    return values.removeFirst()
  }

  public var count: Int { values.count }
  public var isEmpty: Bool { values.isEmpty }
}

public enum ReliableQueueEnqueueResult: Equatable, Sendable {
  case enqueued
  case rejectedQueueFull
}

public struct ReliableSendQueue: Equatable, Sendable {
  public let capacity: Int
  private var values: [ReliableEventFrame] = []

  public init(capacity: Int = 128) {
    self.capacity = max(1, capacity)
  }

  @discardableResult
  public mutating func enqueue(_ frame: ReliableEventFrame) -> ReliableQueueEnqueueResult {
    guard values.count < capacity else { return .rejectedQueueFull }
    values.append(frame)
    return .enqueued
  }

  public mutating func dequeue() -> ReliableEventFrame? {
    guard !values.isEmpty else { return nil }
    return values.removeFirst()
  }

  public var count: Int { values.count }
  public var isEmpty: Bool { values.isEmpty }
}

public enum PeerMembership: Equatable, Sendable {
  case active
  case disconnected
}

public enum TopologyError: Error, Equatable, Sendable {
  case invalidPlayerCount
  case playerCountFull
  case invalidSlot
  case cannotRemoveHost
}

public enum TransportEffect: Equatable, Sendable {
  case fireLockEngaged
  case fireLockReleased
  case peerDisconnected(slot: UInt8)
  case peerRecovered(slot: UInt8)
  case reliableGapUnrecoverable(slot: UInt8)
  case rejectedReliableQueueFull
  case epochReset(epoch: UInt16)
}

public struct HostRelayTopology: Equatable, Sendable {
  public static let hostSlot: UInt8 = 0
  public static let validSlots: ClosedRange<UInt8> = 0...3
  public let playerCount: Int
  private var peers: [UInt8: PeerMembership]
  private var reliableChannelsInOrder = true
  private var queuesAtLowWater = true
  private var hostLinkDown = false
  public let peerTimeoutMs: Int64
  private var lastHeardMs: [UInt8: Int64]
  public private(set) var fireLocked = false

  private init(validatedPlayerCount playerCount: Int, peerTimeoutMs: Int64) {
    self.playerCount = playerCount
    self.peerTimeoutMs = max(1, peerTimeoutMs)
    peers = [Self.hostSlot: .active]
    lastHeardMs = [Self.hostSlot: 0]
    for slot in 1..<UInt8(playerCount) {
      peers[slot] = .active
      lastHeardMs[slot] = 0
    }
  }

  public init(playerCount: Int, peerTimeoutMs: Int64 = 1_000) throws {
    guard (2...4).contains(playerCount) else {
      throw TopologyError.invalidPlayerCount
    }
    self.init(validatedPlayerCount: playerCount, peerTimeoutMs: peerTimeoutMs)
  }

  static func defaultTopology() -> HostRelayTopology {
    HostRelayTopology(validatedPlayerCount: 2, peerTimeoutMs: 1_000)
  }

  public var activeSlots: [UInt8] {
    peers.filter { $0.value == .active }.map(\.key).sorted()
  }

  public var expectedPeerSlots: [UInt8] {
    peers.keys.filter { $0 != Self.hostSlot }.sorted()
  }

  public func outboundRoute(for slot: UInt8) -> [UInt8] {
    guard slot != Self.hostSlot, peers[slot] != nil else { return [] }
    return [Self.hostSlot]
  }

  public func relayTargets(from origin: UInt8) -> [UInt8] {
    activeSlots.filter { slot in
      slot != origin && (origin == Self.hostSlot || slot != Self.hostSlot)
    }
  }

  public func status(for slot: UInt8) -> PeerMembership? {
    peers[slot]
  }

  public mutating func assignNextSlot() throws -> UInt8 {
    guard let slot = Self.validSlots.first(where: { peers[$0] == nil }) else {
      throw TopologyError.playerCountFull
    }
    peers[slot] = .active
    lastHeardMs[slot] = 0
    return slot
  }

  public mutating func disconnect(slot: UInt8) throws -> [TransportEffect] {
    guard slot != Self.hostSlot else { throw TopologyError.cannotRemoveHost }
    guard peers[slot] != nil else { throw TopologyError.invalidSlot }
    peers[slot] = .disconnected
    return engageFireLock(.peerDisconnected(slot: slot))
  }

  public mutating func recover(slot: UInt8, nowMs: Int64 = 0) throws -> [TransportEffect] {
    guard peers[slot] != nil else {
      throw TopologyError.invalidSlot
    }
    peers[slot] = .active
    lastHeardMs[slot] = nowMs
    if slot == Self.hostSlot {
      hostLinkDown = false
    }
    let effects = [TransportEffect.peerRecovered(slot: slot)]
    return effects + releaseIfHealthy()
  }

  public mutating func markReliableGapUnrecoverable(slot: UInt8) -> [TransportEffect] {
    reliableChannelsInOrder = false
    return engageFireLock(.reliableGapUnrecoverable(slot: slot))
  }

  public mutating func rejectReliableQueueFull() -> [TransportEffect] {
    queuesAtLowWater = false
    return engageFireLock(.rejectedReliableQueueFull)
  }

  public mutating func markHostLinkDown() -> [TransportEffect] {
    hostLinkDown = true
    return engageFireLock(nil)
  }

  public mutating func markHeard(slot: UInt8, nowMs: Int64) -> [TransportEffect] {
    guard slot != Self.hostSlot, peers[slot] != nil else { return [] }
    lastHeardMs[slot] = nowMs
    return []
  }

  public mutating func resetEpoch(_ epoch: UInt16) -> [TransportEffect] {
    [.epochReset(epoch: epoch)]
  }

  public mutating func advance(
    nowMs: Int64,
    reliableChannelsInOrder: Bool,
    poseQueueCount: Int,
    reliableQueueCount: Int,
    lowWaterMark: Int
  ) -> [TransportEffect] {
    self.reliableChannelsInOrder = reliableChannelsInOrder
    queuesAtLowWater = poseQueueCount <= lowWaterMark && reliableQueueCount <= lowWaterMark
    var effects: [TransportEffect] = []
    for slot in expectedPeerSlots where peers[slot] == .active {
      guard let lastHeard = lastHeardMs[slot],
            nowMs - lastHeard > peerTimeoutMs
      else { continue }
      peers[slot] = .disconnected
      effects += engageFireLock(.peerDisconnected(slot: slot))
    }
    effects += releaseIfHealthy()
    return effects
  }

  private mutating func engageFireLock(_ cause: TransportEffect?) -> [TransportEffect] {
    guard !fireLocked else { return cause.map { [$0] } ?? [] }
    fireLocked = true
    return (cause.map { [$0] } ?? []) + [.fireLockEngaged]
  }

  private mutating func releaseIfHealthy() -> [TransportEffect] {
    guard fireLocked,
          !hostLinkDown,
          activeSlots.count == peers.count,
          reliableChannelsInOrder,
          queuesAtLowWater
    else { return [] }
    fireLocked = false
    return [.fireLockReleased]
  }
}
