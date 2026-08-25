import Foundation

public enum PoseDiscardReason: Equatable, Sendable {
  case invalidSlot
  case epochMismatch
  case duplicateSequence
  case staleSequence
  case staleTimestamp
}

public struct PoseAdmission: Equatable, Sendable {
  public let accepted: Bool
  public let frame: PoseFrame?
  public let discardedReason: PoseDiscardReason?

  public init(
    accepted: Bool,
    frame: PoseFrame? = nil,
    discardedReason: PoseDiscardReason? = nil
  ) {
    self.accepted = accepted
    self.frame = frame
    self.discardedReason = discardedReason
  }
}

public struct PoseInbox: Equatable, Sendable {
  private struct Cursor: Equatable, Sendable {
    var epoch: UInt16
    var sequence: UInt32
    var timestampMs: Int64
  }

  private var cursors: [UInt8: Cursor] = [:]
  private var latest: [UInt8: PoseFrame] = [:]
  public private(set) var admittedHistory: [PoseFrame] = []

  public init() {}

  public mutating func admit(_ frame: PoseFrame) -> PoseAdmission {
    guard frame.senderSlot <= 3 else {
      return PoseAdmission(accepted: false, discardedReason: .invalidSlot)
    }
    guard let cursor = cursors[frame.senderSlot] else {
      cursors[frame.senderSlot] = Cursor(
        epoch: frame.epoch,
        sequence: frame.sequence,
        timestampMs: frame.timestampMs
      )
      latest[frame.senderSlot] = frame
      admittedHistory.append(frame)
      return PoseAdmission(accepted: true, frame: frame)
    }
    if frame.epoch > cursor.epoch {
      cursors[frame.senderSlot] = Cursor(
        epoch: frame.epoch,
        sequence: frame.sequence,
        timestampMs: frame.timestampMs
      )
      latest[frame.senderSlot] = frame
      admittedHistory.append(frame)
      return PoseAdmission(accepted: true, frame: frame)
    }
    guard frame.epoch == cursor.epoch else {
      return PoseAdmission(accepted: false, discardedReason: .epochMismatch)
    }
    guard frame.sequence > cursor.sequence else {
      return PoseAdmission(
        accepted: false,
        discardedReason: frame.sequence == cursor.sequence
          ? .duplicateSequence
          : .staleSequence
      )
    }
    guard frame.timestampMs > cursor.timestampMs else {
      return PoseAdmission(accepted: false, discardedReason: .staleTimestamp)
    }
    cursors[frame.senderSlot] = Cursor(
      epoch: frame.epoch,
      sequence: frame.sequence,
      timestampMs: frame.timestampMs
    )
    latest[frame.senderSlot] = frame
    admittedHistory.append(frame)
    return PoseAdmission(accepted: true, frame: frame)
  }

  public func latestFrame(for senderSlot: UInt8) -> PoseFrame? {
    latest[senderSlot]
  }

  public mutating func reset(senderSlot: UInt8) {
    cursors[senderSlot] = nil
    latest[senderSlot] = nil
    admittedHistory.removeAll { $0.senderSlot == senderSlot }
  }

  public func cursor(for senderSlot: UInt8) -> (epoch: UInt16, sequence: UInt32, timestampMs: Int64)? {
    guard let cursor = cursors[senderSlot] else { return nil }
    return (cursor.epoch, cursor.sequence, cursor.timestampMs)
  }

  public var admittedFrames: [UInt8: PoseFrame] { latest }
}
