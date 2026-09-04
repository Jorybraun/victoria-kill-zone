import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

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
    case datagramBound(connection: ConnectionID, slot: UInt8)
    case write(connection: ConnectionID, channel: Channel, frame: TransportFrame)
    case received(connection: ConnectionID, frame: TransportFrame)
    case rejected(connection: ConnectionID, error: PeerLinkStateMachineError)
    case dropped(slot: UInt8, status: ReliableDeliveryStatus)
    case reliableGap(slot: UInt8)
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
    case pairingTokenMismatch
    case pairingSlotUnbound
    case flowAlreadyBound
  }

  private struct FlowBinding: Equatable, Sendable {
    let connection: ConnectionID
    var datagramConnection: ConnectionID?
    var pairingToken: Data?
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

  public func datagramConnection(for slot: UInt8) -> ConnectionID? {
    bindingsBySlot[slot]?.datagramConnection
  }

  private let preSharedKey: Data
  private var pendingConnections: Set<ConnectionID> = []
  private var bindingsBySlot: [UInt8: FlowBinding] = [:]
  private var slotsByConnection: [ConnectionID: UInt8] = [:]
  private var reliableQueues: [UInt8: ReliableSendQueue] = [:]
  private var reliableOrderers: [UInt8: ReliableEventOrderer] = [:]
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
    return SHA256Digest.hash(input)
  }

  public static func pairingDigest(
    preSharedKey: Data,
    token: Data,
    claimedSlot: UInt8
  ) -> Data {
    var input = Data(preSharedKey)
    input.append(token)
    input.append(claimedSlot)
    return SHA256Digest.hash(input)
  }

  public static func makePairingClaim(
    preSharedKey: Data,
    token: Data,
    claimedSlot: UInt8
  ) -> PairingClaimFrame {
    PairingClaimFrame(
      claimedSlot: claimedSlot,
      digest: pairingDigest(
        preSharedKey: preSharedKey,
        token: token,
        claimedSlot: claimedSlot
      )
    )
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

  /// Host: authorise exactly one datagram flow for an already-bound slot.
  /// The caller supplies the random token and the accepted datagram port; the
  /// token is retained so only a matching `pairingClaim` can bind that flow.
  public mutating func issuePairingOffer(
    for slot: UInt8,
    datagramPort: UInt16,
    token: Data
  ) throws -> Action {
    guard role == .host, var binding = bindingsBySlot[slot] else {
      throw PeerLinkStateMachineError.pairingSlotUnbound
    }
    guard token.count == TransportFrameCodec.pairingTokenLength else {
      throw PeerLinkStateMachineError.pairingTokenMismatch
    }
    binding.pairingToken = token
    binding.datagramConnection = nil
    binding.datagramReady = false
    bindingsBySlot[slot] = binding
    return .write(
      connection: binding.connection,
      channel: .reliable,
      frame: .pairingOffer(
        PairingOfferFrame(slot: slot, token: token, datagramPort: datagramPort)
      )
    )
  }

  /// Client: bind the datagram flow it dialled after an authenticated offer.
  public mutating func bindClientDatagramConnection(
    _ connection: ConnectionID,
    to slot: UInt8
  ) throws {
    guard role == .client, var binding = bindingsBySlot[slot] else {
      throw PeerLinkStateMachineError.pairingSlotUnbound
    }
    guard binding.datagramConnection == nil ||
      binding.datagramConnection == connection
    else {
      throw PeerLinkStateMachineError.flowAlreadyBound
    }
    binding.datagramConnection = connection
    bindingsBySlot[slot] = binding
    slotsByConnection[connection] = slot
    pendingConnections.remove(connection)
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

    if case let .pairingClaim(claim, _) = frame {
      guard role == .host, pendingConnections.contains(connection) else {
        throw PeerLinkStateMachineError.unboundConnection
      }
      guard (1...3).contains(claim.claimedSlot),
            var binding = bindingsBySlot[claim.claimedSlot],
            let token = binding.pairingToken
      else {
        return reject(connection, .pairingSlotUnbound)
      }
      guard binding.datagramConnection == nil else {
        return reject(connection, .flowAlreadyBound)
      }
      guard claim.digest == Self.pairingDigest(
        preSharedKey: preSharedKey,
        token: token,
        claimedSlot: claim.claimedSlot
      ) else {
        return reject(connection, .pairingTokenMismatch)
      }
      pendingConnections.remove(connection)
      binding.datagramConnection = connection
      bindingsBySlot[claim.claimedSlot] = binding
      slotsByConnection[connection] = claim.claimedSlot
      return [.datagramBound(connection: connection, slot: claim.claimedSlot)]
    }

    guard let boundSlot = slotsByConnection[connection] else {
      throw PeerLinkStateMachineError.unboundConnection
    }
    if frame.relayed {
      // A relayed frame is only admissible from the host link, and its
      // authenticated origin must be a different client slot. The relayed flag
      // alone never authorises admission.
      guard role == .client,
            boundSlot == HostRelayTopology.hostSlot,
            (1...3).contains(frame.senderSlot),
            frame.senderSlot != localSlot
      else {
        return reject(connection, .senderSlotMismatch, unbind: false)
      }
    } else if frame.senderSlot != boundSlot {
      return reject(connection, .senderSlotMismatch)
    }
    guard case let .reliable(reliableFrame, relayed) = frame else {
      return [.received(connection: connection, frame: frame)]
    }
    var orderer = reliableOrderers[reliableFrame.senderSlot] ?? ReliableEventOrderer()
    let delivery = orderer.ingest(reliableFrame)
    reliableOrderers[reliableFrame.senderSlot] = orderer
    switch delivery.status {
    case .delivered:
      return delivery.frames.map {
        .received(
          connection: connection,
          frame: .reliable($0, relayed: relayed)
        )
      }
    case .unrecoverableGap:
      lastEffects = topology.markReliableGapUnrecoverable(
        slot: reliableFrame.senderSlot
      )
      return [.reliableGap(slot: reliableFrame.senderSlot)]
    case .duplicate, .buffered, .epochMismatch:
      return [.dropped(slot: reliableFrame.senderSlot, status: delivery.status)]
    }
  }

  @discardableResult
  public mutating func setFlowReady(
    _ channel: Channel,
    for slot: UInt8,
    connection: ConnectionID
  ) throws -> [Action] {
    guard slotsByConnection[connection] == slot,
          var binding = bindingsBySlot[slot]
    else { throw PeerLinkStateMachineError.unboundConnection }
    switch channel {
    case .pose:
      guard binding.datagramConnection == connection else {
        throw PeerLinkStateMachineError.unboundConnection
      }
      binding.datagramReady = true
    case .reliable:
      guard binding.connection == connection else {
        throw PeerLinkStateMachineError.unboundConnection
      }
      binding.reliableReady = true
    }
    bindingsBySlot[slot] = binding
    guard channel == .reliable else { return [] }
    var actions: [Action] = []
    while var queue = reliableQueues[slot], let queued = queue.dequeue() {
      reliableQueues[slot] = queue
      actions.append(
        .write(
          connection: connection,
          channel: .reliable,
          frame: .reliable(queued.frame, relayed: queued.relayed)
        )
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
    return try fanout(frame, to: targets)
  }

  public mutating func relayOutcome(
    _ frame: TransportFrame,
    from connection: ConnectionID
  ) throws -> SendOutcome {
    guard role == .host,
          let originSlot = slotsByConnection[connection]
    else {
      throw PeerLinkStateMachineError.unboundConnection
    }
    guard frame.senderSlot == originSlot else {
      throw PeerLinkStateMachineError.senderSlotMismatch
    }
    guard !frame.relayed else {
      throw PeerLinkStateMachineError.relayedFrameNotAllowed
    }
    let targets = topology.expectedPeerSlots.filter { $0 != originSlot }
    return try fanout(frame.relayedCopy, to: targets, allowEmptyPose: true)
  }

  private mutating func fanout(
    _ frame: TransportFrame,
    to targets: [UInt8],
    allowEmptyPose: Bool = false
  ) throws -> SendOutcome {
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
        case .slotClaim, .pairingOffer, .pairingClaim:
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
        guard binding.datagramReady,
              let datagramConnection = binding.datagramConnection
        else {
          issues.append(.init(
            slot: target,
            kind: .skipped(.linkNotReady(channel: .pose, slot: target))
          ))
          continue
        }
        actions.append(.write(
          connection: datagramConnection,
          channel: .pose,
          frame: frame
        ))
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
      case .slotClaim, .pairingOffer, .pairingClaim:
        throw PeerLinkStateMachineError.unboundConnection
      }
    }
    if !allowEmptyPose, actions.isEmpty, case .pose = frame,
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
    if let binding = bindingsBySlot[slot] {
      slotsByConnection.removeValue(forKey: binding.connection)
      if let datagram = binding.datagramConnection {
        slotsByConnection.removeValue(forKey: datagram)
      }
    }
    bindingsBySlot[slot] = nil
    reliableOrderers[slot] = nil
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
    case .reliable, .slotClaim, .pairingOffer, .pairingClaim: .reliable
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
    guard queue.enqueue(QueuedReliable(frame: value, relayed: frame.relayed)) == .enqueued else {
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
      actions.append(.write(
        connection: binding.connection,
        channel: .reliable,
        frame: .reliable(queued.frame, relayed: queued.relayed)
      ))
    }
    actions.append(.write(
      connection: binding.connection,
      channel: .reliable,
      frame: frame
    ))
    return actions
  }

  private mutating func reject(
    _ connection: ConnectionID,
    _ error: PeerLinkStateMachineError,
    unbind: Bool = true
  ) -> [Action] {
    guard unbind else {
      return [.rejected(connection: connection, error: error)]
    }
    pendingConnections.remove(connection)
    if let slot = slotsByConnection.removeValue(forKey: connection) {
      bindingsBySlot[slot] = nil
    }
    return [.rejected(connection: connection, error: error)]
  }

}

private extension TransportFrame {
  var relayedCopy: TransportFrame {
    switch self {
    case let .pose(frame, _):
      .pose(frame, relayed: true)
    case let .reliable(frame, _):
      .reliable(frame, relayed: true)
    case let .slotClaim(frame, _):
      .slotClaim(frame, relayed: true)
    case let .pairingOffer(frame, _):
      .pairingOffer(frame, relayed: true)
    case let .pairingClaim(frame, _):
      .pairingClaim(frame, relayed: true)
    }
  }
}
