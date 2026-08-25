import Foundation

public struct CombatTransportCore: Equatable, Sendable {
  public let slot: UInt8
  public private(set) var epoch: UInt16
  public private(set) var poseInbox = PoseInbox()
  public private(set) var reliableOrderers: [UInt8: ReliableEventOrderer] = [:]
  public private(set) var poseQueue = PoseSendQueue()
  public private(set) var reliableQueue = ReliableSendQueue()
  public private(set) var stats = TransportStats()
  public private(set) var deliveredReliable: [UInt8: [ReliableEventFrame]] = [:]
  public private(set) var lastEffects: [TransportEffect] = []
  public private(set) var fireLocked = false

  public init(slot: UInt8, epoch: UInt16 = 1) {
    self.slot = slot
    self.epoch = epoch
  }

  public mutating func resetEpoch(_ newEpoch: UInt16) {
    guard newEpoch > epoch else { return }
    epoch = newEpoch
    poseInbox = PoseInbox()
    reliableOrderers.removeAll()
    fireLocked = false
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
      fireLocked = true
      lastEffects = [.rejectedReliableQueueFull, .fireLockEngaged]
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
      sentAtMs: sentAtMs
    )
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
      sentAtMs: sentAtMs
    )
    deliveredReliable[frame.senderSlot, default: []].append(contentsOf: delivery.frames)
    if delivery.status == .unrecoverableGap {
      fireLocked = true
      lastEffects = [.reliableGapUnrecoverable(slot: frame.senderSlot), .fireLockEngaged]
    }
    return delivery
  }

  public func latestPose(for senderSlot: UInt8) -> PoseFrame? {
    poseInbox.latestFrame(for: senderSlot)
  }

  public func deliveredReliableEvents(for senderSlot: UInt8) -> [ReliableEventFrame] {
    deliveredReliable[senderSlot] ?? []
  }
}
