import CombatTransport
import Foundation

struct ArenaLinkFrameMapper {
  static let controlBodyLimit = TransportFrameCodec.maxPayloadLength - 1

  private let senderSlot: UInt8
  private let epoch: UInt16
  private let maxBulkLength: Int
  private var nextSequence: UInt32 = 1
  private var nextTransferID: UInt32 = 1
  private var assembler: BulkTransferAssembler
  var onRejection: ((BulkAssemblyRejection) -> Void)?

  init(
    senderSlot: UInt8,
    epoch: UInt16,
    maxBulkLength: Int = BulkChunker.maxTransferLength,
    onRejection: ((BulkAssemblyRejection) -> Void)? = nil
  ) {
    self.senderSlot = senderSlot
    self.epoch = epoch
    self.maxBulkLength = maxBulkLength
    self.assembler = BulkTransferAssembler(maxTransferLength: maxBulkLength)
    self.onRejection = onRejection
  }

  mutating func outbound(_ message: ArenaLinkMessage) throws -> [ReliableEventFrame] {
    let encoded = try ArenaLinkBodyCodec.encode(message)
    switch message {
    case .hello, .poseSample, .anchorSet:
      if encoded.body.count <= Self.controlBodyLimit {
        return [nextFrame(kind: .control, payload: Data([encoded.kind]) + encoded.body)]
      }
      return try bulkFrames(kind: .arenaHandshake, payload: Data([encoded.kind]) + encoded.body)
    case .collaboration:
      return try bulkFrames(kind: .arCollaborationData, payload: encoded.body)
    case .worldMap:
      return try bulkFrames(kind: .arWorldMap, payload: encoded.body)
    case .shotTracer, .shotRetracted:
      return [nextFrame(kind: .fire, payload: encoded.body)]
    }
  }

  mutating func inbound(_ frame: ReliableEventFrame) -> ArenaLinkMessage? {
    if frame.eventKind == .bulkChunk {
      let outcome = assembler.ingest(frame)
      guard case let .completed(transfer) = outcome else {
        if case let .rejected(_, rejection) = outcome {
          onRejection?(rejection)
        }
        return nil
      }
      switch transfer.contentKind {
      case .arCollaborationData:
        return .collaboration(transfer.payload)
      case .arWorldMap:
        return .worldMap(transfer.payload)
      case .arenaHandshake:
        guard let kind = transfer.payload.first else {
          onRejection?(.malformedChunk(.truncatedChunk))
          return nil
        }
        do {
          return try ArenaLinkBodyCodec.decode(
            kind: kind,
            body: Data(transfer.payload.dropFirst())
          )
        } catch {
          onRejection?(.malformedChunk(.truncatedChunk))
          return nil
        }
      }
    }

    switch frame.eventKind {
    case .control:
      guard let kind = frame.payload.first else { return nil }
      do {
        return try ArenaLinkBodyCodec.decode(
          kind: kind,
          body: Data(frame.payload.dropFirst())
        )
      } catch {
        return nil
      }
    case .fire:
      do {
        return try ArenaLinkBodyCodec.decode(kind: 6, body: frame.payload)
      } catch {
        do {
          return try ArenaLinkBodyCodec.decode(kind: 7, body: frame.payload)
        } catch {
          return nil
        }
      }
    case .bulkChunk:
      return nil
    }
  }

  mutating func reserveSequence() {
    nextSequence &+= 1
  }

  private mutating func nextFrame(
    kind: ReliableEventKind,
    payload: Data
  ) -> ReliableEventFrame {
    defer { nextSequence &+= 1 }
    return ReliableEventFrame(
      epoch: epoch,
      senderSlot: senderSlot,
      sequence: nextSequence,
      eventKind: kind,
      payload: payload
    )
  }

  private mutating func bulkFrames(
    kind: BulkContentKind,
    payload: Data
  ) throws -> [ReliableEventFrame] {
    guard payload.count <= maxBulkLength else {
      throw BulkTransferError.payloadTooLarge
    }
    defer { nextTransferID &+= 1 }
    let chunks = try BulkChunker.chunk(payload, transferID: nextTransferID, contentKind: kind)
    let frames = try BulkChunker.frames(
      chunks,
      epoch: epoch,
      senderSlot: senderSlot,
      firstSequence: nextSequence
    )
    nextSequence &+= UInt32(frames.count)
    return frames
  }
}
