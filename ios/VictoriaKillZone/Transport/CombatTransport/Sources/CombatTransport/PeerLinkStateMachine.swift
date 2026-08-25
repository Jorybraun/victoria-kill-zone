import CryptoKit
import Foundation

public struct PeerLinkStateMachine: Equatable, Sendable {
  public enum Role: Equatable, Sendable {
    case host
    case client
  }

  public struct ConnectionID: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
      self.rawValue = rawValue
    }
  }

  public enum Channel: Equatable, Sendable {
    case pose
    case reliable
  }

  public enum Action: Equatable, Sendable {
    case bound(connection: ConnectionID, slot: UInt8)
    case write(connection: ConnectionID, channel: Channel, frame: TransportFrame)
    case received(connection: ConnectionID, frame: TransportFrame)
    case rejected(connection: ConnectionID, error: PeerLinkStateMachineError)
    case disconnected(slot: UInt8)
  }

  public struct SendIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case skipped(PeerLinkStateMachineError)
      case queuedReliable
      case failed(PeerLinkStateMachineError)
    }

    public let slot: UInt8
    public let kind: Kind

    public init(slot: UInt8, kind: Kind) {
      self.slot = slot
      self.kind = kind
    }

    var failure: PeerLinkStateMachineError? {
      guard case let .failed(error) = kind else { return nil }
      return error
    }
  }

  public struct SendOutcome: Equatable, Sendable {
    public let actions: [Action]
    public let issues: [SendIssue]

    public init(actions: [Action] = [], issues: [SendIssue] = []) {
      self.actions = actions
      self.issues = issues
    }
  }

  public enum PeerLinkStateMachineError: Error, Equatable, Sendable {
    case invalidSlotClaim
    case authenticationFailed
    case duplicateSlot
    case unboundConnection
    case senderSlotMismatch
    case linkNotReady(channel: Channel, slot: UInt8)
    case reliableQueueFull(slot: UInt8)
    case disconnected(slot: UInt8)
    case relayedFrameNotAllowed
  }

  private struct FlowBinding: Equatable, Sendable {
    let connection: ConnectionID
    var reliableReady = false
    var datagramReady = false
  }

  public let role: Role
  public let localSlot: UInt8
  public let remoteSlot: UInt8?
  public private(set) var topology: HostRelayTopology
  public private(set) var lastEffects: [TransportEffect] = []
  public var fireLocked: Bool { topology.fireLocked }

  public func boundSlot(for connection: ConnectionID) -> UInt8? {
    slotsByConnection[connection]
  }

  private let preSharedKey: Data
  private var pendingConnections: Set<ConnectionID> = []
  private var bindingsBySlot: [UInt8: FlowBinding] = [:]
  private var slotsByConnection: [ConnectionID: UInt8] = [:]
  private var reliableQueues: [UInt8: ReliableSendQueue] = [:]
  private var disconnectedSlots: Set<UInt8> = []

  public init(
    role: Role,
    localSlot: UInt8,
    remoteSlot: UInt8? = nil,
    playerCount: Int = 2,
    preSharedKey: Data
  ) throws {
    guard localSlot <= 3 else { throw PeerLinkStateMachineError.invalidSlotClaim }
    if let remoteSlot, remoteSlot > 3 {
      throw PeerLinkStateMachineError.invalidSlotClaim
    }
    if role == .client, remoteSlot == nil {
      throw PeerLinkStateMachineError.invalidSlotClaim
    }
    self.role = role
    self.localSlot = localSlot
    self.remoteSlot = remoteSlot
    self.preSharedKey = preSharedKey
    topology = try HostRelayTopology(playerCount: playerCount)
  }

  public static func slotClaimDigest(
    preSharedKey: Data,
    nonce: UInt32,
    claimedSlot: UInt8
  ) -> Data {
    var input = Data(preSharedKey)
    var nonceLE = nonce.littleEndian
    withUnsafeBytes(of: &nonceLE) { input.append(contentsOf: $0) }
    input.append(claimedSlot)
    return Data(SHA256.hash(data: input))
  }

  public static func makeSlotClaim(
    preSharedKey: Data,
    nonce: UInt32,
    claimedSlot: UInt8
  ) -> SlotClaimFrame {
    SlotClaimFrame(
      claimedSlot: claimedSlot,
      nonce: nonce,
      digest: slotClaimDigest(
        preSharedKey: preSharedKey,
        nonce: nonce,
        claimedSlot: claimedSlot
      )
    )
  }

  public mutating func acceptConnection(_ connection: ConnectionID) throws {
    guard role == .host else { throw PeerLinkStateMachineError.unboundConnection }
    pendingConnections.insert(connection)
  }

  public mutating func bindClientConnection(
    _ connection: ConnectionID,
    to slot: UInt8? = nil
  ) throws {
    guard role == .client else { throw PeerLinkStateMachineError.unboundConnection }
    let target = slot ?? remoteSlot
    guard let target, target == remoteSlot else {
      throw PeerLinkStateMachineError.invalidSlotClaim
    }
    pendingConnections.remove(connection)
    bindingsBySlot[target] = FlowBinding(connection: connection)
    slotsByConnection[connection] = target
    disconnectedSlots.remove(target)
  }

  @discardableResult
  public mutating func receive(
    _ frame: TransportFrame,
    on connection: ConnectionID
  ) throws -> [Action] {
    if case let .slotClaim(claim, _) = frame {
      guard role == .host, pendingConnections.contains(connection) else {
        throw PeerLinkStateMachineError.unboundConnection
      }
      guard (1...3).contains(claim.claimedSlot) else {
        return reject(connection, .invalidSlotClaim)
      }
      guard claim.digest == Self.slotClaimDigest(
        preSharedKey: preSharedKey,
        nonce: claim.nonce,
        claimedSlot: claim.claimedSlot
      ) else {
        return reject(connection, .authenticationFailed)
      }
      guard bindingsBySlot[claim.claimedSlot] == nil else {
        return reject(connection, .duplicateSlot)
      }
      pendingConnections.remove(connection)
      bindingsBySlot[claim.claimedSlot] = FlowBinding(connection: connection)
      slotsByConnection[connection] = claim.claimedSlot
      disconnectedSlots.remove(claim.claimedSlot)
      return [.bound(connection: connection, slot: claim.claimedSlot)]
    }

    guard let boundSlot = slotsByConnection[connection] else {
      throw PeerLinkStateMachineError.unboundConnection
    }
    guard frame.senderSlot == boundSlot else {
      return reject(connection, .senderSlotMismatch)
    }
    return [.received(connection: connection, frame: frame)]
  }

  @discardableResult
  public mutating func setFlowReady(
    _ channel: Channel,
    for slot: UInt8,
    connection: ConnectionID
  ) throws -> [Action] {
    guard slotsByConnection[connection] == slot,
          bindingsBySlot[slot]?.connection == connection
    else { throw PeerLinkStateMachineError.unboundConnection }
    guard var binding = bindingsBySlot[slot] else {
      throw PeerLinkStateMachineError.unboundConnection
    }
    switch channel {
    case .pose:
      binding.datagramReady = true
    case .reliable:
      binding.reliableReady = true
    }
    bindingsBySlot[slot] = binding
    guard channel == .reliable else { return [] }
    var actions: [Action] = []
    while var queue = reliableQueues[slot], let frame = queue.dequeue() {
      reliableQueues[slot] = queue
      actions.append(
        .write(connection: connection, channel: .reliable, frame: .reliable(frame))
      )
    }
    return actions
  }

  public mutating func send(_ frame: TransportFrame) throws -> [Action] {
    let outcome = try sendOutcome(frame)
    if let failure = outcome.issues.compactMap(\.failure).first {
      throw failure
    }
    return outcome.actions
  }

  public mutating func sendOutcome(_ frame: TransportFrame) throws -> SendOutcome {
    guard frame.senderSlot == localSlot else {
      throw PeerLinkStateMachineError.senderSlotMismatch
    }
    guard !frame.relayed else {
      throw PeerLinkStateMachineError.relayedFrameNotAllowed
    }
    let targets: [UInt8]
    switch role {
    case .host:
      targets = topology.expectedPeerSlots
    case .client:
      guard let remoteSlot else { throw PeerLinkStateMachineError.linkNotReady(channel: channel(for: frame), slot: 0) }
      targets = [remoteSlot]
    }

    var actions: [Action] = []
    var issues: [SendIssue] = []
    for target in targets {
      if disconnectedSlots.contains(target) {
        switch frame {
        case .pose:
          issues.append(.init(slot: target, kind: .skipped(.disconnected(slot: target))))
          continue
        case .reliable:
          break
        case .slotClaim:
          throw PeerLinkStateMachineError.unboundConnection
        }
      }
      guard let binding = bindingsBySlot[target] else {
        if channel(for: frame) == .reliable {
          if try enqueueReliable(frame, for: target) {
            issues.append(.init(slot: target, kind: .queuedReliable))
          } else {
            issues.append(.init(
              slot: target,
              kind: .failed(.reliableQueueFull(slot: target))
            ))
          }
          continue
        }
        issues.append(.init(
          slot: target,
          kind: .skipped(.linkNotReady(channel: .pose, slot: target))
        ))
        continue
      }
      switch frame {
      case .pose:
        guard binding.datagramReady else {
          issues.append(.init(
            slot: target,
            kind: .skipped(.linkNotReady(channel: .pose, slot: target))
          ))
          continue
        }
        actions.append(.write(connection: binding.connection, channel: .pose, frame: frame))
      case .reliable:
        if binding.reliableReady {
          actions.append(contentsOf: flushAndWrite(frame, for: target, binding: binding))
        } else {
          if try enqueueReliable(frame, for: target) {
            issues.append(.init(slot: target, kind: .queuedReliable))
          } else {
            issues.append(.init(
              slot: target,
              kind: .failed(.reliableQueueFull(slot: target))
            ))
          }
        }
      case .slotClaim:
        throw PeerLinkStateMachineError.unboundConnection
      }
    }
    if actions.isEmpty, case .pose = frame,
       let issue = issues.first,
       case let .skipped(error) = issue.kind {
      throw error
    }
    return SendOutcome(actions: actions, issues: issues)
  }

  public func sendSlotClaim(
    _ claim: SlotClaimFrame,
    on connection: ConnectionID
  ) throws -> Action {
    guard role == .client,
          pendingConnections.contains(connection) || slotsByConnection[connection] != nil
    else { throw PeerLinkStateMachineError.unboundConnection }
    return .write(
      connection: connection,
      channel: .reliable,
      frame: .slotClaim(claim)
    )
  }

  @discardableResult
  public mutating func disconnect(_ connection: ConnectionID) -> [Action] {
    guard let slot = slotsByConnection.removeValue(forKey: connection) else {
      pendingConnections.remove(connection)
      return []
    }
    bindingsBySlot[slot] = nil
    disconnectedSlots.insert(slot)
    var effects: [TransportEffect] = []
    if role == .host, slot != HostRelayTopology.hostSlot {
      effects = (try? topology.disconnect(slot: slot)) ?? []
    } else {
      effects = topology.markHostLinkDown()
    }
    lastEffects = effects
    return [.disconnected(slot: slot)]
  }

  public static func selectServiceName(
    from serviceNames: [String],
    matching token: String
  ) -> String? {
    serviceNames.first { $0 == token }
  }

  private func channel(for frame: TransportFrame) -> Channel {
    switch frame {
    case .pose: .pose
    case .reliable, .slotClaim: .reliable
    }
  }

  private mutating func enqueueReliable(
    _ frame: TransportFrame,
    for slot: UInt8
  ) throws -> Bool {
    guard case let .reliable(value, _) = frame else {
      throw PeerLinkStateMachineError.linkNotReady(channel: .pose, slot: slot)
    }
    var queue = reliableQueues[slot] ?? ReliableSendQueue()
    guard queue.enqueue(value) == .enqueued else {
      lastEffects = topology.rejectReliableQueueFull()
      return false
    }
    reliableQueues[slot] = queue
    return true
  }

  private mutating func flushAndWrite(
    _ frame: TransportFrame,
    for slot: UInt8,
    binding: FlowBinding
  ) -> [Action] {
    var actions: [Action] = []
    while var queue = reliableQueues[slot], let queued = queue.dequeue() {
      reliableQueues[slot] = queue
      actions.append(.write(connection: binding.connection, channel: .reliable, frame: .reliable(queued)))
    }
    actions.append(.write(connection: binding.connection, channel: .reliable, frame: frame))
    return actions
  }

  private mutating func reject(
    _ connection: ConnectionID,
    _ error: PeerLinkStateMachineError
  ) -> [Action] {
    pendingConnections.remove(connection)
    if let slot = slotsByConnection.removeValue(forKey: connection) {
      bindingsBySlot[slot] = nil
    }
    return [.rejected(connection: connection, error: error)]
  }
}
