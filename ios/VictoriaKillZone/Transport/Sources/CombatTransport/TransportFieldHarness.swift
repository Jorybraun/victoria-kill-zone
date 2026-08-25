import Foundation

public final class TransportFieldHarness {
  private var fabric: LoopbackFabric?
  private let seed: UInt64

  public init(seed: UInt64 = 1) {
    self.seed = seed
  }

  public func startHostAndClient(playerCount: Int = 2) {
    fabric = LoopbackFabric(playerCount: playerCount, seed: seed)
  }

  public func drivePoseCadence(seconds: Int, senderSlot: UInt8 = 1) throws {
    guard let fabric else { return }
    let client = fabric.client(slot: senderSlot)
    let totalFrames = max(0, seconds) * 30
    for index in 0..<totalFrames {
      let timestamp = Int64(index + 1) * 33
      try client.send(
        PoseFrame(
          epoch: 1,
          senderSlot: senderSlot,
          sequence: UInt32(index + 1),
          timestampMs: timestamp,
          position: SIMD3<Float>(0, 0, 0),
          orientation: SIMD4<Float>(0, 0, 0, 1),
          tracking: .normal
        )
      )
      fabric.advance(to: timestamp)
    }
  }

  public func sanitizedStatsSnapshot() throws -> Data {
    guard let fabric else {
      let empty = TransportStats()
      return try empty.sanitizedSnapshotData()
    }
    return try fabric.sanitizedStatsSnapshotData()
  }
}
