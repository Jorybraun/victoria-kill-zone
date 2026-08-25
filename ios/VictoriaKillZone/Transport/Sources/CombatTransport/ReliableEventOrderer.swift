import Foundation

public enum ReliableDeliveryStatus: Equatable, Sendable {
  case delivered
  case duplicate
  case buffered
  case epochMismatch
  case unrecoverableGap
}

public struct ReliableDelivery: Equatable, Sendable {
  public let status: ReliableDeliveryStatus
  public let frames: [ReliableEventFrame]

  public init(status: ReliableDeliveryStatus, frames: [ReliableEventFrame] = []) {
    self.status = status
    self.frames = frames
  }
}

public struct ReliableEventOrderer: Equatable, Sendable {
  private struct SenderState: Equatable, Sendable {
    var epoch: UInt16
    var nextSequence: UInt32
    var pending: [UInt32: ReliableEventFrame]
  }

  public let maxPendingReliableEvents: Int
  private var senders: [UInt8: SenderState] = [:]

  public init(maxPendingReliableEvents: Int = 128) {
    self.maxPendingReliableEvents = max(1, maxPendingReliableEvents)
  }

  public mutating func ingest(_ frame: ReliableEventFrame) -> ReliableDelivery {
    guard frame.senderSlot <= 3 else {
      return ReliableDelivery(status: .epochMismatch)
    }
    var state = senders[frame.senderSlot] ?? SenderState(
      epoch: frame.epoch,
      nextSequence: 1,
      pending: [:]
    )
    if frame.epoch > state.epoch {
      state = SenderState(
        epoch: frame.epoch,
        nextSequence: 1,
        pending: [:]
      )
    }
    guard frame.epoch == state.epoch else {
      return ReliableDelivery(status: .epochMismatch)
    }
    if frame.sequence < state.nextSequence ||
      state.pending[frame.sequence] != nil {
      return ReliableDelivery(status: .duplicate)
    }
    if frame.sequence > state.nextSequence {
      guard state.pending.count < maxPendingReliableEvents else {
        return ReliableDelivery(status: .unrecoverableGap)
      }
      state.pending[frame.sequence] = frame
      senders[frame.senderSlot] = state
      return ReliableDelivery(status: .buffered)
    }

    var delivered = [frame]
    state.nextSequence += 1
    while let next = state.pending.removeValue(forKey: state.nextSequence) {
      delivered.append(next)
      state.nextSequence += 1
    }
    senders[frame.senderSlot] = state
    return ReliableDelivery(status: .delivered, frames: delivered)
  }

  public func nextExpectedSequence(for senderSlot: UInt8) -> UInt32 {
    senders[senderSlot]?.nextSequence ?? 1
  }

  public func pendingCount(for senderSlot: UInt8) -> Int {
    senders[senderSlot]?.pending.count ?? 0
  }
}
