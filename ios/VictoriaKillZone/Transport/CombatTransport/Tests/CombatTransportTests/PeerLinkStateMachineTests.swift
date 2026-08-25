import Foundation
import XCTest

@testable import CombatTransport

final class PeerLinkStateMachineTests: XCTestCase {
  private let key = Data("match-scoped-test-key".utf8)

  private func pose(slot: UInt8 = 0, sequence: UInt32 = 1) -> PoseFrame {
    PoseFrame(
      epoch: 1,
      senderSlot: slot,
      sequence: sequence,
      timestampMs: Int64(sequence),
      position: SIMD3<Float>(0, 0, 0),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
  }

  private func event(slot: UInt8 = 0, sequence: UInt32 = 1) -> ReliableEventFrame {
    ReliableEventFrame(
      epoch: 1,
      senderSlot: slot,
      sequence: sequence,
      eventKind: .fire,
      payload: Data([UInt8(sequence)])
    )
  }

  private func host(playerCount: Int = 4) throws -> PeerLinkStateMachine {
    try PeerLinkStateMachine(
      role: .host,
      localSlot: 0,
      playerCount: playerCount,
      preSharedKey: key
    )
  }

  private func claim(slot: UInt8) -> SlotClaimFrame {
    PeerLinkStateMachine.makeSlotClaim(
      preSharedKey: key,
      nonce: UInt32(slot) * 17,
      claimedSlot: slot
    )
  }

  private func bind(
    _ machine: inout PeerLinkStateMachine,
    connection: UInt64,
    slot: UInt8
  ) throws {
    let id = PeerLinkStateMachine.ConnectionID(connection)
    try machine.acceptConnection(id)
    XCTAssertEqual(
      try machine.receive(.slotClaim(claim(slot: slot)), on: id),
      [.bound(connection: id, slot: slot)]
    )
  }

  func testThreeAndFourPeersHaveIndependentAuthenticatedFlows() throws {
    for playerCount in [3, 4] {
      var machine = try host(playerCount: playerCount)
      for slot in 1..<UInt8(playerCount) {
        try bind(&machine, connection: UInt64(slot), slot: slot)
        let id = PeerLinkStateMachine.ConnectionID(UInt64(slot))
        _ = try machine.setFlowReady(.pose, for: slot, connection: id)
        _ = try machine.setFlowReady(.reliable, for: slot, connection: id)
      }

      let poseWrites = try machine.send(.pose(pose()))
        .compactMap { action -> PeerLinkStateMachine.ConnectionID? in
          guard case let .write(connection, .pose, _) = action else { return nil }
          return connection
        }
      XCTAssertEqual(poseWrites, (1..<UInt64(playerCount)).map(PeerLinkStateMachine.ConnectionID.init))
      let reliableWrites = try machine.send(.reliable(event()))
        .compactMap { action -> PeerLinkStateMachine.ConnectionID? in
          guard case let .write(connection, .reliable, _) = action else { return nil }
          return connection
        }
      XCTAssertEqual(reliableWrites, poseWrites)
    }
  }

  func testDuplicateAndBadClaimsAreRejectedWithoutOverwritingBindings() throws {
    var machine = try host()
    try bind(&machine, connection: 1, slot: 1)

    try machine.acceptConnection(.init(2))
    XCTAssertEqual(
      try machine.receive(.slotClaim(claim(slot: 1)), on: .init(2)),
      [.rejected(connection: .init(2), error: .duplicateSlot)]
    )

    try machine.acceptConnection(.init(3))
    let bad = SlotClaimFrame(claimedSlot: 2, nonce: 4, digest: Data(repeating: 0, count: 32))
    XCTAssertEqual(
      try machine.receive(.slotClaim(bad), on: .init(3)),
      [.rejected(connection: .init(3), error: .authenticationFailed)]
    )

    try machine.acceptConnection(.init(4))
    let invalid = SlotClaimFrame(claimedSlot: 4, nonce: 4, digest: Data(repeating: 0, count: 32))
    XCTAssertEqual(
      try machine.receive(.slotClaim(invalid), on: .init(4)),
      [.rejected(connection: .init(4), error: .invalidSlotClaim)]
    )
  }

  func testBoundConnectionRejectsSenderSlotMismatch() throws {
    var machine = try host(playerCount: 2)
    try bind(&machine, connection: 1, slot: 1)
    XCTAssertEqual(
      try machine.receive(.pose(pose(slot: 2)), on: .init(1)),
      [.rejected(connection: .init(1), error: .senderSlotMismatch)]
    )
  }

  func testPoseRequiresReadyDatagramAndReliableQueuesThenFlushesInOrder() throws {
    var machine = try host(playerCount: 2)
    try bind(&machine, connection: 1, slot: 1)

    XCTAssertThrowsError(try machine.send(.pose(pose()))) { error in
      XCTAssertEqual(
        error as? PeerLinkStateMachine.PeerLinkStateMachineError,
        .linkNotReady(channel: .pose, slot: 1)
      )
    }
    XCTAssertTrue(try machine.send(.reliable(event(sequence: 1))).isEmpty)
    XCTAssertTrue(try machine.send(.reliable(event(sequence: 2))).isEmpty)

    let flushed = try machine.setFlowReady(
      .reliable,
      for: 1,
      connection: .init(1)
    )
    XCTAssertEqual(
      flushed.compactMap { action -> UInt32? in
        guard case let .write(_, .reliable, .reliable(frame, _)) = action else { return nil }
        return frame.sequence
      },
      [1, 2]
    )
  }

  func testReliableQueueFullEngagesFireLockAndDisconnectFails() throws {
    var machine = try host(playerCount: 2)
    try bind(&machine, connection: 1, slot: 1)
    for sequence in 1...128 {
      XCTAssertTrue(try machine.send(.reliable(event(sequence: UInt32(sequence)))).isEmpty)
    }
    XCTAssertThrowsError(try machine.send(.reliable(event(sequence: 129)))) { error in
      XCTAssertEqual(
        error as? PeerLinkStateMachine.PeerLinkStateMachineError,
        .reliableQueueFull(slot: 1)
      )
    }
    XCTAssertTrue(machine.fireLocked)
    _ = machine.disconnect(.init(1))
    XCTAssertThrowsError(try machine.send(.pose(pose()))) { error in
      XCTAssertEqual(
        error as? PeerLinkStateMachine.PeerLinkStateMachineError,
        .disconnected(slot: 1)
      )
    }
  }

  func testHostFanoutSkipsDegradedPeersWithoutAbortingHealthyWrites() throws {
    var machine = try host()
    try bind(&machine, connection: 1, slot: 1)
    try bind(&machine, connection: 2, slot: 2)
    _ = try machine.setFlowReady(.pose, for: 1, connection: .init(1))
    _ = try machine.setFlowReady(.pose, for: 2, connection: .init(2))
    _ = try machine.setFlowReady(.reliable, for: 1, connection: .init(1))
    _ = try machine.setFlowReady(.reliable, for: 2, connection: .init(2))

    let initialPose = try machine.sendOutcome(.pose(pose()))
    XCTAssertEqual(
      initialPose.actions.compactMap { action -> UInt64? in
        guard case let .write(connection, .pose, _) = action else { return nil }
        return connection.rawValue
      },
      [1, 2]
    )
    XCTAssertEqual(initialPose.issues.map(\.slot), [3])

    _ = machine.disconnect(.init(2))
    let degradedPose = try machine.sendOutcome(.pose(pose(sequence: 2)))
    XCTAssertEqual(
      degradedPose.actions.compactMap { action -> UInt64? in
        guard case let .write(connection, .pose, _) = action else { return nil }
        return connection.rawValue
      },
      [1]
    )
    XCTAssertEqual(degradedPose.issues.map(\.slot), [2, 3])
    XCTAssertTrue(degradedPose.issues.allSatisfy {
      if case .skipped = $0.kind { return true }
      return false
    })

    let fire = try machine.sendOutcome(.reliable(event(sequence: 1)))
    XCTAssertEqual(
      fire.actions.compactMap { action -> UInt64? in
        guard case let .write(connection, .reliable, _) = action else { return nil }
        return connection.rawValue
      },
      [1]
    )
    XCTAssertEqual(fire.issues.map(\.slot), [2, 3])
    XCTAssertTrue(fire.issues.allSatisfy {
      if case .queuedReliable = $0.kind { return true }
      return false
    })

    try bind(&machine, connection: 4, slot: 2)
    let flushed = try machine.setFlowReady(.reliable, for: 2, connection: .init(4))
    XCTAssertEqual(
      flushed.compactMap { action -> UInt32? in
        guard case let .write(_, .reliable, .reliable(frame, _)) = action else { return nil }
        return frame.sequence
      },
      [1]
    )

    var queueMachine = try host()
    try bind(&queueMachine, connection: 1, slot: 1)
    try bind(&queueMachine, connection: 2, slot: 2)
    _ = try queueMachine.setFlowReady(.reliable, for: 1, connection: .init(1))
    for sequence in 1...128 {
      _ = try queueMachine.sendOutcome(
        .reliable(event(sequence: UInt32(sequence)))
      )
    }
    let queueFull = try queueMachine.sendOutcome(.reliable(event(sequence: 129)))
    XCTAssertEqual(
      queueFull.actions.compactMap { action -> UInt64? in
        guard case let .write(connection, .reliable, _) = action else { return nil }
        return connection.rawValue
      },
      [1]
    )
    XCTAssertEqual(
      queueFull.issues.first(where: { $0.slot == 2 })?.kind,
      .failed(.reliableQueueFull(slot: 2))
    )
  }

  func testHostWithNoWritablePoseTargetThrowsTypedNotReady() throws {
    var machine = try host(playerCount: 2)
    XCTAssertThrowsError(try machine.sendOutcome(.pose(pose()))) { error in
      XCTAssertEqual(
        error as? PeerLinkStateMachine.PeerLinkStateMachineError,
        .linkNotReady(channel: .pose, slot: 1)
      )
    }
  }

  func testRelayUsesAuthenticatedOriginAndPreservesOrderedFanout() throws {
    var machine = try host()
    try bind(&machine, connection: 1, slot: 1)
    try bind(&machine, connection: 2, slot: 2)
    _ = try machine.setFlowReady(.pose, for: 2, connection: .init(2))
    _ = try machine.setFlowReady(.reliable, for: 2, connection: .init(2))
    XCTAssertFalse(machine.topology.expectedPeerSlots.contains(HostRelayTopology.hostSlot))

    let received = try machine.receive(.pose(pose(slot: 1)), on: .init(1))
    XCTAssertEqual(received, [.received(connection: .init(1), frame: .pose(pose(slot: 1)))])

    let reliableFrame = TransportFrame.reliable(event(slot: 1, sequence: 1))
    XCTAssertEqual(
      try machine.receive(reliableFrame, on: .init(1)),
      [.received(connection: .init(1), frame: reliableFrame)]
    )
    XCTAssertEqual(try machine.receive(reliableFrame, on: .init(1)), [])

    let relayedPose = try machine.relayOutcome(.pose(pose(slot: 1)), from: .init(1))
    XCTAssertEqual(
      relayedPose.actions,
      [.write(
        connection: .init(2),
        channel: .pose,
        frame: .pose(pose(slot: 1), relayed: true)
      )]
    )
    XCTAssertEqual(relayedPose.issues.map(\.slot), [3])
    XCTAssertThrowsError(
      try machine.relayOutcome(.pose(pose(slot: 2)), from: .init(1))
    ) { error in
      XCTAssertEqual(
        error as? PeerLinkStateMachine.PeerLinkStateMachineError,
        .senderSlotMismatch
      )
    }

    let first = try machine.relayOutcome(
      .reliable(event(slot: 1, sequence: 1)),
      from: .init(1)
    )
    XCTAssertEqual(
      first.actions,
      [.write(
        connection: .init(2),
        channel: .reliable,
        frame: .reliable(event(slot: 1, sequence: 1), relayed: true)
      )]
    )
    _ = machine.disconnect(.init(2))
    let second = try machine.relayOutcome(
      .reliable(event(slot: 1, sequence: 2)),
      from: .init(1)
    )
    XCTAssertEqual(
      second.issues.compactMap { issue -> UInt8? in
        guard case .queuedReliable = issue.kind else { return nil }
        return issue.slot
      },
      [2, 3]
    )

    try bind(&machine, connection: 4, slot: 2)
    let flushed = try machine.setFlowReady(.reliable, for: 2, connection: .init(4))
    XCTAssertEqual(
      flushed.compactMap { action -> UInt32? in
        guard case let .write(_, .reliable, .reliable(frame, _)) = action else {
          return nil
        }
        return frame.sequence
      },
      [2]
    )
    guard case let .write(_, .reliable, .reliable(_, relayed)) = flushed[0] else {
      return XCTFail("expected a flushed reliable relay")
    }
    XCTAssertEqual(relayed, true)
  }

  func testClientUsesOnlyHostRouteAndBonjourSelectionRequiresExactToken() throws {
    var machine = try PeerLinkStateMachine(
      role: .client,
      localSlot: 1,
      remoteSlot: 0,
      playerCount: 2,
      preSharedKey: key
    )
    try machine.bindClientConnection(.init(42))
    _ = try machine.setFlowReady(.pose, for: 0, connection: .init(42))
    XCTAssertEqual(
      try machine.send(.pose(pose(slot: 1))),
      [.write(connection: .init(42), channel: .pose, frame: .pose(pose(slot: 1)))]
    )
    XCTAssertNil(PeerLinkStateMachine.selectServiceName(from: ["wrong"], matching: "token"))
    XCTAssertEqual(
      PeerLinkStateMachine.selectServiceName(
        from: ["wrong", "token", "other"],
        matching: "token"
      ),
      "token"
    )
  }
}
