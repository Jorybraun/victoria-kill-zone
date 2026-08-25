import Foundation

public struct CombatTransportCore: Equatable, Sendable {
  public let slot: UInt8
  public private(set) var epoch: UInt16
  public private(set) var topology: HostRelayTopology
  public private(set) var poseInbox = PoseInbox()
  public private(set) var reliableOrderers: [UInt8: ReliableEventOrderer] = [:]
  public private(set) var poseQueue = PoseSendQueue()
  public private(set) var reliableQueue = ReliableSendQueue()
  public private(set) var stats: TransportStats
  public private(set) var deliveredReliable: [UInt8: [ReliableEventFrame]] = [:]
  public private(set) var lastEffects: [TransportEffect] = []
  public var fireLocked: Bool { topology.fireLocked }

  public init(
    slot: UInt8,
    epoch: UInt16 = 1,
    topology: HostRelayTopology? = nil,
    evidenceTier: TransportEvidenceTier = .loopbackSimulated
  ) {
    self.slot = slot
    self.epoch = epoch
    self.topology = topology ?? .defaultTopology()
    stats = TransportStats(evidenceTier: evidenceTier)
  }

  public mutating func resetEpoch(_ newEpoch: UInt16) {
    guard newEpoch > epoch else { return }
    epoch = newEpoch
    poseInbox = PoseInbox()
    reliableOrderers.removeAll()
    apply(topology.resetEpoch(newEpoch), at: 0)
  }

  public mutating func resetPeerEpoch(_ peer: UInt8, _ newEpoch: UInt16) {
    poseInbox.reset(senderSlot: peer)
    reliableOrderers[peer] = nil
    deliveredReliable[peer] = nil
    apply(topology.resetEpoch(newEpoch), at: 0)
  }

  @discardableResult
  public mutating func enqueuePose(_ frame: PoseFrame) -> PoseQueueEnqueueResult {
    stats.recordSent(channel: .pose, slot: frame.senderSlot)
    return poseQueue.enqueue(frame)
  }

  @discardableResult
  public mutating func enqueueReliable(_ frame: ReliableEventFrame) -> ReliableQueueEnqueueResult {
    stats.recordSent(channel: .reliable, slot: frame.senderSlot)
    let result = reliableQueue.enqueue(frame)
    if result == .rejectedQueueFull {
      apply(topology.rejectReliableQueueFull(), at: 0)
      lastEffects = [.rejectedReliableQueueFull] + lastEffects
    }
    return result
  }

  public mutating func receivePose(
    _ frame: PoseFrame,
    receivedAtMs: Int64,
    sentAtMs: Int64? = nil
  ) -> PoseAdmission {
    let admission = poseInbox.admit(frame)
    stats.recordReceived(
      channel: .pose,
      slot: frame.senderSlot,
      accepted: admission.accepted,
      duplicate: admission.discardedReason == .duplicateSequence,
      arrivalMs: receivedAtMs,
      sentAtMs: sentAtMs,
      sequence: frame.sequence,
      epoch: frame.epoch
    )
    apply(topology.markHeard(slot: frame.senderSlot, nowMs: receivedAtMs), at: receivedAtMs)
    return admission
  }

  public mutating func receiveReliable(
    _ frame: ReliableEventFrame,
    receivedAtMs: Int64,
    sentAtMs: Int64? = nil
  ) -> ReliableDelivery {
    var orderer = reliableOrderers[frame.senderSlot] ?? ReliableEventOrderer()
    let delivery = orderer.ingest(frame)
    reliableOrderers[frame.senderSlot] = orderer
    stats.recordReceived(
      channel: .reliable,
      slot: frame.senderSlot,
      accepted: delivery.status == .delivered,
      duplicate: delivery.status == .duplicate,
      buffered: delivery.status == .buffered,
      arrivalMs: receivedAtMs,
      sentAtMs: sentAtMs,
      sequence: frame.sequence,
      epoch: frame.epoch
    )
    apply(topology.markHeard(slot: frame.senderSlot, nowMs: receivedAtMs), at: receivedAtMs)
    deliveredReliable[frame.senderSlot, default: []].append(contentsOf: delivery.frames)
    if delivery.status == .unrecoverableGap {
      apply(topology.markReliableGapUnrecoverable(slot: frame.senderSlot), at: receivedAtMs)
      lastEffects = [.reliableGapUnrecoverable(slot: frame.senderSlot)] + lastEffects
    }
    return delivery
  }

  public mutating func receiveAlreadyOrderedReliable(
    _ frame: ReliableEventFrame,
    receivedAtMs: Int64,
    sentAtMs: Int64? = nil
  ) -> ReliableDelivery {
    let delivery = ReliableDelivery(status: .delivered, frames: [frame])
    stats.recordReceived(
      channel: .reliable,
      slot: frame.senderSlot,
      accepted: true,
      arrivalMs: receivedAtMs,
      sentAtMs: sentAtMs,
      sequence: frame.sequence,
      epoch: frame.epoch
    )
    apply(topology.markHeard(slot: frame.senderSlot, nowMs: receivedAtMs), at: receivedAtMs)
    deliveredReliable[frame.senderSlot, default: []].append(frame)
    return delivery
  }

  @discardableResult
  public mutating func advance(nowMs: Int64, lowWaterMark: Int = 1) -> [TransportEffect] {
    let effects = topology.advance(
      nowMs: nowMs,
      poseQueueCount: poseQueue.count,
      reliableQueueCount: reliableQueue.count,
      lowWaterMark: lowWaterMark
    )
    apply(effects, at: nowMs)
    return effects
  }

  public mutating func disconnectPeer(_ peer: UInt8, at nowMs: Int64) throws -> [TransportEffect] {
    let effects = try topology.disconnect(slot: peer)
    apply(effects, at: nowMs)
    return effects
  }

  public mutating func recoverPeer(_ peer: UInt8, at nowMs: Int64) throws -> [TransportEffect] {
    let effects = try topology.recover(slot: peer, nowMs: nowMs)
    apply(effects, at: nowMs)
    return effects
  }

  private mutating func apply(_ effects: [TransportEffect], at nowMs: Int64) {
    guard !effects.isEmpty else { return }
    lastEffects = effects
    for effect in effects {
      switch effect {
      case .peerDisconnected:
        stats.recordDisconnect()
      case .peerRecovered:
        stats.recordRecovery()
      case .fireLockEngaged:
        stats.setFireLocked(true, at: nowMs)
      case .fireLockReleased:
        stats.setFireLocked(false, at: nowMs)
      default:
        break
      }
    }
  }

  public func latestPose(for senderSlot: UInt8) -> PoseFrame? {
    poseInbox.latestFrame(for: senderSlot)
  }

  public func deliveredReliableEvents(for senderSlot: UInt8) -> [ReliableEventFrame] {
    deliveredReliable[senderSlot] ?? []
  }
}
