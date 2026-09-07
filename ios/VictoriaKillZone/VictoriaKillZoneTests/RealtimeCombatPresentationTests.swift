import Foundation
import XCTest

@testable import VictoriaKillZone

final class RealtimeCombatPresentationTests: XCTestCase {
  func testDisplayTimeFollowsAcceptedWorldlineWithoutUsingStalePosition() throws {
    var state = RealtimeCombatPresentation()
    let snapshot = realtimeFXSnapshot()
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    let projectile = try XCTUnwrap(state.projectiles.first)
    let start = try XCTUnwrap(RealtimeCombatPresentation.position(projectile, timing: XCTUnwrap(state.timing(at: 10))))
    let next = try XCTUnwrap(RealtimeCombatPresentation.position(projectile, timing: XCTUnwrap(state.timing(at: 10.016))))
    XCTAssertEqual(start, SIMD3<Double>(1, 2, 2.6))
    XCTAssertEqual(next.z, 2.472, accuracy: 0.000001)
  }

  func testAcceptedSlowSegmentChangesSpeedFromItsOwnOrigin() throws {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.matchTimeMs = 1100
    snapshot.projectiles[0].segmentStartedAtMs = 1100
    snapshot.projectiles[0].segmentOrigin = [1, 2, 2.2]
    snapshot.projectiles[0].timeScale = 0.25
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1100, localTime: 10))
    let projectile = try XCTUnwrap(state.projectiles.first)
    let position = try XCTUnwrap(RealtimeCombatPresentation.position(projectile, timing: XCTUnwrap(state.timing(at: 10.05))))
    XCTAssertEqual(position.z, 2.1, accuracy: 0.000001)
    XCTAssertEqual(snapshot.projectiles[0].direction, [0, 0, -1])
    XCTAssertEqual(snapshot.projectiles[0].speed, 8)
  }

  func testExtrapolationFreezesThenStaleStateHidesDespiteRepeatedUIUpdates() throws {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.matchTimeMs = 1000
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1000, localTime: 10))
    let projectile = try XCTUnwrap(state.projectiles.first)
    let bounded = try XCTUnwrap(RealtimeCombatPresentation.position(projectile, timing: XCTUnwrap(state.timing(at: 10.1))))
    let frozen = try XCTUnwrap(RealtimeCombatPresentation.position(projectile, timing: XCTUnwrap(state.timing(at: 10.2))))
    XCTAssertEqual(frozen.z, bounded.z, accuracy: 0.000001)
    XCTAssertNil(state.timing(at: 10.251))
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1200, localTime: 20))
    XCTAssertNil(state.timing(at: 20.051))
    XCTAssertFalse(state.update(snapshot, matchTimeMs: 1251, localTime: 21))
    XCTAssertTrue(state.projectiles.isEmpty)
  }

  func testSharedExpirationsUseActualClockWhileFlightIsFrozen() throws {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.projectiles[0].expiresAtMs = 1200
    snapshot.slowFields[0].endsAtMs = 1200
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    let timing = try XCTUnwrap(state.timing(at: 10.151))
    XCTAssertNil(RealtimeCombatPresentation.position(try XCTUnwrap(state.projectiles.first), timing: timing))
    XCTAssertFalse(RealtimeCombatPresentation.fieldVisible(try XCTUnwrap(state.fields.first), timing: timing))
  }

  func testShieldUsesAcceptedPhoneOrientationAndHidesWhenPoseBecomesStale() throws {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.phonePoses[0].pose.orientation = [0, sqrt(0.5), 0, sqrt(0.5)]
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    let shield = try XCTUnwrap(state.shields.first)
    XCTAssertEqual(shield.center.x, -0.15, accuracy: 0.000001)
    XCTAssertEqual(shield.center.y, 1, accuracy: 0.000001)
    XCTAssertEqual(shield.center.z, 0, accuracy: 0.000001)
    XCTAssertTrue(RealtimeCombatPresentation.shieldVisible(shield, timing: try XCTUnwrap(state.timing(at: 10))))
    XCTAssertFalse(RealtimeCombatPresentation.shieldVisible(shield, timing: try XCTUnwrap(state.timing(at: 10.101))))
    snapshot.players[0].frameReady = false
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 11))
    XCTAssertTrue(state.shields.isEmpty)
  }

  func testCapacityIsBoundedAndClearDropsEveryRetainedPresentation() {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    let projectile = snapshot.projectiles[0]
    snapshot.projectiles = (0..<128).map { index in
      var next = projectile
      next.projectileId = "projectile-\(index)"
      return next
    }
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    XCTAssertEqual(state.projectiles.count, 128)
    snapshot.projectiles.append(projectile)
    XCTAssertFalse(state.update(snapshot, matchTimeMs: 1050, localTime: 11))
    XCTAssertTrue(state.projectiles.isEmpty)
    XCTAssertTrue(state.update(realtimeFXSnapshot(), matchTimeMs: 1050, localTime: 12))
    state.clear()
    XCTAssertTrue(state.projectiles.isEmpty && state.shields.isEmpty && state.fields.isEmpty)
    XCTAssertNil(state.timing(at: 12))
  }

  func testEpochRollbackAndLateRunningSnapshotCannotRevivePausedEffects() {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.authorityEpoch = 2
    snapshot.frameEpoch = 2
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    var old = snapshot
    old.frameEpoch = 1
    XCTAssertFalse(state.update(old, matchTimeMs: 1050, localTime: 11))
    snapshot.phase = .paused
    snapshot.tick += 1
    XCTAssertFalse(state.update(snapshot, matchTimeMs: 1050, localTime: 12))
    old.frameEpoch = 2
    XCTAssertFalse(state.update(old, matchTimeMs: 1050, localTime: 13))
    XCTAssertTrue(state.projectiles.isEmpty)
    XCTAssertNil(state.timing(at: 13))
  }

  func testMalformedTransformsNeverReachSceneKit() {
    var state = RealtimeCombatPresentation()
    var snapshot = realtimeFXSnapshot()
    snapshot.projectiles[0].segmentOrigin = [1e200, 0, 0]
    snapshot.phonePoses[0].pose.orientation = [0, 0, 0, 0]
    snapshot.slowFields[0].center = [.nan, 0, 0]
    XCTAssertTrue(state.update(snapshot, matchTimeMs: 1050, localTime: 10))
    XCTAssertTrue(state.projectiles.isEmpty && state.shields.isEmpty && state.fields.isEmpty)
  }
}

#if os(iOS) && canImport(SceneKit)
  import SceneKit

  @MainActor
  final class RealtimeCombatSceneTests: XCTestCase {
    func testScenePoolsStayFixedAndClearHidesAllWorldEffects() async {
      let fx = RealtimeCombatFX()
      let initialCount = fx.root.childNodes.count
      XCTAssertEqual(initialCount, 128 + 4 + 4)
      let geometryIDs = fx.root.childNodes.compactMap { $0.geometry }.map(ObjectIdentifier.init)
      for _ in 0..<100 { fx.update(snapshot: realtimeFXSnapshot(), matchTimeMs: 1050) }
      XCTAssertEqual(fx.root.childNodes.count, initialCount)
      XCTAssertEqual(fx.root.childNodes.compactMap { $0.geometry }.map(ObjectIdentifier.init), geometryIDs)
      XCTAssertFalse(fx.root.childNodes.allSatisfy(\.isHidden))
      fx.clear()
      XCTAssertTrue(fx.root.childNodes.allSatisfy(\.isHidden))
    }
  }
#endif

private func realtimeFXSnapshot() -> CombatWire.Snapshot {
  let rules = CombatWire.Rules(durationMs: 180_000, geometry: "trackedBody", respawnMs: 5000, protectionMs: 2000,
    weapon: .init(id: "pulse", kind: "projectile", damage: .init(head: 75, torso: 34, limbs: 20),
      cooldownMs: 150, magazine: 8, reloadMs: 1250, speed: 8, projectileRadius: 0.015, lifetimeMs: 4000, rangeMeters: 25),
    shield: .init(radius: 0.4, offsetMeters: 0.15, durationMs: 2000, cooldownMs: 8000, energy: 100),
    slowField: .init(radius: 2, durationMs: 2000, cooldownMs: 10_000, scale: 0.25))
  let player = CombatWire.Player(playerId: "player-a", displayName: "A", role: "host", health: 100,
    ammo: 8, kills: 0, deaths: 0, connected: true, frameReady: true, lastFireAtMs: nil,
    reloadEndsAtMs: nil, respawnAtMs: nil, protectedUntilMs: nil,
    shield: .init(activeUntilMs: 2000, cooldownUntilMs: 8000, energy: 100), slowFieldReadyAtMs: 10_000)
  let projectile = CombatWire.Projectile(projectileId: "p", shotId: "shot", shooterId: "player-a",
    spawnedAtMs: 1000, position: [-99, -99, -99], direction: [0, 0, -1], speed: 8,
    segmentStartedAtMs: 1000, segmentOrigin: [1, 2, 3], timeScale: 1, radius: 0.015, expiresAtMs: 5000, distanceTravelled: 0)
  return CombatWire.Snapshot(matchId: "match", authorityEpoch: 1, frameEpoch: 1, tick: 21, matchTimeMs: 1050,
    phase: .running, rules: rules, players: [player], projectiles: [projectile],
    slowFields: [.init(fieldId: "field", ownerId: "player-a", center: [1, 1, 1], radius: 2, startsAtMs: 1000, endsAtMs: 3000, scale: 0.25)],
    phonePoses: [.init(playerId: "player-a", pose: .init(sequence: 1, capturedAtMs: 1050, position: [0, 1, 0], orientation: [0, 0, 0, 1], tracking: "normal"))])
}
