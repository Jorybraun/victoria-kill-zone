import Foundation
import XCTest

import CombatTransport
import PewPewSimulation

@testable import VictoriaKillZone

/// KIL-43 A1: the deterministic core and the peer transport are linked into the
/// app module. Until `ArenaHitEvaluator` is retired in favour of
/// `MatchSimulation`, this also pins its duplicated spatial constants to the
/// frozen values the simulation owns so the two cannot drift apart silently.
final class EngineLinkageTests: XCTestCase {
  func testSimulationCoreIsReachableFromTheAppModule() throws {
    var simulation = try MatchSimulation(playerIDs: [SimulationPlayerID("host"), SimulationPlayerID("guest")])
    XCTAssertEqual(simulation.clockMs, 0)
    simulation.advance()
    XCTAssertEqual(simulation.clockMs, 50)
  }

  func testTransportFrameCodecIsReachableFromTheAppModule() throws {
    let frame = PoseFrame(
      epoch: 1,
      senderSlot: 1,
      sequence: 1,
      timestampMs: 50,
      position: SIMD3<Float>(0, 0, 10),
      orientation: SIMD4<Float>(0, 0, 0, 1),
      tracking: .normal
    )
    var inbox = PoseInbox()
    XCTAssertTrue(inbox.admit(frame).accepted)
  }

  func testHarnessEvaluatorConstantsMatchTheSimulationCore() {
    XCTAssertEqual(ArenaHitEvaluator.proxyRadiusMeters, SimulationConstants.proxyRadiusMeters)
    XCTAssertEqual(ArenaHitEvaluator.minimumLaneMeters, SimulationConstants.minimumSeparationMeters)
    XCTAssertEqual(ArenaHitEvaluator.maximumLaneMeters, SimulationConstants.maximumRangeMeters)
    XCTAssertEqual(ArenaHitEvaluator.maximumRewindMs, SimulationConstants.rewindCapMilliseconds)
  }
}
