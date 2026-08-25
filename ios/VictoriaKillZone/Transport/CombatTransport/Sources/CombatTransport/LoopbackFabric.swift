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

public enum LoopbackEndpointError: Error, Equatable, Sendable {
  case relayedFrameNotAllowed
  case slotClaimNotAllowed
}

public final class LoopbackEndpoint: PeerLink, @unchecked Sendable {
  public let slot: UInt8
  public let remoteSlot: UInt8
  public let evidenceTier: TransportEvidenceTier = .loopbackSimulated
  public let deliversOrderedReliableFrames = false
  private let fabric: LoopbackFabric
  private var receiveHandler: PeerLinkReceiveHandler?

  fileprivate init(slot: UInt8, remoteSlot: UInt8, fabric: LoopbackFabric) {
    self.slot = slot
    self.remoteSlot = remoteSlot
    self.fabric = fabric
  }

  public func send(_ frame: PoseFrame) throws {
    try fabric.schedule(.pose(frame, relayed: false), from: slot)
  }

  public func send(_ frame: ReliableEventFrame) throws {
    try fabric.schedule(.reliable(frame, relayed: false), from: slot)
  }

  public func send(_ frame: TransportFrame) throws {
    switch frame {
    case let .pose(value, relayed):
      guard !relayed else { throw LoopbackEndpointError.relayedFrameNotAllowed }
      try fabric.schedule(.pose(value, relayed: relayed), from: slot)
    case let .reliable(value, relayed):
      guard !relayed else { throw LoopbackEndpointError.relayedFrameNotAllowed }
      try fabric.schedule(.reliable(value, relayed: relayed), from: slot)
    case .slotClaim, .pairingOffer, .pairingClaim:
      throw LoopbackEndpointError.slotClaimNotAllowed
    }
  }

  public func setReceiveHandler(_ handler: PeerLinkReceiveHandler?) {
    receiveHandler = handler
  }

  public func advance(to targetMs: Int64) {
    fabric.advance(to: targetMs)
  }

  public func start() {}
  public func stop() {}

  fileprivate func notify(
    _ frame: TransportFrame,
    arrivalMs: Int64,
    sentAtMs: Int64
  ) {
    receiveHandler?(frame, arrivalMs, sentAtMs)
  }

  public func latestPose(for senderSlot: UInt8) -> PoseFrame? {
    fabric.latestPose(for: senderSlot, at: slot)
  }

  public func deliveredReliableEvents(for senderSlot: UInt8) -> [ReliableEventFrame] {
    fabric.deliveredReliableEvents(for: senderSlot, at: slot)
  }
}

public final class LoopbackFabric {
  fileprivate enum Payload {
    case pose(PoseFrame, relayed: Bool)
    case reliable(ReliableEventFrame, relayed: Bool)
  }

  private struct Scheduled {
    let dueMs: Int64
    let ordinal: UInt64
    let origin: UInt8
    let destination: UInt8
    let payload: Payload
    let sentAtMs: Int64
  }

  private var random: SeededRandom
  private var defaultProfile: FaultProfile
  private var directionalProfiles: [String: FaultProfile] = [:]
  private var scheduled: [Scheduled] = []
  private var endpoints: [UInt8: LoopbackEndpoint] = [:]
  private var cores: [UInt8: CombatTransportCore] = [:]
  private var epochs: [UInt8: UInt16] = [:]
  private var ordinal: UInt64 = 0
  private(set) public var nowMs: Int64 = 0
  private(set) public var topology: HostRelayTopology
  public let playerCount: Int

  public init(
    playerCount: Int,
    faultProfile: FaultProfile = FaultProfile(),
    seed: UInt64 = 1
  ) {
    precondition((2...4).contains(playerCount))
    self.playerCount = playerCount
    self.defaultProfile = faultProfile
    self.random = SeededRandom(seed: seed)
    self.topology = try! HostRelayTopology(playerCount: playerCount)
    for slot in 0..<UInt8(playerCount) {
      cores[slot] = CombatTransportCore(
        slot: slot,
        topology: topology,
        evidenceTier: .loopbackSimulated
      )
      epochs[slot] = 1
    }
    endpoints[0] = LoopbackEndpoint(slot: 0, remoteSlot: 0, fabric: self)
    for slot in 1..<UInt8(playerCount) {
      endpoints[slot] = LoopbackEndpoint(slot: slot, remoteSlot: 0, fabric: self)
    }
  }

  public var host: LoopbackEndpoint { endpoints[0]! }

  public func client(slot: UInt8) -> LoopbackEndpoint {
    precondition(slot != 0 && slot < UInt8(playerCount))
    return endpoints[slot]!
  }

  public var hostCore: CombatTransportCore { cores[0]! }

  public func core(for slot: UInt8) -> CombatTransportCore { cores[slot]! }

  public func epoch(for slot: UInt8) -> UInt16 { epochs[slot] ?? 1 }

  @discardableResult
  public func disconnect(slot: UInt8) throws -> [TransportEffect] {
    guard var host = cores[0] else { return [] }
    let effects = try host.disconnectPeer(slot, at: nowMs)
    cores[0] = host
    topology = host.topology
    return effects
  }

  @discardableResult
  public func recover(slot: UInt8) throws -> [TransportEffect] {
    guard var host = cores[0] else { return [] }
    let effects = try host.recoverPeer(slot, at: nowMs)
    cores[0] = host
    topology = host.topology
    let nextEpoch = (epochs[slot] ?? 1) &+ 1
    epochs[slot] = nextEpoch
    host.resetPeerEpoch(slot, nextEpoch)
    cores[0] = host
    return effects
  }

  public func setFaultProfile(_ profile: FaultProfile, from: UInt8, to: UInt8) {
    directionalProfiles["\(from):\(to)"] = profile
  }

  fileprivate func schedule(_ payload: Payload, from origin: UInt8) throws {
    let destinations: [UInt8]
    switch payload {
    case let .pose(_, relayed), let .reliable(_, relayed):
      if relayed {
        destinations = [origin]
      } else if origin == HostRelayTopology.hostSlot {
        destinations = topology.relayTargets(from: origin)
      } else {
        let route = topology.outboundRoute(for: origin)
        precondition(route == [HostRelayTopology.hostSlot])
        destinations = route
      }
    }
    for destination in destinations {
      schedule(payload, from: origin, to: destination)
    }
  }

  private func schedule(_ payload: Payload, from origin: UInt8, to destination: UInt8) {
    let profile = directionalProfiles["\(origin):\(destination)"] ?? defaultProfile
    switch payload {
    case .pose:
      if random.nextInt(100) < profile.poseLossPercent { return }
    case .reliable:
      break
    }
    let jitter = profile.jitterMs == 0 ? 0 : random.nextInt(profile.jitterMs + 1)
    let reorder = profile.reliableReorderPercent > 0 &&
      random.nextInt(100) < profile.reliableReorderPercent
      ? random.nextInt(max(1, profile.jitterMs + 1))
      : 0
    let delay = profile.baseLatencyMs + jitter + reorder
    ordinal += 1
    scheduled.append(
      Scheduled(
        dueMs: nowMs + Int64(delay),
        ordinal: ordinal,
        origin: origin,
        destination: destination,
        payload: payload,
        sentAtMs: nowMs
      )
    )
    if case let .reliable(frame, relayed) = payload,
       !relayed,
       profile.reliableDuplicatePercent > 0,
       random.nextInt(100) < profile.reliableDuplicatePercent {
      ordinal += 1
      scheduled.append(
        Scheduled(
          dueMs: nowMs + Int64(delay + 1),
          ordinal: ordinal,
          origin: origin,
          destination: destination,
          payload: .reliable(frame, relayed: relayed),
          sentAtMs: nowMs
        )
      )
    }
  }

  public func advance(to targetMs: Int64) {
    guard targetMs >= nowMs else { return }
    while let index = scheduled.enumerated()
      .filter({ $0.element.dueMs <= targetMs })
      .min(by: {
        if $0.element.dueMs == $1.element.dueMs {
          return $0.element.ordinal < $1.element.ordinal
        }
        return $0.element.dueMs < $1.element.dueMs
      })?.offset {
      let event = scheduled.remove(at: index)
      nowMs = max(nowMs, event.dueMs)
      deliver(event)
    }
    nowMs = targetMs
    for slot in 0..<UInt8(playerCount) {
      guard var core = cores[slot] else { continue }
      _ = core.advance(nowMs: nowMs)
      cores[slot] = core
      if slot == HostRelayTopology.hostSlot {
        topology = core.topology
      }
    }
  }

  private func deliver(_ event: Scheduled) {
    guard var destinationCore = cores[event.destination] else { return }
    switch event.payload {
    case let .pose(frame, relayed):
      let admission = destinationCore.receivePose(
        frame,
        receivedAtMs: nowMs,
        sentAtMs: event.sentAtMs
      )
      cores[event.destination] = destinationCore
      endpoints[event.destination]?.notify(
        .pose(frame, relayed: relayed),
        arrivalMs: nowMs,
        sentAtMs: event.sentAtMs
      )
      if event.destination == HostRelayTopology.hostSlot {
        topology = destinationCore.topology
      }
      if event.destination == HostRelayTopology.hostSlot, !relayed, admission.accepted {
        relay(frame: .pose(frame, relayed: true), origin: frame.senderSlot)
      }
    case let .reliable(frame, relayed):
      let delivery = destinationCore.receiveReliable(
        frame,
        receivedAtMs: nowMs,
        sentAtMs: event.sentAtMs
      )
      cores[event.destination] = destinationCore
      endpoints[event.destination]?.notify(
        .reliable(frame, relayed: relayed),
        arrivalMs: nowMs,
        sentAtMs: event.sentAtMs
      )
      if event.destination == HostRelayTopology.hostSlot {
        topology = destinationCore.topology
      }
      if event.destination == HostRelayTopology.hostSlot, !relayed {
        for deliveredFrame in delivery.frames {
          relay(
            frame: .reliable(deliveredFrame, relayed: true),
            origin: deliveredFrame.senderSlot
          )
        }
      }
    }
  }

  private func relay(frame: Payload, origin: UInt8) {
    for destination in topology.relayTargets(from: origin) where destination != 0 {
      schedule(frame, from: 0, to: destination)
    }
  }

  public func latestPose(for senderSlot: UInt8, at receiverSlot: UInt8 = 0) -> PoseFrame? {
    cores[receiverSlot]?.latestPose(for: senderSlot)
  }

  public func deliveredReliableEvents(
    for senderSlot: UInt8,
    at receiverSlot: UInt8 = 0
  ) -> [ReliableEventFrame] {
    cores[receiverSlot]?.deliveredReliableEvents(for: senderSlot) ?? []
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
