import Foundation
import XCTest

@testable import VictoriaKillZone

final class SkeletonAnatomyTests: XCTestCase {
  func testCompletePosePlacesRecognizableAnatomyWithRigidAxes() {
    let placements = SkeletonAnatomyLayout.placements(for: anatomyPose())
    XCTAssertEqual(Set(placements.map(\.part)), Set(SkeletonAnatomyPart.allCases))
    for part in placements {
      XCTAssertEqual((part.right * part.right).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.up * part.up).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.back * part.back).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.right * part.up).sum(), 0, accuracy: 0.00001)
      XCTAssertTrue(part.size.x > 0 && part.size.y > 0 && part.size.z > 0)
    }
  }

  func testUpperArmEndsStayAtObservedShoulderAndElbow() throws {
    let pose = anatomyPose()
    let arm = try XCTUnwrap(SkeletonAnatomyLayout.placements(for: pose).first { $0.part == .leftUpperArm })
    let start = arm.position - arm.up * arm.size.y / 2
    let end = arm.position + arm.up * arm.size.y / 2
    let observedStart = try XCTUnwrap(pose.position(of: "left_arm_joint"))
    let observedEnd = try XCTUnwrap(pose.position(of: "left_forearm_joint"))
    XCTAssertEqual(start.x, observedStart.x, accuracy: 0.00001)
    XCTAssertEqual(start.y, observedStart.y, accuracy: 0.00001)
    XCTAssertEqual(end.x, observedEnd.x, accuracy: 0.00001)
    XCTAssertEqual(end.y, observedEnd.y, accuracy: 0.00001)
  }

  func testMissingLandmarksHideOnlyIncompleteAnatomy() {
    let pose = anatomyPose()
    let incomplete = TargetingSkeleton(joints: pose.joints.filter { !["head", "left_forearm_joint", "right_upLeg_joint"].contains($0.name) },
      bones: [], capturedAt: Date())
    let visible = Set(SkeletonAnatomyLayout.placements(for: incomplete).map(\.part))
    XCTAssertFalse(visible.contains(.skull))
    XCTAssertFalse(visible.contains(.cervicalSpine))
    XCTAssertFalse(visible.contains(.leftUpperArm))
    XCTAssertFalse(visible.contains(.leftForearm))
    XCTAssertFalse(visible.contains(.leftHand))
    XCTAssertFalse(visible.contains(.pelvis))
    XCTAssertFalse(visible.contains(.rightThigh))
    XCTAssertTrue(visible.contains(.ribcage))
    XCTAssertTrue(visible.contains(.rightUpperArm))
  }

  func testNeutralHandTemplateStartsAtObservedWristAndRequiresProximalOrientation() throws {
    let pose = anatomyPose()
    let hand = try XCTUnwrap(SkeletonAnatomyLayout.placements(for: pose).first { $0.part == .leftHand })
    let start = hand.position - hand.up * hand.size.y / 2
    let wrist = try XCTUnwrap(pose.position(of: "leftHand"))
    XCTAssertEqual(start.x, wrist.x, accuracy: 0.00001)
    XCTAssertEqual(start.y, wrist.y, accuracy: 0.00001)
    XCTAssertEqual(start.z, wrist.z, accuracy: 0.00001)
    let incomplete = TargetingSkeleton(joints: pose.joints.filter { !["left_leg_joint", "left_forearm_joint"].contains($0.name) },
      bones: [], capturedAt: Date())
    let visible = Set(SkeletonAnatomyLayout.placements(for: incomplete).map(\.part))
    XCTAssertFalse(visible.contains(.leftHand))
    XCTAssertFalse(visible.contains(.leftFoot))
    XCTAssertTrue(visible.contains(.rightHand))
    XCTAssertTrue(visible.contains(.rightFoot))
  }

  func testMalformedAndCollapsedLandmarksNeverProduceInvalidTransforms() {
    let pose = anatomyPose()
    let malformed = TargetingSkeleton(joints: pose.joints.map {
      TargetingSkeletonJoint(name: $0.name, position: TargetingVector3(x: .nan, y: .infinity, z: 0))
    }, bones: [], capturedAt: Date())
    XCTAssertTrue(SkeletonAnatomyLayout.placements(for: malformed).isEmpty)
    let unrepresentable = TargetingSkeleton(joints: pose.joints.map {
      TargetingSkeletonJoint(name: $0.name, position: TargetingVector3(x: 1e200, y: $0.position.y, z: 0))
    }, bones: [], capturedAt: Date())
    XCTAssertTrue(SkeletonAnatomyLayout.placements(for: unrepresentable).isEmpty)
    let collapsed = TargetingSkeleton(joints: pose.joints.map {
      TargetingSkeletonJoint(name: $0.name, position: TargetingVector3(x: 0, y: 0, z: 0))
    }, bones: [], capturedAt: Date())
    XCTAssertTrue(SkeletonAnatomyLayout.placements(for: collapsed).isEmpty)
  }
}

#if canImport(SceneKit)
  import SceneKit

  @MainActor
  final class SkeletonAnatomySceneTests: XCTestCase {
    func testAnatomyGeometryIsReusedAndMissingPartsHideAfterAPreviousFullPose() async throws {
      let model = SkeletonAnatomyModel()
      let pose = anatomyPose()
      model.update(pose, zone: .torso)
      let geometryNodes = model.root.childNodes.filter { $0.geometry != nil }
      XCTAssertEqual(geometryNodes.count, SkeletonAnatomyPart.allCases.count)
      XCTAssertTrue(geometryNodes.allSatisfy { !$0.isHidden })
      let geometryIDs = geometryNodes.map { ObjectIdentifier($0.geometry!) }
      for _ in 0..<100 { model.update(pose, zone: .head) }
      XCTAssertEqual(geometryNodes.map { ObjectIdentifier($0.geometry!) }, geometryIDs)
      XCTAssertEqual(model.root.childNodes.filter { $0.geometry != nil }.count, geometryNodes.count)
      let skull = try XCTUnwrap(model.root.childNode(withName: "skull", recursively: false)?.geometry)
      XCTAssertEqual(skull.elements.count, 2, "Skull mesh includes distinct cavity surfaces")
      let ribs = try XCTUnwrap(model.root.childNode(withName: "ribcage", recursively: false)?.geometry)
      XCTAssertGreaterThan(ribs.elements.reduce(0) { $0 + $1.primitiveCount }, 1_000)
      XCTAssertLessThan(geometryNodes.reduce(0) { $0 + ($1.geometry?.sources(for: .vertex).first?.vectorCount ?? 0) }, 30_000)
      model.update(TargetingSkeleton(joints: [], bones: [], capturedAt: Date()), zone: .torso)
      XCTAssertTrue(geometryNodes.allSatisfy(\.isHidden))
    }
  }
#endif

private func anatomyPose() -> TargetingSkeleton {
  let coordinates: [(String, Double, Double)] = [
    ("head", 0, 1.65), ("neck_1_joint", 0, 1.48), ("spine_7_joint", 0, 1.35), ("root", 0, 0.94),
    ("leftShoulder", 0.18, 1.45), ("rightShoulder", -0.18, 1.45),
    ("left_arm_joint", 0.26, 1.42), ("right_arm_joint", -0.26, 1.42),
    ("left_forearm_joint", 0.36, 1.13), ("right_forearm_joint", -0.36, 1.13),
    ("leftHand", 0.42, 0.91), ("rightHand", -0.42, 0.91),
    ("left_upLeg_joint", 0.12, 0.93), ("right_upLeg_joint", -0.12, 0.93),
    ("left_leg_joint", 0.12, 0.50), ("right_leg_joint", -0.12, 0.50),
    ("leftFoot", 0.12, 0.05), ("rightFoot", -0.12, 0.05),
  ]
  return TargetingSkeleton(joints: coordinates.map {
    TargetingSkeletonJoint(name: $0.0, position: TargetingVector3(x: $0.1, y: $0.2, z: 0))
  }, bones: [], capturedAt: Date())
}
