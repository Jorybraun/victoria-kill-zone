import Foundation
import PewPewSimulation
import CombatTransport

public final class AuthorityPeerAdapter: @unchecked Sendable {
  public let slot: UInt8
  public let roster: AuthorityRoster
  public let link: any PeerLink
  public private(set) var epoch: UInt16
  public private(set) var host: AuthorityHost?
  public private(set) var client: AuthorityClient
  public private(set) var latency = VerdictLatencyTracker()
  public private(set) var clientEffects: [AuthorityClientEffect] = []

  private let codec: AuthorityWireCodec
  private let stateLock = NSLock()
  private var reliableFrameSequence: UInt32 = 0
  private var pendingHostFrames: [UInt32: ReliableEventFrame] = [:]
  private var nextHostFrameSequence: UInt32 = 1

  public init(
    slot: UInt8,
    roster: AuthorityRoster,
    link: any PeerLink,
    epoch: UInt16 = 1,
    hostConfiguration: AuthorityHostConfiguration = .init(),
    clientConfiguration: AuthorityClientConfiguration = .init()
  ) throws {
    guard roster.playerID(for: slot) != nil else {
      throw AuthorityError.unknownSlot(slot)
    }
    self.slot = slot
    self.roster = roster
    self.link = link
    self.epoch = epoch
    self.codec = AuthorityWireCodec(roster: roster)
    self.client = AuthorityClient(
      slot: slot,
      roster: roster,
      configuration: clientConfiguration
    )
    if slot == 0 {
      let authority = try AuthorityHost(
        roster: roster,
        configuration: hostConfiguration,
        startedAtMs: 0
      )
      self.host = authority
      self.clientEffects = []
      self.client = AuthorityClient(slot: slot, roster: roster, configuration: clientConfiguration)
      _ = self.client.receive(.snapshot(authority.snapshot()), atMs: 0)
    }
    link.setReceiveHandler { [weak self] frame, arrivalMs, _ in
      self?.receive(frame, atMs: arrivalMs)
    }
  }

  public func pose(_ sample: PoseSample) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    let effect = client.pose(sample)
    if slot == 0 {
      guard var authority = host,
            case let .send(message) = effect
      else { return }
      let effects = authority.ingest(message, from: slot, atMs: sample.timestampMs)
      host = authority
      processHostEffects(effects, atMs: sample.timestampMs)
    } else {
      try processClientEffects([effect])
    }
  }

  public func fire(_ claim: ShotClaim, atMs: Int64) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    let effects = client.fire(claim, atMs: atMs)
    if slot == 0 {
      guard var authority = host else { return }
      for effect in effects {
        guard case let .send(message) = effect else {
          appendClientEffect(effect)
          continue
        }
        let hostEffects = authority.ingest(message, from: slot, atMs: atMs)
        processHostEffects(hostEffects, atMs: atMs)
      }
      host = authority
    } else {
      try processClientEffects(effects)
    }
  }

  public func reload(atMs: Int64) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    let effects = client.reload(atMs: atMs)
    if slot == 0 {
      guard var authority = host else { return }
      for effect in effects {
        guard case let .send(message) = effect else {
          appendClientEffect(effect)
          continue
        }
        let hostEffects = authority.ingest(message, from: slot, atMs: atMs)
        processHostEffects(hostEffects, atMs: atMs)
      }
      host = authority
    } else {
      try processClientEffects(effects)
    }
  }

  public func applyTransportEffects(
    _ effects: [TransportEffect],
    atMs: Int64
  ) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard slot == 0, var authority = host else { return }
    var hostEffects: [AuthorityHostEffect] = []
    for effect in effects {
      switch effect {
      case let .peerDisconnected(memberSlot):
        hostEffects += authority.memberDropped(memberSlot, atMs: atMs)
      case let .peerRecovered(memberSlot):
        hostEffects += authority.memberRecovered(memberSlot, atMs: atMs)
      default:
        break
      }
    }
    host = authority
    processHostEffects(hostEffects, atMs: atMs)
  }

  public func resetEpoch(_ epoch: UInt16) {
    stateLock.lock()
    defer { stateLock.unlock() }
    self.epoch = epoch
  }

  public func advance(nowMs: Int64) throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    if slot == 0, var authority = host {
      let effects = authority.advance(nowMs: nowMs)
      host = authority
      processHostEffects(effects, atMs: nowMs)
    }
    let effects = client.advance(nowMs: nowMs)
    try processClientEffects(effects)
  }

  public func drainClientEffects() -> [AuthorityClientEffect] {
    stateLock.lock()
    defer { stateLock.unlock() }
    defer { clientEffects.removeAll(keepingCapacity: true) }
    return clientEffects
  }

  private func receive(_ frame: TransportFrame, atMs: Int64) {
    stateLock.lock()
    defer { stateLock.unlock() }
    if frame.relayed && frame.senderSlot == slot { return }
    do {
      switch frame {
      case let .pose(pose, _):
        guard slot == 0 else { return }
        guard var authority = host else { return }
        let effects = authority.ingest(
          .pose(codec.poseInput(from: pose)),
          from: pose.senderSlot,
          atMs: atMs
        )
        host = authority
        processHostEffects(effects, atMs: atMs)
      case let .reliable(reliable, _):
        if slot == 0 {
          guard reliable.senderSlot != 0 else { return }
          guard reliable.eventKind == .fire || reliable.eventKind == .control else { return }
          guard var authority = host else { return }
          let effects = authority.ingest(
            try codec.message(from: reliable),
            from: reliable.senderSlot,
            atMs: atMs
          )
          host = authority
          processHostEffects(effects, atMs: atMs)
        } else {
          guard reliable.senderSlot == 0,
                reliable.eventKind == .verdict || reliable.eventKind == .snapshot
          else { return }
          guard reliable.sequence >= nextHostFrameSequence else { return }
          pendingHostFrames[reliable.sequence] = reliable
          while let next = pendingHostFrames.removeValue(forKey: nextHostFrameSequence) {
            nextHostFrameSequence &+= 1
            let effects = client.receive(try codec.message(from: next), atMs: atMs)
            try processClientEffects(effects)
          }
        }
      case .slotClaim, .pairingOffer, .pairingClaim:
        break
      }
    } catch {
      return
    }
  }

  private func processHostEffects(
    _ effects: [AuthorityHostEffect],
    atMs: Int64
  ) {
    for effect in effects {
      switch effect {
      case let .broadcast(message):
        do {
          let frame = try nextReliableFrame(for: message)
          try link.send(.reliable(frame))
          let localEffects = client.receive(message, atMs: atMs)
          for localEffect in localEffects {
            appendClientEffect(localEffect)
          }
        } catch {
          continue
        }
      case let .memberFireLocked(memberSlot):
        if memberSlot == slot {
          appendClientEffect(.fireRefusedLocally(.memberFireLocked))
        }
      case .memberFireUnlocked, .rejectedInput:
        break
      }
    }
  }

  private func processClientEffects(_ effects: [AuthorityClientEffect]) throws {
    for effect in effects {
      appendClientEffect(effect)
      if case let .send(message) = effect {
        if slot == 0 {
          continue
        }
        switch message {
        case let .pose(input):
          try link.send(
            .pose(
              codec.poseFrame(
                from: input,
                epoch: epoch,
                orientation: SIMD4<Float>(0, 0, 0, 1)
              )
            )
          )
        case .fire, .reload:
          let frame = try nextReliableFrame(for: message)
          try link.send(.reliable(frame))
        case .verdict, .snapshot:
          break
        }
      }
    }
  }

  private func nextReliableFrame(
    for message: AuthorityMessage
  ) throws -> ReliableEventFrame {
    reliableFrameSequence &+= 1
    return try codec.reliableFrame(
      message,
      epoch: epoch,
      senderSlot: slot,
      sequence: reliableFrameSequence
    )
  }

  private func appendClientEffect(_ effect: AuthorityClientEffect) {
    clientEffects.append(effect)
    if case let .predictionResolved(_, _, latencyMs) = effect {
      latency.record(latencyMs: latencyMs)
    }
  }
}
