import Foundation

public final class TransportFieldHarness: @unchecked Sendable {
  private let link: any PeerLink
  private let lock = NSLock()
  private var core: CombatTransportCore
  private var stats: TransportStats
  private var nowMs: Int64 = 0

  public init(link: any PeerLink) {
    self.link = link
    core = CombatTransportCore(slot: link.remoteSlot, evidenceTier: link.evidenceTier)
    stats = TransportStats(evidenceTier: link.evidenceTier)
    link.setReceiveHandler { [weak self] frame, arrivalMs, sentAtMs in
      self?.recordReceived(
        frame,
        arrivalMs: arrivalMs,
        sentAtMs: sentAtMs
      )
    }
  }

  public func startHostAndClient() {
    link.start()
  }

  public func drivePoseCadence(seconds: Int, senderSlot: UInt8 = 1) throws {
    let totalFrames = max(0, seconds) * 30
    for index in 0..<totalFrames {
      let frame: PoseFrame = withLock {
        nowMs = Int64(index + 1) * 33
        let frame = PoseFrame(
          epoch: 1,
          senderSlot: senderSlot,
          sequence: UInt32(index + 1),
          timestampMs: nowMs,
          position: SIMD3<Float>(0, 0, 0),
          orientation: SIMD4<Float>(0, 0, 0, 1),
          tracking: .normal
        )
        stats.recordSent(channel: .pose, slot: senderSlot)
        return frame
      }
      try link.send(.pose(frame))
    }
  }

  public func sanitizedStatsSnapshot() throws -> Data {
    try withLock {
      try stats.sanitizedSnapshotData(nowMs: nowMs)
    }
  }

  private func recordReceived(
    _ frame: TransportFrame,
    arrivalMs: Int64,
    sentAtMs: Int64?
  ) {
    withLock {
      switch frame {
      case let .pose(value, _):
        let admission = core.receivePose(
          value,
          receivedAtMs: arrivalMs,
          sentAtMs: sentAtMs
        )
        stats.recordReceived(
          channel: .pose,
          slot: value.senderSlot,
          accepted: admission.accepted,
          arrivalMs: arrivalMs,
          sentAtMs: sentAtMs,
          sequence: value.sequence,
          epoch: value.epoch
        )
      case let .reliable(value, _):
        let delivery = core.receiveReliable(
          value,
          receivedAtMs: arrivalMs,
          sentAtMs: sentAtMs
        )
        stats.recordReceived(
          channel: .reliable,
          slot: value.senderSlot,
          accepted: delivery.status == .delivered,
          duplicate: delivery.status == .duplicate,
          buffered: delivery.status == .buffered,
          arrivalMs: arrivalMs,
          sentAtMs: sentAtMs,
          sequence: value.sequence,
          epoch: value.epoch
        )
      case .slotClaim:
        break
      }
    }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
