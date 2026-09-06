import Foundation
import XCTest

@testable import VictoriaKillZone

final class CombatPresentationPolicyTests: XCTestCase {
  func testSkeletonOnlyAppearsForAConfirmedHitAndExpiresWithoutPoseUpdates() {
    var presentation = HitSkeletonPresentation()
    XCTAssertFalse(presentation.isVisible(at: 10))

    presentation.confirmHit(at: 10)
    XCTAssertTrue(presentation.isVisible(at: 10))
    XCTAssertTrue(presentation.isVisible(at: 10.27))
    XCTAssertFalse(presentation.isVisible(at: 10.28))
    XCTAssertFalse(presentation.isVisible(at: 20))
  }

  func testRepeatedHitsExtendTheFlashButSessionCleanupRevokesIt() {
    var presentation = HitSkeletonPresentation()
    presentation.confirmHit(at: 10)
    presentation.confirmHit(at: 10.15)
    XCTAssertTrue(presentation.isVisible(at: 10.3))
    presentation.clear()
    XCTAssertFalse(presentation.isVisible(at: 10.3))
    XCTAssertNil(presentation.expiresAt)
  }

  func testInvalidClockValuesFailClosed() {
    var presentation = HitSkeletonPresentation()
    presentation.confirmHit(at: 5)
    XCTAssertFalse(presentation.isVisible(at: 4))
    XCTAssertFalse(presentation.isVisible(at: .nan))
    presentation.confirmHit(at: .infinity)
    XCTAssertFalse(presentation.isVisible(at: 5))
  }

  func testStaleFutureAndInvalidSkeletonTimestampsCannotPresentAnImpact() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertTrue(CombatPresentationPolicy.isPoseFresh(capturedAt: now, now: now))
    XCTAssertTrue(CombatPresentationPolicy.isPoseFresh(capturedAt: now.addingTimeInterval(-0.19), now: now))
    XCTAssertFalse(CombatPresentationPolicy.isPoseFresh(capturedAt: now.addingTimeInterval(-0.21), now: now))
    XCTAssertFalse(CombatPresentationPolicy.isPoseFresh(capturedAt: now.addingTimeInterval(1), now: now))
    XCTAssertFalse(CombatPresentationPolicy.isPoseFresh(capturedAt: Date(timeIntervalSince1970: .nan), now: now))
  }

  func testTracerPresentationHasBoundedTravelTimeAndRejectsMalformedGeometry() {
    XCTAssertEqual(CombatPresentationPolicy.tracerDuration(distance: 3), 0.045)
    XCTAssertEqual(CombatPresentationPolicy.tracerDuration(distance: 25)!, 25 / 180, accuracy: 0.00001)
    for distance in [0, -1, 26, Double.nan, .infinity] {
      XCTAssertNil(CombatPresentationPolicy.tracerDuration(distance: distance))
    }
  }

  func testCosmeticMuzzleKeepsParallaxWhenCameraTurnsAndConvergesWithinRange() {
    for heading: Float in [-1, 1] {
      let right = SIMD3<Float>(-heading, 0, 0)
      let up = SIMD3<Float>(0, 1, 0)
      let forward = SIMD3<Float>(0, 0, heading)
      let muzzle = CombatPresentationPolicy.cosmeticMuzzleOffset(
        cameraRight: right, cameraUp: up, cameraForward: forward
      )
      XCTAssertEqual(muzzle.x * right.x, 0.06, accuracy: 0.00001)
      XCTAssertEqual(muzzle.y, -0.045, accuracy: 0.00001)
      XCTAssertEqual(muzzle.z * forward.z, 0.10, accuracy: 0.00001)

      let originalRayEndpoint = forward * Float(CombatPresentationPolicy.maximumTracerDistance)
      let travel = originalRayEndpoint - muzzle
      let distance = Double((travel * travel).sum().squareRoot())
      XCTAssertNotNil(CombatPresentationPolicy.tracerDuration(distance: distance))
      XCTAssertNotEqual(muzzle.x, originalRayEndpoint.x, "A camera-collinear tracer would collapse to a reticle dot")
    }
  }

  func testThousandsOfShotsReuseFixedSlotsAndResetCleanly() {
    var pool = CombatEffectPoolCursor(capacity: CombatPresentationPolicy.tracerCapacity)
    var visited = Set<Int>()
    for _ in 0..<10_000 {
      let slot = pool.acquire()
      XCTAssertTrue((0..<CombatPresentationPolicy.tracerCapacity).contains(slot))
      visited.insert(slot)
    }
    XCTAssertEqual(visited.count, CombatPresentationPolicy.tracerCapacity)
    pool.reset()
    XCTAssertEqual(pool.acquire(), 0)
    var minimalPool = CombatEffectPoolCursor(capacity: 0)
    XCTAssertEqual(minimalPool.acquire(), 0)
    XCTAssertEqual(minimalPool.acquire(), 0)
  }
}

#if os(iOS) && canImport(ARKit)
  import ARKit

  @MainActor
  final class LaserFXSceneTests: XCTestCase {
    func testSceneStaysBoundedAndCleanupCannotBeUndoneByAPoseUpdate() async throws {
      let view = ARSCNView(frame: .zero)
      let engine = LaserFXEngine()
      engine.attach(to: view)
      let root = try XCTUnwrap(view.scene.rootNode.childNode(withName: "combat-effects", recursively: false))
      let skeletonRoot = try XCTUnwrap(root.childNode(withName: "confirmed-hit-skeleton", recursively: false))
      let ray = TargetingCameraRay(
        origin: TargetingVector3(x: 0, y: 0, z: 0),
        direction: TargetingVector3(x: 0, y: 0, z: -1),
        capturedAt: Date()
      )
      let skeleton = TargetingSkeleton(
        joints: (0..<100).map { index in
          TargetingSkeletonJoint(
            name: index == 0 ? "root" : "joint-\(index)",
            position: TargetingVector3(x: 0, y: Double(index) * 0.01, z: -3)
          )
        },
        bones: (1..<100).map { TargetingSkeletonBone(from: "root", to: "joint-\($0)") },
        capturedAt: Date()
      )

      engine.updateSkeleton(skeleton, zone: .torso)
      XCTAssertTrue(skeletonRoot.isHidden, "Tracking an unhit person must not reveal them")
      for _ in 0..<100 { engine.fireLaser(ray: ray) }
      let freshSkeleton = TargetingSkeleton(joints: skeleton.joints, bones: skeleton.bones, capturedAt: Date())
      engine.confirmHit(skeleton: freshSkeleton, zone: .torso)
      XCTAssertFalse(skeletonRoot.isHidden)
      XCTAssertEqual(root.childNodes.count, 1 + CombatPresentationPolicy.tracerCapacity + CombatPresentationPolicy.impactCapacity)
      XCTAssertLessThanOrEqual(skeletonRoot.childNodes.count, CombatPresentationPolicy.maximumSkeletonJoints + CombatPresentationPolicy.maximumSkeletonBones)

      engine.clearTransientEffects()
      XCTAssertTrue(root.childNodes.allSatisfy(\.isHidden))
      engine.updateSkeleton(freshSkeleton, zone: .head)
      XCTAssertTrue(skeletonRoot.isHidden)
      XCTAssertFalse(skeletonRoot.hasActions)
    }
  }
#endif
