import XCTest

@testable import PewPewSimulation

/// Hand-computed bounded-rewind fixtures. Every expected verdict is derived in
/// the comment above the test from the frozen baselines: 250 ms rewind cap,
/// 100 ms max pose age, 0.35 m proxy radius, 3 m minimum separation, 15 m
/// maximum range, 50 ms tick.
final class RewindFixtureTests: XCTestCase {

  // Rewind-window acceptance.
  // Shooter A at (0,0,0); target B's last pose at t=800 ms is (0,0,10).
  // The claim fires at t=800 and is evaluated at tick 20 (clock = 20 × 50 = 1000 ms):
  //   rewind = 1000 − 800 = 200 ms ≤ 250 ms cap            → accepted for rewind
  //   rewound pose = B@800, age = 800 − 800 = 0 ms ≤ 100 ms → pose fresh
  //   separation = |(0,0,10) − (0,0,0)| = 10 m, 3 ≤ 10 ≤ 15 → in band
  //   ray (0,0,1) from origin: closest approach to (0,0,10) is 0 m ≤ 0.35 m
  //   → HIT with appliedDamage = min(34, 100) = 34
  func testRewindWindowAcceptanceProducesHit() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 16,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )
    XCTAssertEqual(simulation.clockMs, 800)
    simulation.advance()
    simulation.advance()
    simulation.advance()

    let events = simulation.advance(inputs: [
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 800))
    ])

    XCTAssertEqual(simulation.clockMs, 1000)
    guard case .verdict(let record) = events.first else {
      return XCTFail("expected a verdict event, got \(events)")
    }
    XCTAssertEqual(record.verdict, .hit(appliedDamage: 34))
    XCTAssertEqual(record.rewindMilliseconds, 200)
    XCTAssertEqual(simulation.player(playerB)?.health, 66)
  }

  // Pose-too-old rejection.
  // B's newest pose at or before the fire time is B@600 ms. The claim fires at
  // t=750 and is evaluated at tick 16 (clock = 800 ms):
  //   rewind = 800 − 750 = 50 ms ≤ 250 ms cap        → inside the rewind window
  //   rewound pose = B@600, age = 750 − 600 = 150 ms > 100 ms max pose age
  //   → REJECTED(poseTooOld)
  func testStalePoseIsRejectedPoseTooOld() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 12,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )
    XCTAssertEqual(simulation.clockMs, 600)
    advanceFeedingPoses(&simulation, ticks: 3, positions: [(playerA, .zero)])

    let events = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 800, position: .zero)),
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 750)),
    ])

    XCTAssertEqual(simulation.clockMs, 800)
    XCTAssertEqual(verdicts(in: events), [.rejected(.poseTooOld)])
  }

  // Out-of-range rejection.
  // B's pose at t=1000 ms is (0,0,16); the claim fires at t=1000 and is
  // evaluated the same tick (clock = 1000 ms):
  //   rewind = 0 ms, pose age = 0 ms                       → both fresh
  //   separation = |(0,0,16)| = 16 m > 15 m maximum range
  //   → REJECTED(targetOutOfRange)
  func testSeparationBeyondMaximumRangeIsRejected() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 19,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 16))]
    )

    let events = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 1000, position: .zero)),
      .poseSample(playerB, PoseSample(timestampMs: 1000, position: Vector3(0, 0, 16))),
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1000)),
    ])

    XCTAssertEqual(simulation.clockMs, 1000)
    XCTAssertEqual(verdicts(in: events), [.rejected(.targetOutOfRange)])
  }

  // Minimum-separation rejection.
  // B's pose at t=1000 ms is (0,0,2.5); the claim fires at t=1000, clock = 1000 ms:
  //   rewind = 0 ms, pose age = 0 ms                    → both fresh
  //   separation = |(0,0,2.5)| = 2.5 m < 3 m minimum separation
  //   → REJECTED(targetTooClose)
  func testSeparationUnderMinimumIsRejected() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 19,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 2.5))]
    )

    let events = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 1000, position: .zero)),
      .poseSample(playerB, PoseSample(timestampMs: 1000, position: Vector3(0, 0, 2.5))),
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1000)),
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.targetTooClose)])
  }

  // Shot-too-late rejection.
  // The claim fires at t=700 but is evaluated at tick 21 (clock = 1050 ms):
  //   rewind = 1050 − 700 = 350 ms > 250 ms rewind cap
  //   → REJECTED(shotTooLate)
  func testRewindBeyondCapIsRejectedShotTooLate() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )
    XCTAssertEqual(simulation.clockMs, 1000)

    let events = simulation.advance(inputs: [
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 700))
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.shotTooLate)])
  }

  // Tracking-lost rejection.
  // B's latest pose at t=1000 ms carries tracking = lost, so B's transform is
  // untrusted regardless of its age → REJECTED(trackingLost).
  func testLostTrackingIsRejectedTrackingLost() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 19,
      positions: [(playerA, .zero), (playerB, Vector3(0, 0, 10))]
    )

    let events = simulation.advance(inputs: [
      .poseSample(playerA, PoseSample(timestampMs: 1000, position: .zero)),
      .poseSample(
        playerB,
        PoseSample(timestampMs: 1000, position: Vector3(0, 0, 10), tracking: .lost)
      ),
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1000)),
    ])

    XCTAssertEqual(verdicts(in: events), [.rejected(.trackingLost)])
  }

  // Geometry miss.
  // B's rewound pose is (0.5, 0, 10) but the ray runs along +z from the origin:
  //   separation = √(0.5² + 10²) ≈ 10.012 m → in band
  //   closest approach of the ray to the centre = 0.5 m > 0.35 m proxy radius
  //   → MISS (no damage, shotsFired increments, shotsHit does not)
  func testRayOutsideProxyRadiusIsMiss() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0.5, 0, 10))]
    )

    let events = simulation.advance(inputs: [
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1000))
    ])

    XCTAssertEqual(verdicts(in: events), [.miss])
    XCTAssertEqual(simulation.player(playerA)?.shotsFired, 1)
    XCTAssertEqual(simulation.player(playerA)?.shotsHit, 0)
    XCTAssertEqual(simulation.player(playerB)?.health, 100)
  }

  // Geometry graze.
  // B's rewound pose is (0.3, 0, 10); closest approach of the +z ray to the
  // centre = 0.3 m ≤ 0.35 m proxy radius → HIT.
  func testRayInsideProxyRadiusIsHit() throws {
    var simulation = try makeDuel()
    advanceFeedingPoses(
      &simulation,
      ticks: 20,
      positions: [(playerA, .zero), (playerB, Vector3(0.3, 0, 10))]
    )

    let events = simulation.advance(inputs: [
      .fire(fireClaim(shooter: playerA, target: playerB, origin: .zero, firedAtMs: 1000))
    ])

    XCTAssertEqual(verdicts(in: events), [.hit(appliedDamage: 34)])
  }
}
