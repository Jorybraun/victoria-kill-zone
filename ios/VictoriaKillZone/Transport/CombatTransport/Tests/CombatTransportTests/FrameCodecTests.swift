import Foundation
import XCTest

@testable import CombatTransport

final class FrameCodecTests: XCTestCase {
  private let pose = PoseFrame(
    epoch: 3,
    senderSlot: 2,
    sequence: 7,
    timestampMs: 1234,
    position: SIMD3<Float>(1, 2, 3),
    orientation: SIMD4<Float>(0, 0, 0, 1),
    tracking: .normal
  )

  func testRoundTripsEveryFrameKind() throws {
    let frames: [TransportFrame] = [
      .pose(pose, relayed: true),
      .reliable(
        ReliableEventFrame(
          epoch: 3,
          senderSlot: 2,
          sequence: 9,
          eventKind: .control,
          payload: Data([1, 2, 3])
        )
      ),
    ]
    for frame in frames {
      XCTAssertEqual(try TransportFrameCodec.decode(try TransportFrameCodec.encode(frame)), frame)
    }
  }

  func testRoundTripsAuthenticatedSlotClaim() throws {
    let frame = TransportFrame.slotClaim(
      SlotClaimFrame(
        claimedSlot: 2,
        nonce: 0xAABBCCDD,
        digest: Data(repeating: 7, count: 32)
      )
    )
    XCTAssertEqual(
      try TransportFrameCodec.decode(try TransportFrameCodec.encode(frame)),
      frame
    )
  }

  func testEveryPosePrefixIsTruncated() throws {
    let encoded = try TransportFrameCodec.encode(.pose(pose))
    for length in 0..<encoded.count {
      XCTAssertThrowsError(try TransportFrameCodec.decode(encoded.prefix(length))) { error in
        XCTAssertEqual(error as? TransportCodecError, .truncated)
      }
    }
  }

  func testEveryReliablePrefixIsTruncated() throws {
    let frame: TransportFrame = .reliable(
      ReliableEventFrame(
        epoch: 3,
        senderSlot: 2,
        sequence: 9,
        eventKind: .control,
        payload: Data([1, 2, 3])
      )
    )
    let encoded = try TransportFrameCodec.encode(frame)
    for length in 0..<encoded.count {
      XCTAssertThrowsError(try TransportFrameCodec.decode(encoded.prefix(length))) { error in
        XCTAssertEqual(error as? TransportCodecError, .truncated)
      }
    }
  }

  func testMalformedInputsThrowTypedErrors() throws {
    let encoded = try TransportFrameCodec.encode(.pose(pose))
    var cases: [(Data, TransportCodecError)] = []
    var magic = encoded
    magic[0] = 0
    cases.append((magic, .magicMismatch))
    var version = encoded
    version[2] = 9
    cases.append((version, .unsupportedVersion))
    var kind = encoded
    kind[3] = 9
    cases.append((kind, .unknownFrameKind))
    var slot = encoded
    slot[6] = 4
    cases.append((slot, .slotOutOfRange))
    var flags = encoded
    flags[7] = 2
    cases.append((flags, .reservedFlagSet))
    var sequence = encoded
    sequence[8] = 0
    sequence[9] = 0
    sequence[10] = 0
    sequence[11] = 0
    cases.append((sequence, .zeroSequence))
    var timestamp = encoded
    timestamp.replaceSubrange(12..<20, with: Array(repeating: 0, count: 8))
    cases.append((timestamp, .nonPositiveTimestamp))
    var tracking = encoded
    tracking[48] = 3
    cases.append((tracking, .invalidTracking))
    var trailing = encoded
    trailing.append(0)
    cases.append((trailing, .trailingBytes))

    var eventKind = try TransportFrameCodec.encode(
      .reliable(
        ReliableEventFrame(
          epoch: 1,
          senderSlot: 1,
          sequence: 1,
          eventKind: .fire,
          payload: Data()
        )
      )
    )
    eventKind[12] = 99
    cases.append((eventKind, .invalidEventKind))
    var tooLarge = eventKind
    tooLarge[12] = ReliableEventKind.control.rawValue
    tooLarge.replaceSubrange(13..<15, with: [0x01, 0x02])
    tooLarge.append(Data(repeating: 0, count: 513))
    cases.append((tooLarge, .payloadTooLarge))
    var mismatched = try TransportFrameCodec.encode(
      .reliable(
        ReliableEventFrame(
          epoch: 1,
          senderSlot: 1,
          sequence: 1,
          eventKind: .fire,
          payload: Data([1, 2])
        )
      )
    )
    mismatched[13] = 1
    cases.append((mismatched, .payloadLengthMismatch))

    for (data, expected) in cases {
      XCTAssertThrowsError(try TransportFrameCodec.decode(data)) { error in
        XCTAssertEqual(error as? TransportCodecError, expected)
      }
    }
  }

  func testBitFlipFuzzNeverTraps() throws {
    let original = try TransportFrameCodec.encode(.pose(pose))
    var state: UInt64 = 0x12345678
    for _ in 0..<1_000 {
      state = state &* 6364136223846793005 &+ 1
      let index = Int(state % UInt64(original.count))
      state = state &* 6364136223846793005 &+ 1
      let bit = UInt8(1 << (state % 8))
      var mutated = original
      mutated[index] ^= bit
      if let decoded = try? TransportFrameCodec.decode(mutated) {
        XCTAssertEqual(try TransportFrameCodec.encode(decoded), mutated)
      }
    }
  }
}
