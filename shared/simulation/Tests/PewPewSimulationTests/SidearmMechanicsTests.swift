import Foundation
import XCTest

@testable import PewPewSimulation

/// KIL-42: Sidearm mechanics on the deterministic core — zoned proxy, optional
/// target with nearest-candidate resolution, always-fire misses, ammo/cooldown/
/// reload, death/respawn, and spawn protection. Ticks are 50 ms unless stated.
final class SidearmMechanicsTests: XCTestCase {
  private let forward = Vector3(0, 0, 1)
  private let bAt10 = Vector3(0, 0, 10)

  private func warmDuel(bPosition: Vector3 = Vector3(0, 0, 10), ticks: Int = 20) throws -> MatchSimulation {
    var simulation = try makeDuel()
    advanceFeedingPoses(&simulation, ticks: ticks, positions: [(playerA, .zero), (playerB, bPosition)])
    return simulation
  }

  private func fire(
    _ simulation: inout MatchSimulation,
    shotID: String,
    shooter: SimulationPlayerID = playerA,
    target: SimulationPlayerID? = nil,
    origin: Vector3 = .zero,
    direction: Vector3 = Vector3(0, 0, 1),
    firedAtMs: Int64? = nil
  ) -> [SimulationEvent] {
    let firedAt = firedAtMs ?? simulation.clockMs
    return simulation.advance(inputs: [
      .fire(fireClaim(shotID: shotID, shooter: shooter, target: target, origin: origin, direction: direction, firedAtMs: firedAt))
    ])
  }

  private func refusals(in events: [SimulationEvent]) -> [FireRefusalReason] {
    events.compactMap { event in
      if case .fireRefused(_, _, let reason, _) = event { return reason }
      return nil
    }
  }

  // MARK: - Zone geometry (pure)

  func testRayThroughPhoneOriginIsTorso() {
    let hit = ProxyGeometry.intersect(origin: .zero, direction: forward, proxyCenter: bAt10)
    XCTAssertEqual(hit?.zone, .torso)
    XCTAssertEqual(hit?.entryDistance ?? 0, 10 - SimulationConstants.proxyRadiusMeters, accuracy: 1e-9)
  }

  func testRayThroughTopOfEnvelopeIsHead() {
    // 0.21 m above the phone is the head sphere's centre.
    let hit = ProxyGeometry.intersect(origin: Vector3(0, 0.21, 0), direction: forward, proxyCenter: bAt10)
    XCTAssertEqual(hit?.zone, .head)
  }

  func testRayThroughShoulderBandIsLimbs() {
    // 0.30 m off-axis is inside the 0.35 m envelope but outside the 0.17 m torso capsule and the head.
    let hit = ProxyGeometry.intersect(origin: Vector3(0.30, 0, 0), direction: forward, proxyCenter: bAt10)
    XCTAssertEqual(hit?.zone, .limbs)
  }

  func testRayBelowTorsoBottomIsLimbs() {
    // 0.34 m below the phone: envelope yes (≤ 0.35), torso capsule bottom cap reaches −0.34 exactly → torso by tangency.
    XCTAssertEqual(
      ProxyGeometry.intersect(origin: Vector3(0, -0.34, 0), direction: forward, proxyCenter: bAt10)?.zone, .torso)
    // Just past the torso cap but still inside the envelope → limbs.
    XCTAssertEqual(
      ProxyGeometry.intersect(origin: Vector3(0.05, -0.34, 0), direction: forward, proxyCenter: bAt10)?.zone, .limbs)
  }

  func testEnvelopeEdgeJustInsideHitsAndJustOutsideMisses() {
    // The frozen §5.1 predicate |v|² − (v·d)² ≤ r² is evaluated in Double; at 10 m
    // the exact tangent (0.35) is below its resolution, so bracket it instead.
    XCTAssertNotNil(ProxyGeometry.intersect(origin: Vector3(0.349, 0, 0), direction: forward, proxyCenter: bAt10))
    XCTAssertNil(ProxyGeometry.intersect(origin: Vector3(0.351, 0, 0), direction: forward, proxyCenter: bAt10))
  }

  func testProxyBehindOriginIsNotHit() {
    XCTAssertNil(ProxyGeometry.intersect(origin: .zero, direction: Vector3(0, 0, -1), proxyCenter: bAt10))
  }

  func testHeadWinsTieWithTorsoAndFirstEntryWinsOtherwise() {
    // Descending ray that enters the head sphere before reaching the torso.
    let steep = Vector3(0, -0.2, 1).normalized!
    let fromAbove = ProxyGeometry.intersect(origin: Vector3(0, 2.21, 0), direction: steep, proxyCenter: bAt10)
    XCTAssertEqual(fromAbove?.zone, .head)
    // Ascending ray from below enters the torso first even though it also crosses the head.
    let rising = Vector3(0, 0.05, 1).normalized!
    let fromBelow = ProxyGeometry.intersect(origin: Vector3(0, -0.4, 0), direction: rising, proxyCenter: bAt10)
    XCTAssertEqual(fromBelow?.zone, .torso)
  }

  func testCapsuleEntryCoversCylinderBodyAndBothCaps() {
    let a = Vector3(0, -1, 10), b = Vector3(0, 1, 10)
    let body = ProxyGeometry.capsuleEntryDistance(origin: .zero, direction: forward, segmentStart: a, segmentEnd: b, radius: 0.5)
    XCTAssertEqual(body ?? 0, 9.5, accuracy: 1e-9)
    let topCap = ProxyGeometry.capsuleEntryDistance(origin: Vector3(0, 1.4, 0), direction: forward, segmentStart: a, segmentEnd: b, radius: 0.5)
    XCTAssertEqual(topCap ?? 0, 10 - 0.3, accuracy: 1e-9)
    XCTAssertNil(ProxyGeometry.capsuleEntryDistance(origin: Vector3(0, 1.6, 0), direction: forward, segmentStart: a, segmentEnd: b, radius: 0.5))
    // Parallel to the axis, straight down through the top cap.
    let alongAxis = ProxyGeometry.capsuleEntryDistance(origin: Vector3(0, 5, 10), direction: Vector3(0, -1, 0), segmentStart: a, segmentEnd: b, radius: 0.5)
    XCTAssertEqual(alongAxis ?? 0, 3.5, accuracy: 1e-9)
  }

  // MARK: - Zone damage through the simulation

  func testHeadshotAppliesSeventyFive() throws {
    var simulation = try warmDuel()
    let events = fire(&simulation, shotID: "head", origin: Vector3(0, 0.21, 0))
    XCTAssertEqual(verdicts(in: events), [.hit(zone: .head, appliedDamage: 75)])
    XCTAssertEqual(simulation.player(playerB)?.health, 25)
  }

  func testLimbHitAppliesTwenty() throws {
    var simulation = try warmDuel()
    let events = fire(&simulation, shotID: "limb", origin: Vector3(0.3, 0, 0))
    XCTAssertEqual(verdicts(in: events), [.hit(zone: .limbs, appliedDamage: 20)])
    XCTAssertEqual(simulation.player(playerB)?.health, 80)
  }

  // MARK: - Optional target and candidate resolution

  func testUnnamedClaimResolvesTargetFromRay() throws {
    var simulation = try warmDuel()
    let events = fire(&simulation, shotID: "open")
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict, got \(events)") }
    XCTAssertNil(record.shot.targetID)
    XCTAssertEqual(record.targetID, playerB)
    XCTAssertEqual(record.verdict, .hit(zone: .torso, appliedDamage: 34))
  }

  func testNearestOfTwoCandidatesOnTheRayTakesTheHit() throws {
    var simulation = try MatchSimulation(playerIDs: [playerA, playerB, playerC])
    advanceFeedingPoses(
      &simulation, ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 12)), (playerC, Vector3(0, 0, 6))])
    let events = fire(&simulation, shotID: "line")
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict") }
    XCTAssertEqual(record.targetID, playerC)
    XCTAssertEqual(simulation.player(playerC)?.health, 66)
    XCTAssertEqual(simulation.player(playerB)?.health, 100)
  }

  func testEquidistantCandidatesTieBreakByPlayerID() throws {
    // B and C at the same range; an exact tie on entry distance resolves to the lower ID.
    var simulation = try MatchSimulation(playerIDs: [playerC, playerB, playerA])
    advanceFeedingPoses(
      &simulation, ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10)), (playerC, Vector3(0, 0, 10))])
    let events = fire(&simulation, shotID: "tie")
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict") }
    XCTAssertEqual(record.targetID, playerB)
  }

  func testNamedTargetIsNeverRedirectedToTheNearestMember() throws {
    var simulation = try MatchSimulation(playerIDs: [playerA, playerB, playerC])
    advanceFeedingPoses(
      &simulation, ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 12)), (playerC, Vector3(0, 0, 6))])
    // A names B but C is in the way: only B is a candidate, and B is hit (C is not in the way geometrically for the sphere test of B).
    let events = fire(&simulation, shotID: "named", target: playerB)
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict") }
    XCTAssertEqual(record.targetID, playerB)
    XCTAssertEqual(simulation.player(playerC)?.health, 100)
  }

  func testNamedTargetReadingMatchesOpenReadingOnHits() throws {
    var named = try warmDuel()
    var open = try warmDuel()
    let namedEvents = fire(&named, shotID: "s", target: playerB)
    let openEvents = fire(&open, shotID: "s")
    XCTAssertEqual(verdicts(in: namedEvents), verdicts(in: openEvents))
    XCTAssertEqual(named.player(playerB), open.player(playerB))
  }

  func testDeadAndUntrackedMembersAreExcludedFromTheOpenCandidateSet() throws {
    var simulation = try MatchSimulation(playerIDs: [playerA, playerB, playerC])
    advanceFeedingPoses(
      &simulation, ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 12)), (playerC, Vector3(0, 0, 6))])
    // C loses tracking; the open ray passes through C's stale proxy and hits B behind it.
    let now = simulation.clockMs + 50
    let events = simulation.advance(inputs: [
      .poseSample(playerC, PoseSample(timestampMs: now, position: Vector3(0, 0, 6), tracking: .lost)),
      .poseSample(playerB, PoseSample(timestampMs: now, position: Vector3(0, 0, 12))),
      .fire(fireClaim(shotID: "through", shooter: playerA, origin: .zero, firedAtMs: now)),
    ])
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict") }
    XCTAssertEqual(record.verdict, .hit(zone: .torso, appliedDamage: 34))
    XCTAssertEqual(record.targetID, playerB)
  }

  // MARK: - Always-fire

  func testNoCandidateInViewIsAnAuthoritativeMissThatSpendsARound() throws {
    var simulation = try warmDuel()
    let events = fire(&simulation, shotID: "air", direction: Vector3(1, 0, 0))
    guard case .verdict(let record)? = events.first else { return XCTFail("expected verdict") }
    XCTAssertEqual(record.verdict, .miss)
    XCTAssertNil(record.targetID)
    XCTAssertEqual(simulation.player(playerA)?.ammo, 7)
    XCTAssertEqual(simulation.player(playerA)?.shotsFired, 1)
    XCTAssertEqual(simulation.player(playerA)?.shotsHit, 0)
  }

  func testEmptyArenaMissWhenEveryOtherMemberIsOutOfLane() throws {
    var simulation = try warmDuel(bPosition: Vector3(0, 0, 20))
    let events = fire(&simulation, shotID: "far-open")
    XCTAssertEqual(verdicts(in: events), [.miss])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 7)
  }

  // MARK: - Weapon gate

  func testCooldownRejectsAt100MsAndAcceptsAt150Ms() throws {
    var simulation = try warmDuel()
    _ = fire(&simulation, shotID: "one")
    advanceFeedingPoses(&simulation, ticks: 1, positions: [(playerA, .zero), (playerB, bAt10)])
    let tooSoon = fire(&simulation, shotID: "two")  // 100 ms later
    XCTAssertEqual(refusals(in: tooSoon), [.cooldownActive])
    XCTAssertTrue(verdicts(in: tooSoon).isEmpty)
    let onTime = fire(&simulation, shotID: "three")  // 150 ms after "one"
    XCTAssertEqual(verdicts(in: onTime), [.hit(zone: .torso, appliedDamage: 34)])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 6)
  }

  func testMagazineEmptyAfterEightRoundsUntilReload() throws {
    var simulation = try warmDuel(bPosition: Vector3(0, 0, 20))  // B out of lane → every shot is a miss
    for round in 1...8 {
      let events = fire(&simulation, shotID: "r\(round)")
      XCTAssertEqual(verdicts(in: events), [.miss], "round \(round)")
      advanceFeedingPoses(&simulation, ticks: 7, positions: [(playerA, .zero), (playerB, Vector3(0, 0, 20))])
    }
    XCTAssertEqual(simulation.player(playerA)?.ammo, 0)
    XCTAssertEqual(refusals(in: fire(&simulation, shotID: "dry")), [.magazineEmpty])
    XCTAssertEqual(simulation.player(playerA)?.shotsFired, 8)
  }

  func testReloadTakesExactlyTwelveHundredFiftyMsAndRefusesFireMeanwhile() throws {
    var simulation = try warmDuel()
    _ = fire(&simulation, shotID: "spend")
    let started = simulation.advance(inputs: [.reload(playerA)])
    let startClock = simulation.clockMs
    XCTAssertEqual(started, [.reloadStarted(player: playerA, endsAtMs: startClock + 1250, atTick: simulation.tick)])
    XCTAssertTrue(simulation.player(playerA)?.isReloading(atMs: startClock) ?? false)

    // 1200 ms in: still reloading.
    advanceFeedingPoses(&simulation, ticks: 23, positions: [(playerA, .zero), (playerB, bAt10)])
    XCTAssertEqual(simulation.clockMs, startClock + 1150)
    let duringReload = fire(&simulation, shotID: "mid-reload")  // evaluated at +1200
    XCTAssertEqual(refusals(in: duringReload), [.reloading])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 7)

    // Tick at +1250 completes the reload before inputs are applied.
    let completion = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: startClock + 1250, position: .zero)),
      .poseSample(playerB, PoseSample(timestampMs: startClock + 1250, position: bAt10)),
    ])
    XCTAssertEqual(completion, [.reloadCompleted(player: playerA, atTick: simulation.tick)])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 8)
    XCTAssertNil(simulation.player(playerA)?.reloadEndsAtMs)
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "after")), [.hit(zone: .torso, appliedDamage: 34)])
  }

  func testReloadIsIgnoredWhenMagazineIsFullOrAlreadyReloading() throws {
    var simulation = try warmDuel()
    XCTAssertEqual(simulation.advance(inputs: [.reload(playerA)]), [])
    _ = fire(&simulation, shotID: "spend")
    XCTAssertEqual(simulation.advance(inputs: [.reload(playerA)]).count, 1)
    XCTAssertEqual(simulation.advance(inputs: [.reload(playerA)]), [])
  }

  func testSameTickFireThenReloadLetsTheShotOut() throws {
    var simulation = try warmDuel()
    let now = simulation.clockMs + 50
    let events = simulation.advance(inputs: [
      .reload(playerA),
      .fire(fireClaim(shotID: "last-round", shooter: playerA, origin: .zero, firedAtMs: now)),
    ])
    XCTAssertEqual(verdicts(in: events), [.hit(zone: .torso, appliedDamage: 34)])
    XCTAssertEqual(events.last, .reloadStarted(player: playerA, endsAtMs: now + 1250, atTick: simulation.tick))
  }

  // MARK: - Death, respawn, spawn protection

  private func killB(_ simulation: inout MatchSimulation) -> [SimulationEvent] {
    var all: [SimulationEvent] = []
    // 75 (head) + 34 (torso) = 109 ≥ 100, two shots one cooldown apart.
    all += fire(&simulation, shotID: "k-head", origin: Vector3(0, 0.21, 0))
    advanceFeedingPoses(&simulation, ticks: 7, positions: [(playerA, .zero), (playerB, bAt10)])
    all += fire(&simulation, shotID: "k-torso")
    return all
  }

  func testLethalShotSchedulesRespawnAndClearsReload() throws {
    var simulation = try warmDuel()
    _ = fire(&simulation, shotID: "b-spend", shooter: playerB, origin: bAt10, direction: Vector3(0, 0, -1))
    _ = simulation.advance(inputs: [.reload(playerB)])
    XCTAssertNotNil(simulation.player(playerB)?.reloadEndsAtMs)

    let events = killB(&simulation)
    let killTick = simulation.tick
    XCTAssertEqual(verdicts(in: events), [.hit(zone: .head, appliedDamage: 75), .hit(zone: .torso, appliedDamage: 25)])
    XCTAssertEqual(events.last, .playerKilled(target: playerB, by: playerA, atTick: killTick))
    let b = try XCTUnwrap(simulation.player(playerB))
    XCTAssertEqual(b.lifeState, .dead)
    XCTAssertEqual(b.health, 0)
    XCTAssertEqual(b.respawnAtMs, simulation.clockMs + 5000)
    XCTAssertNil(b.reloadEndsAtMs)
  }

  func testRespawnAfterFiveSecondsRestoresHealthAndMagazineWithProtection() throws {
    var simulation = try warmDuel()
    _ = killB(&simulation)
    let deathClock = simulation.clockMs

    // 4950 ms later: still dead.
    advanceFeedingPoses(&simulation, ticks: 99, positions: [(playerA, .zero), (playerB, bAt10)])
    XCTAssertEqual(simulation.player(playerB)?.lifeState, .dead)

    let respawnEvents = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: deathClock + 5000, position: .zero)),
      .poseSample(playerB, PoseSample(timestampMs: deathClock + 5000, position: bAt10)),
    ])
    XCTAssertEqual(simulation.clockMs, deathClock + 5000)
    XCTAssertEqual(
      respawnEvents,
      [.playerRespawned(player: playerB, protectedUntilMs: deathClock + 7000, atTick: simulation.tick)])
    let b = try XCTUnwrap(simulation.player(playerB))
    XCTAssertEqual(b.lifeState, .alive)
    XCTAssertEqual(b.health, 100)
    XCTAssertEqual(b.ammo, 8)
    XCTAssertEqual(b.deaths, 1)
    XCTAssertTrue(b.isSpawnProtected(atMs: simulation.clockMs))
  }

  func testSpawnProtectedPlayerCannotFireAndIsTransparentToRays() throws {
    var simulation = try warmDuel()
    _ = killB(&simulation)
    advanceFeedingPoses(&simulation, ticks: 100, positions: [(playerA, .zero), (playerB, bAt10)])
    XCTAssertEqual(simulation.player(playerB)?.lifeState, .alive)

    // B presses fire while protected.
    let refused = fire(&simulation, shotID: "b-protected", shooter: playerB, origin: bAt10, direction: Vector3(0, 0, -1))
    XCTAssertEqual(refusals(in: refused), [.spawnProtected])
    XCTAssertEqual(simulation.player(playerB)?.ammo, 8)

    // A shoots straight at protected B: open reading and named reading both miss, round spent.
    let open = fire(&simulation, shotID: "a-open")
    XCTAssertEqual(verdicts(in: open), [.miss])
    advanceFeedingPoses(&simulation, ticks: 7, positions: [(playerA, .zero), (playerB, bAt10)])
    let named = fire(&simulation, shotID: "a-named", target: playerB)
    XCTAssertEqual(verdicts(in: named), [.miss])
    XCTAssertEqual(simulation.player(playerB)?.health, 100)
    XCTAssertEqual(simulation.player(playerA)?.shotsFired, 4)
  }

  func testSpawnProtectionLapsesAfterTwoSeconds() throws {
    var simulation = try warmDuel()
    _ = killB(&simulation)
    let deathClock = simulation.clockMs
    advanceFeedingPoses(&simulation, ticks: 100, positions: [(playerA, .zero), (playerB, bAt10)])  // respawned at +5000
    advanceFeedingPoses(&simulation, ticks: 39, positions: [(playerA, .zero), (playerB, bAt10)])  // +6950
    XCTAssertEqual(refusals(in: fire(&simulation, shotID: "b-early", shooter: playerB, origin: bAt10, direction: Vector3(0, 0, -1), firedAtMs: deathClock + 6999)), [.spawnProtected])
    let free = fire(&simulation, shotID: "b-free", shooter: playerB, origin: bAt10, direction: Vector3(0, 0, -1), firedAtMs: deathClock + 7000)
    XCTAssertEqual(verdicts(in: free), [.hit(zone: .torso, appliedDamage: 34)])
    XCTAssertFalse(simulation.player(playerB)?.isSpawnProtected(atMs: deathClock + 7000) ?? true)
  }

  func testDeadPlayerCannotReload() throws {
    var simulation = try warmDuel()
    _ = killB(&simulation)
    XCTAssertEqual(simulation.advance(inputs: [.reload(playerB)]), [])
  }

  // MARK: - Ingress and named-target validation do not spend rounds

  func testSelfOrNonMemberNamedTargetIsRejectedWithoutSpendingARound() throws {
    var simulation = try warmDuel()
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "self", target: playerA)), [.rejected(.invalidTarget)])
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "ghost", target: playerD)), [.rejected(.invalidTarget)])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 8)
    XCTAssertEqual(simulation.player(playerA)?.shotsFired, 0)
  }

  func testDegenerateOrNonFiniteRayIsTrackingLostAtIngress() throws {
    var simulation = try warmDuel()
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "zero", direction: .zero)), [.rejected(.trackingLost)])
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "nan", direction: Vector3(.nan, 0, 1))), [.rejected(.trackingLost)])
    XCTAssertEqual(verdicts(in: fire(&simulation, shotID: "inf", origin: Vector3(0, .infinity, 0))), [.rejected(.trackingLost)])
    XCTAssertEqual(simulation.player(playerA)?.ammo, 8)
  }

  func testShooterSideRejectionsPrecedeTheWeaponGate() throws {
    var simulation = try warmDuel()
    _ = fire(&simulation, shotID: "spend")
    // Both too late and inside the cooldown: shotTooLate is reported, no refusal.
    let events = fire(&simulation, shotID: "late-and-hot", firedAtMs: simulation.clockMs - 300)
    XCTAssertEqual(verdicts(in: events), [.rejected(.shotTooLate)])
    XCTAssertTrue(refusals(in: events).isEmpty)
  }

  // MARK: - Determinism across the new state

  func testFullLifecycleLogReplaysByteIdentically() throws {
    var log: [[SimulationInput]] = []
    let layout: [(SimulationPlayerID, Vector3)] = [(playerA, .zero), (playerB, bAt10), (playerC, Vector3(0, 0, 6))]
    for tickIndex in 1...220 {
      let t = Int64(tickIndex) * 50
      var inputs: [SimulationInput] = layout.map { .poseSample($0.0, PoseSample(timestampMs: t, position: $0.1)) }
      switch tickIndex {
      case 20: inputs.append(.fire(fireClaim(shotID: "a-head", shooter: playerA, origin: Vector3(0, 0.21, 0), firedAtMs: t)))
      case 27: inputs.append(.fire(fireClaim(shotID: "a-torso", shooter: playerA, origin: .zero, firedAtMs: t)))  // kills C (nearest)
      case 28: inputs.append(.reload(playerA))
      case 30: inputs.append(.fire(fireClaim(shotID: "a-while-reloading", shooter: playerA, origin: .zero, firedAtMs: t)))
      case 60: inputs.append(.fire(fireClaim(shotID: "a-after-reload", shooter: playerA, target: playerB, origin: .zero, firedAtMs: t)))
      case 130: inputs.append(.fire(fireClaim(shotID: "c-protected", shooter: playerC, origin: Vector3(0, 0, 6), direction: Vector3(0, 0, -1), firedAtMs: t)))
      case 170: inputs.append(.fire(fireClaim(shotID: "c-free", shooter: playerC, origin: Vector3(0, 0, 6), direction: Vector3(0, 0, -1), firedAtMs: t)))
      default: break
      }
      log.append(inputs)
    }
    let first = try replay(playerIDs: [playerA, playerB, playerC], log: log)
    let second = try replay(playerIDs: [playerA, playerB, playerC], log: log)
    XCTAssertEqual(try encoded(first), try encoded(second))

    let kinds = first.map { event -> String in
      switch event {
      case .verdict(let r): return "verdict:\(r.shot.shotID)"
      case .playerKilled(let t, _, _): return "killed:\(t)"
      case .fireRefused(let id, _, let reason, _): return "refused:\(id):\(reason)"
      case .reloadStarted(let p, _, _): return "reloadStarted:\(p)"
      case .reloadCompleted(let p, _): return "reloadCompleted:\(p)"
      case .playerRespawned(let p, _, _): return "respawned:\(p)"
      }
    }
    XCTAssertEqual(
      kinds,
      [
        "verdict:a-head", "verdict:a-torso", "killed:player-c", "reloadStarted:player-a",
        "refused:a-while-reloading:reloading", "reloadCompleted:player-a", "verdict:a-after-reload",
        "respawned:player-c", "refused:c-protected:spawnProtected", "verdict:c-free",
      ])
  }

  private func encoded(_ events: [SimulationEvent]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(events)
  }
}
