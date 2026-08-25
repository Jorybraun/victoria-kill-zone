#if os(macOS)
import Foundation
import Network
import XCTest
@testable import CombatTransport

final class NetworkPeerLinkLoopbackSmokeTests: XCTestCase {
  private let key = Data("loopback-smoke-match-key".utf8)

  func testTier1LoopbackHostRelayAndHealthyPeerContinuity() throws {
    let identity = try SelfSignedIdentityFixture()
    let hostReceived = FrameRecorder()
    let clientOneReceived = FrameRecorder()
    let clientTwoReceived = FrameRecorder()
    let listenersReady = expectation(description: "host listeners ready")
    let ports = PortRecorder()
    let hostSlots = expectation(description: "host receives both authenticated slots")
    let clientOneHostPose = expectation(description: "client one pose reaches host")
    let clientOneHostReliable = expectation(description: "client one reliable reaches host")
    let clientTwoHostPose = expectation(description: "client two pose reaches host")
    let clientTwoHostReliable = expectation(description: "client two reliable reaches host")
    let hostPoseReachesBothClients = expectation(description: "host pose reaches both clients")
    let poseRelay = expectation(description: "pose relays from client one to client two")
    let reliableRelay = expectation(description: "reliable fire relays from client one to client two")
    let continuityPose = expectation(description: "client one continuity pose")
    let continuityReliable = expectation(description: "client one continuity reliable")
    [
      hostSlots, clientOneHostPose, clientOneHostReliable, clientTwoHostPose,
      clientTwoHostReliable, hostPoseReachesBothClients, poseRelay,
      reliableRelay, continuityPose, continuityReliable
    ].forEach { $0.assertForOverFulfill = false }
    let clientLinks = ClientLinks()

    let hostCredentials = TransportCredentials(
      preSharedKey: key,
      identity: identity
    )
    let hostConfiguration = NetworkPeerLinkConfiguration(
      serviceToken: "loopback-smoke",
      credentials: hostCredentials,
      role: .host,
      localSlot: 0,
      playerCount: 3,
      advertisesService: false
    )
    let host = try NetworkPeerLink(
      remoteSlot: 0,
      configuration: hostConfiguration,
      receiveHandler: { frame, _, _ in
        hostReceived.append(frame)
        if case let .pose(value, _) = frame, value.senderSlot == 1 {
          clientOneHostPose.fulfill()
          if value.sequence == 3 { continuityPose.fulfill() }
        }
        if case let .reliable(value, _) = frame, value.senderSlot == 1 {
          clientOneHostReliable.fulfill()
          if value.sequence == 3 { continuityReliable.fulfill() }
          if value.sequence == 1 {
            if let link = clientLinks.one {
              Self.scheduleSend(link, frame: .pose(Self.pose(slot: 1, sequence: 1)))
            }
          }
        }
        if case let .pose(value, _) = frame, value.senderSlot == 2 {
          clientTwoHostPose.fulfill()
        }
        if case let .reliable(value, _) = frame, value.senderSlot == 2 {
          clientTwoHostReliable.fulfill()
          if value.sequence == 1 {
            if let link = clientLinks.two {
              Self.scheduleSend(link, frame: .pose(Self.pose(slot: 2, sequence: 1)))
            }
          }
        }
        let slots = Set(hostReceived.frames.compactMap(\.senderSlot))
        if slots.isSuperset(of: [UInt8(1), UInt8(2)]) {
          hostSlots.fulfill()
        }
      },
      listenersReadyHandler: { reliablePort, _ in
        if ports.set(NWEndpoint.Port(rawValue: reliablePort)!) {
          listenersReady.fulfill()
        }
      }
    )

    let clientConfiguration: (UInt8) -> NetworkPeerLinkConfiguration = { slot in
      NetworkPeerLinkConfiguration(
        serviceToken: "loopback-smoke",
        credentials: TransportCredentials(
          preSharedKey: self.key,
          identity: identity
        ),
        role: .client,
        localSlot: slot,
        playerCount: 3,
        advertisesService: false
      )
    }
    clientLinks.one = try NetworkPeerLink(
      remoteSlot: 0,
      configuration: clientConfiguration(1),
      receiveHandler: { frame, _, _ in
        clientOneReceived.append(frame)
        if case let .pose(value, relayed) = frame, value.senderSlot == 0, !relayed {
          hostPoseReachesBothClients.fulfill()
        }
        if case let .pose(value, relayed) = frame, value.senderSlot == 1, relayed {
          poseRelay.fulfill()
        }
      },
    )
    clientLinks.two = try NetworkPeerLink(
      remoteSlot: 0,
      configuration: clientConfiguration(2),
      receiveHandler: { frame, _, _ in
        clientTwoReceived.append(frame)
        if case let .pose(value, relayed) = frame, value.senderSlot == 0, !relayed {
          hostPoseReachesBothClients.fulfill()
        }
        if case let .pose(value, relayed) = frame, value.senderSlot == 1, relayed {
          XCTAssertTrue(relayed)
          poseRelay.fulfill()
        }
        if case let .reliable(value, relayed) = frame, value.senderSlot == 1, relayed {
          XCTAssertEqual(value.eventKind, .fire)
          reliableRelay.fulfill()
        }
      },
    )

    defer {
      clientLinks.one?.stop()
      clientLinks.two?.stop()
      host.stop()
    }

    host.start()
    wait(for: [listenersReady], timeout: 10)

    guard let reliablePort = ports.reliablePort else {
      return XCTFail("host did not expose a loopback listener port")
    }
    let endpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback),
      port: reliablePort
    )
    clientLinks.one?.connect(to: endpoint)
    clientLinks.two?.connect(to: endpoint)

    Self.scheduleSend(clientLinks.one!, frame: .reliable(Self.event(slot: 1, sequence: 1)))
    Self.scheduleSend(clientLinks.two!, frame: .reliable(Self.event(slot: 2, sequence: 1)))
    wait(for: [hostSlots, clientOneHostPose, clientOneHostReliable,
               clientTwoHostPose, clientTwoHostReliable], timeout: 10)
    XCTAssertEqual(hostReceived.frames.count > 0, true)

    try host.send(TransportFrame.pose(Self.pose(slot: 0, sequence: 1)))
    wait(for: [hostPoseReachesBothClients], timeout: 10)

    Self.scheduleSend(clientLinks.one!, frame: .pose(Self.pose(slot: 1, sequence: 2)))
    wait(for: [poseRelay], timeout: 10)
    Self.scheduleSend(clientLinks.one!, frame: .reliable(Self.event(slot: 1, sequence: 2)))
    wait(for: [reliableRelay], timeout: 10)

    clientLinks.two?.stop()
    Self.scheduleSend(clientLinks.one!, frame: .reliable(Self.event(slot: 1, sequence: 3)))
    Self.scheduleSend(clientLinks.one!, frame: .pose(Self.pose(slot: 1, sequence: 3)))
    wait(for: [continuityPose, continuityReliable], timeout: 10)
  }

  private static func scheduleSend(
    _ link: NetworkPeerLink,
    frame: TransportFrame
  ) {
    let deadline = Date().addingTimeInterval(9)
    func attempt() {
      guard Date() < deadline else { return }
      do {
        try link.send(frame)
      } catch {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: attempt)
      }
    }
    attempt()
  }

  private static func pose(slot: UInt8, sequence: UInt32) -> PoseFrame {
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

  private static func event(slot: UInt8, sequence: UInt32) -> ReliableEventFrame {
    ReliableEventFrame(
      epoch: 1,
      senderSlot: slot,
      sequence: sequence,
      eventKind: .fire,
      payload: Data([UInt8(sequence)])
    )
  }
}

private final class PortRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: NWEndpoint.Port?
  private var didSet = false

  var reliablePort: NWEndpoint.Port? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ port: NWEndpoint.Port) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    value = port
    let shouldFulfill = !didSet
    didSet = true
    return shouldFulfill
  }
}

private final class ClientLinks: @unchecked Sendable {
  var one: NetworkPeerLink?
  var two: NetworkPeerLink?
}

private final class FrameRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var frames: [TransportFrame] = []

  func append(_ frame: TransportFrame) {
    lock.lock()
    frames.append(frame)
    lock.unlock()
  }
}

private extension TransportFrame {
  var senderSlot: UInt8 {
    switch self {
    case let .pose(frame, _): frame.senderSlot
    case let .reliable(frame, _): frame.senderSlot
    case let .slotClaim(frame, _): frame.claimedSlot
    case let .pairingOffer(frame, _): frame.slot
    case let .pairingClaim(frame, _): frame.claimedSlot
    }
  }
}
#endif
