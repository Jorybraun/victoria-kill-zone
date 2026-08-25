import XCTest

@testable import PewPewSimulation

final class ProjectileWorldlineTests: XCTestCase {
  func testPositionIsUndefinedBeforeSpawn() {
    let worldline = ProjectileWorldline(
      projectileID: "proj-1",
      shooterID: playerA,
      spawnedAtMs: 500,
      origin: .zero,
      velocityMetersPerSecond: Vector3(0, 0, 20)
    )

    XCTAssertNil(worldline.position(atMs: 499))
    XCTAssertEqual(worldline.position(atMs: 500), .zero)
  }

  // Linear worldline: origin (1,2,3), v = (2,0,4) m/s, spawn at 500 ms.
  // At 1500 ms, t = 1 s → (1+2, 2+0, 3+4) = (3, 2, 7).
  func testLinearWorldlineIsPureFunctionOfTime() {
    let worldline = ProjectileWorldline(
      projectileID: "proj-2",
      shooterID: playerA,
      spawnedAtMs: 500,
      origin: Vector3(1, 2, 3),
      velocityMetersPerSecond: Vector3(2, 0, 4)
    )

    XCTAssertEqual(worldline.position(atMs: 1500), Vector3(3, 2, 7))
    XCTAssertEqual(worldline.position(atMs: 1500), worldline.position(atMs: 1500))
  }

  // Accelerated worldline: origin (1,2,3), v = (2,0,4) m/s, a = (0,-10,0) m/s²,
  // spawn at 500 ms. At 2500 ms, t = 2 s →
  //   (1 + 2·2, 2 + 0 − 0.5·10·4, 3 + 4·2) = (5, −18, 11).
  func testAcceleratedWorldlineMatchesHandComputation() {
    let worldline = ProjectileWorldline(
      projectileID: "proj-3",
      shooterID: playerA,
      spawnedAtMs: 500,
      origin: Vector3(1, 2, 3),
      velocityMetersPerSecond: Vector3(2, 0, 4),
      accelerationMetersPerSecondSquared: Vector3(0, -10, 0)
    )

    XCTAssertEqual(worldline.position(atMs: 2500), Vector3(5, -18, 11))
  }
}
