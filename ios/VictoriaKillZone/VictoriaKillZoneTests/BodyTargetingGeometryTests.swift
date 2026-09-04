import Foundation
import XCTest

@testable import VictoriaKillZone

final class BodyTargetingGeometryTests: XCTestCase {
  private let capturedAt = Date(timeIntervalSince1970: 1_000)

  func testRayStraightAtHeadSphereReturnsHead() {
    XCTAssertEqual(
      BodyTargetingGeometry.aimZone(
        joints: joints(headY: 1, neckY: 0.7),
        ray: ray(y: 1)
      ),
      .head
    )
  }

  func testRayAtMidTorsoReturnsTorso() {
    XCTAssertEqual(
      BodyTargetingGeometry.aimZone(
        joints: joints(headY: 1, neckY: 0.7),
        ray: ray(y: 0.35)
      ),
      .torso
    )
  }

  func testRayOneMeterToTheSideMisses() {
    XCTAssertNil(
      BodyTargetingGeometry.aimZone(
        joints: joints(headY: 1, neckY: 0.7),
        ray: TargetingCameraRay(
          origin: TargetingVector3(x: 1, y: 0, z: 0),
          direction: TargetingVector3(x: 0, y: 0, z: -1),
          capturedAt: capturedAt
        )
      )
    )
  }

  func testDegenerateCapsuleFallsBackToSphere() {
    let point = TargetingVector3(x: 0, y: 0.5, z: -2)
    XCTAssertTrue(
      BodyTargetingGeometry.rayIntersectsCapsule(
        ray(y: 0.5),
        start: point,
        end: point,
        radius: 0.18
      )
    )
  }

  func testHeadTakesPrecedenceWhenBothZonesIntersect() {
    XCTAssertEqual(
      BodyTargetingGeometry.aimZone(
        joints: joints(headY: 0.8, neckY: 0.7),
        ray: ray(y: 0.8)
      ),
      .head
    )
  }

  private func joints(headY: Double, neckY: Double) -> [String: TargetingVector3] {
    [
      "head": TargetingVector3(x: 0, y: headY, z: -2),
      "neck_1_joint": TargetingVector3(x: 0, y: neckY, z: -2),
      "root": TargetingVector3(x: 0, y: 0, z: -2),
    ]
  }

  private func ray(y: Double) -> TargetingCameraRay {
    TargetingCameraRay(
      origin: TargetingVector3(x: 0, y: y, z: 0),
      direction: TargetingVector3(x: 0, y: 0, z: -1),
      capturedAt: capturedAt
    )
  }
}
