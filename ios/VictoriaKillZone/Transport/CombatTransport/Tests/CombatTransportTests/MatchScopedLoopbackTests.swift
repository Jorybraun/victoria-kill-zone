import Foundation
import XCTest

@testable import CombatTransport

final class MatchScopedLoopbackTests: XCTestCase {
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [TransportFrame] = []

    func append(_ frame: TransportFrame) {
      lock.lock()
      frames.append(frame)
      lock.unlock()
    }

    func snapshot() -> [TransportFrame] {
      lock.lock()
      defer { lock.unlock() }
      return frames
    }
  }

  func testFireRetractionAndWorldMapCrossTheLoopbackPeerPlane() throws {
    let fabric = LoopbackFabric(playerCount: 2)
    let host = fabric.host
    let guest = fabric.client(slot: 1)
    let shot = try CombatShotEvent(
      shotId: "guest#1",
      shooterPlayerId: "guest",
      origin: SIMD3<Float>(0, 1, 0),
      direction: SIMD3<Float>(0, 0, -1),
      firedAtMs: 100
    )
    let collector = Collector()
    host.setReceiveHandler { frame, _, _ in collector.append(frame) }
    try guest.send(.reliable(ReliableEventFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: 1,
      eventKind: .fire,
      payload: try CombatFireMessageCodec.encode(.shot(shot))
    )))
    try guest.send(.reliable(ReliableEventFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: 2,
      eventKind: .fire,
      payload: try CombatFireMessageCodec.encode(.retracted(CombatShotRetraction(shotId: shot.shotId)))
    )))

    let worldMap = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 17) })
    let chunks = try BulkChunker.chunk(worldMap, transferID: 1, contentKind: .arWorldMap)
    for frame in try BulkChunker.frames(chunks, epoch: 1, senderSlot: 1, firstSequence: 3) {
      try guest.send(.reliable(frame))
    }
    fabric.advance(to: 1)

    var assembler = BulkTransferAssembler()
    var reassembled: Data?
    let received = collector.snapshot()
    for frame in received.compactMap({ frame -> ReliableEventFrame? in
      guard case let .reliable(reliable, _) = frame else { return nil }
      return reliable
    }) {
      if case let .completed(transfer) = assembler.ingest(frame) {
        reassembled = transfer.payload
      }
    }
    XCTAssertEqual(reassembled, worldMap)
    XCTAssertEqual(
      received.compactMap { frame -> CombatFireMessage? in
        guard case let .reliable(reliable, _) = frame, reliable.eventKind == .fire else {
          return nil
        }
        return try? CombatFireMessageCodec.decode(reliable.payload)
      },
      [.shot(shot), .retracted(CombatShotRetraction(shotId: shot.shotId))]
    )
  }
}
