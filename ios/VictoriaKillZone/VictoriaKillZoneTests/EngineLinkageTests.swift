import Foundation
import XCTest

import PewPewSimulation

@testable import VictoriaKillZone

/// KIL-43 A1: pins duplicated spatial constants to the frozen values owned by
/// `MatchSimulation` until `ArenaHitEvaluator` is retired.
final class EngineLinkageTests: XCTestCase {
  func testSimulationCoreIsReachableFromTheAppModule() throws {
    var simulation = try MatchSimulation(playerIDs: [SimulationPlayerID("host"), SimulationPlayerID("guest")])
    XCTAssertEqual(simulation.clockMs, 0)
    simulation.advance()
    XCTAssertEqual(simulation.clockMs, 50)
  }

  func testHarnessEvaluatorConstantsMatchTheSimulationCore() {
    XCTAssertEqual(ArenaHitEvaluator.proxyRadiusMeters, SimulationConstants.proxyRadiusMeters)
    XCTAssertEqual(ArenaHitEvaluator.minimumLaneMeters, SimulationConstants.minimumSeparationMeters)
    XCTAssertEqual(ArenaHitEvaluator.maximumLaneMeters, SimulationConstants.maximumRangeMeters)
    XCTAssertEqual(ArenaHitEvaluator.maximumRewindMs, SimulationConstants.rewindCapMilliseconds)
  }
}
