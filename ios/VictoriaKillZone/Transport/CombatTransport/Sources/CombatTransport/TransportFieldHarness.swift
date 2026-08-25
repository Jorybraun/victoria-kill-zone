import Foundation

public final class TransportFieldHarness {
  private let link: any PeerLink
  private var stats: TransportStats
  private var nowMs: Int64 = 0

  public init(link: any PeerLink) {
    self.link = link
    stats = TransportStats(evidenceTier: link.evidenceTier)
  }

  public func startHostAndClient(playerCount: Int = 2) {
    _ = playerCount
    link.start()
  }

  public func drivePoseCadence(seconds: Int, senderSlot: UInt8 = 1) throws {
    let totalFrames = max(0, seconds) * 30
    for index in 0..<totalFrames {
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
      try link.send(.pose(frame))
    }
  }

  public func sanitizedStatsSnapshot() throws -> Data {
    try stats.sanitizedSnapshotData(nowMs: nowMs)
  }
}
