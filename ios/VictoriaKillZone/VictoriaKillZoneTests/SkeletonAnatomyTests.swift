import Foundation
import XCTest

@testable import VictoriaKillZone

final class SkeletonAnatomyTests: XCTestCase {
  func testNeutralPoseUsesRightHandedAnatomicalFramesAndHumeralWidth() throws {
    let placements = SkeletonAnatomyLayout.placements(for: anatomyPose())
    XCTAssertEqual(Set(placements.map(\.part)), Set(SkeletonAnatomyPart.allCases))
    for part in placements {
      XCTAssertEqual((part.right * part.right).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.up * part.up).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.back * part.back).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual((part.right * part.up).sum(), 0, accuracy: 0.00001)
      XCTAssertEqual((cross(part.right, part.up) * part.back).sum(), 1, accuracy: 0.00001)
      XCTAssertEqual(part.size.x, 0.4, accuracy: 0.00001,
        "The 0.14m medial shoulder separation must not collapse the imported chest")
      XCTAssertTrue(part.size.y > 0 && part.size.z > 0)
    }
    for part in placements where [.leftThigh, .rightThigh, .leftShin, .rightShin, .leftFoot, .rightFoot].contains(part.part) {
      XCTAssertGreaterThan(part.back.z, 0.99, "Anterior must stay forward on the legs and feet")
    }
  }

  func testLimbFramesUseObservedJointPivotsInsteadOfBoundingBoxCenters() throws {
    let pose = anatomyPose()
    for (part, proximalName, distalName) in [
      (SkeletonAnatomyPart.leftUpperArm, "left_arm_joint", "left_forearm_joint"),
      (.leftForearm, "left_forearm_joint", "leftHand"),
      (.rightThigh, "right_upLeg_joint", "right_leg_joint"),
    ] {
      let frame = try XCTUnwrap(SkeletonAnatomyLayout.placements(for: pose).first { $0.part == part })
      assertPoint(frame.position, try point(proximalName, pose))
      assertPoint(frame.position - frame.up * frame.size.y, try point(distalName, pose))
    }
    let hand = try XCTUnwrap(SkeletonAnatomyLayout.placements(for: pose).first { $0.part == .leftHand })
    assertPoint(hand.position, try point("leftHand", pose))
  }

  func testBentElbowsAndGlobalTurnPreserveJointEndpointsAndAnatomicalHandedness() throws {
    let bent = anatomyPose(replacing: ["leftHand": SIMD3(0.26, 1.125, 0.257), "rightHand": SIMD3(-0.26, 1.125, 0.257)])
    let frames = SkeletonAnatomyLayout.placements(for: bent)
    let arm = try XCTUnwrap(frames.first { $0.part == .leftForearm })
    assertPoint(arm.up, SIMD3(0, 0, -1))
    XCTAssertGreaterThan(arm.back.y, 0.99)
    let turned = mapPose(bent) { SIMD3($0.z, $0.y, -$0.x) }
    let turnedFrames = SkeletonAnatomyLayout.placements(for: turned)
    for frame in frames {
      let rotated = try XCTUnwrap(turnedFrames.first { $0.part == frame.part })
      assertPoint(rotated.position, SIMD3(frame.position.z, frame.position.y, -frame.position.x))
      assertPoint(rotated.back, SIMD3(frame.back.z, frame.back.y, -frame.back.x))
    }
  }

  func testLateralArmExtensionDoesNotFlipRollApproachedFromEitherDirection() throws {
    for degrees in [Array(70...110), Array((70...110).reversed())] {
      var prior: [SkeletonAnatomyPart: SkeletonAnatomyPlacement] = [:]
      for degree in degrees {
        let angle = Double(degree) * .pi / 180
        let shoulder = SIMD3<Double>(0.20, 1.435, 0)
        let elbow = shoulder + SIMD3(sin(angle), -cos(angle), 0) * 0.315
        let pose = anatomyPose(replacing: ["left_forearm_joint": elbow])
        let frames = SkeletonAnatomyLayout.placements(for: pose, previous: prior)
        let arm = try XCTUnwrap(frames.first { $0.part == .leftUpperArm })
        XCTAssertGreaterThan(arm.back.z, 0.999)
        if let before = prior[.leftUpperArm] {
          XCTAssertGreaterThan((before.right * arm.right).sum(), 0.99)
        }
        prior = Dictionary(uniqueKeysWithValues: frames.map { ($0.part, $0) })
      }
    }
  }

  func testCrouchUsesObservedSegmentSpansRatherThanVerticalSkeletonScaling() throws {
    let crouch = anatomyPose(replacing: [
      "root": SIMD3(0, 0.73, 0.04), "neck_1_joint": SIMD3(0, 1.22, 0.14),
      "head": SIMD3(0, 1.36, 0.16), "left_arm_joint": SIMD3(0.20, 1.17, 0.14),
      "right_arm_joint": SIMD3(-0.20, 1.17, 0.14),
      "left_upLeg_joint": SIMD3(0.10, 0.70, 0.08), "right_upLeg_joint": SIMD3(-0.10, 0.70, 0.08),
      "left_leg_joint": SIMD3(0.10, 0.38, 0.34), "right_leg_joint": SIMD3(-0.10, 0.38, 0.34),
    ])
    let thigh = try XCTUnwrap(SkeletonAnatomyLayout.placements(for: crouch).first { $0.part == .leftThigh })
    assertPoint(thigh.position - thigh.up * thigh.size.y, try point("left_leg_joint", crouch))
    XCTAssertEqual(thigh.size.y, sqrt(0.32 * 0.32 + 0.26 * 0.26), accuracy: 0.00001)
    XCTAssertGreaterThan(thigh.back.z, 0)
  }

  func testMissingLandmarksHideOnlyDependentAnatomy() {
    let pose = anatomyPose()
    let incomplete = TargetingSkeleton(joints: pose.joints.filter {
      !["head", "leftHand", "rightFoot", "right_upLeg_joint"].contains($0.name)
    }, bones: [], capturedAt: Date())
    let visible = Set(SkeletonAnatomyLayout.placements(for: incomplete).map(\.part))
    for part: SkeletonAnatomyPart in [.skull, .cervicalSpine, .leftForearm, .leftHand, .rightShin, .rightFoot, .pelvis, .rightThigh] {
      XCTAssertFalse(visible.contains(part))
    }
    for part: SkeletonAnatomyPart in [.ribcage, .leftUpperArm, .rightUpperArm, .leftThigh, .leftShin, .leftFoot] {
      XCTAssertTrue(visible.contains(part))
    }
  }

  func testMalformedAndCollapsedLandmarksNeverProduceInvalidTransforms() {
    for value: SIMD3<Double> in [SIMD3(.nan, .infinity, 0), SIMD3(1e200, 0, 0), .zero] {
      XCTAssertTrue(SkeletonAnatomyLayout.placements(for: mapPose(anatomyPose()) { _ in value }).isEmpty)
    }
  }
}

#if canImport(SceneKit)
  import SceneKit
  import simd

  @MainActor
  final class SkeletonAnatomySceneTests: XCTestCase {
    func testActualBundledAssetDecodesWithinGeometryBudget() async throws {
      let url = try XCTUnwrap(SkeletonMeshAsset.defaultURL, "The actual mesh must ship in the app and Swift package")
      let parts = try SkeletonMeshAsset.load(url)
      XCTAssertEqual(Set(parts.map(\.name)), Set(SkeletonAnatomyPart.allCases.map(\.rawValue)))
      let triangles = parts.reduce(0) { $0 + $1.geometry.elements.reduce(0) { $0 + $1.primitiveCount } }
      XCTAssertGreaterThan(triangles, 30_000)
      XCTAssertLessThanOrEqual(triangles, 52_000)
      XCTAssertLessThanOrEqual(parts.reduce(0) { $0 + $1.geometry.elements.count }, 32)
      XCTAssertTrue(parts.allSatisfy { SkeletonMeshAsset.validBind($0.bindTransform) })
    }

    func testAnatomicalAssetReuseAndMissingPartsHideAfterFullPose() async throws {
      let model = SkeletonAnatomyModel()
      XCTAssertTrue(model.geometryLoaded)
      let nodes = model.root.childNodes.filter { $0.geometry != nil }
      XCTAssertEqual(nodes.count, SkeletonAnatomyPart.allCases.count)
      XCTAssertTrue(nodes.allSatisfy(\.isHidden), "No anatomy is visible before the hit owner updates it")
      model.update(anatomyPose(), zone: .torso)
      XCTAssertTrue(nodes.allSatisfy { !$0.isHidden })
      let geometryIDs = nodes.map { ObjectIdentifier($0.geometry!) }
      for _ in 0..<100 { model.update(anatomyPose(), zone: .head) }
      XCTAssertEqual(nodes.map { ObjectIdentifier($0.geometry!) }, geometryIDs)
      let other = SkeletonAnatomyModel()
      XCTAssertEqual(other.root.childNodes.compactMap { $0.geometry.map(ObjectIdentifier.init) }, geometryIDs)
      model.update(TargetingSkeleton(joints: [], bones: [], capturedAt: Date()), zone: .torso)
      XCTAssertTrue(nodes.allSatisfy(\.isHidden))
      XCTAssertEqual(model.root.childNodes.filter { $0.geometry != nil }.count, nodes.count)
    }

    func testImportedBindPivotsMapExactlyToObservedBentArmJoints() async throws {
      let pose = anatomyPose(replacing: ["leftHand": SIMD3(0.26, 1.125, 0.257)])
      let model = SkeletonAnatomyModel()
      model.update(pose, zone: nil)
      let asset = try XCTUnwrap(SkeletonMeshAsset.bundled.first { $0.name == "leftForearm" })
      let node = try XCTUnwrap(model.root.childNode(withName: asset.name, recursively: false))
      let sourceProximal = asset.bindTransform.columns.3
      let sourceDistal = sourceProximal - asset.bindTransform.columns.1
      let proximal = node.simdTransform * sourceProximal, distal = node.simdTransform * sourceDistal
      assertPoint(SIMD3(Double(proximal.x), Double(proximal.y), Double(proximal.z)), try point("left_forearm_joint", pose))
      assertPoint(SIMD3(Double(distal.x), Double(distal.y), Double(distal.z)), try point("leftHand", pose))
      XCTAssertGreaterThan(simd_determinant(node.simdTransform), 0)
    }

    func testSourceLandmarksReconstructUnmodifiedAnatomicalSourceGeometry() async throws {
      let assetURL = try XCTUnwrap(SkeletonMeshAsset.defaultURL)
      let data = try Data(contentsOf: assetURL.deletingLastPathComponent().appendingPathComponent("manifest.json"))
      let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let positions = try XCTUnwrap(manifest["sourceLandmarksMeters"] as? [String: [Double]])
      let pose = TargetingSkeleton(joints: positions.map { name, p in
        TargetingSkeletonJoint(name: name, position: TargetingVector3(x: p[0], y: p[1], z: p[2]))
      }, bones: [], capturedAt: Date())
      let model = SkeletonAnatomyModel()
      model.update(pose, zone: nil)
      for node in model.root.childNodes where node.geometry != nil {
        XCTAssertFalse(node.isHidden)
        for column in 0..<4 {
          for row in 0..<4 {
            XCTAssertEqual(node.simdTransform[column][row], column == row ? 1 : 0,
              accuracy: 0.00001, "Source bind must preserve original bone proportions and offsets: \(node.name ?? "part")")
          }
        }
      }
    }

    func testMalformedAssetCannotCreateVisibleFallback() async throws {
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(Data("SKN1".utf8)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(singular: true)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(perspective: true)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(normal: SIMD3(0, 0, 0))))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(color: 2)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(index: 3)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(position: .infinity)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture(position: 50)))
      XCTAssertThrowsError(try SkeletonMeshAsset.decode(meshFixture() + Data([0])))
      XCTAssertEqual(try SkeletonMeshAsset.decode(meshFixture()).count, 19)
      var mirrored = matrix_identity_float4x4
      mirrored[0].x = -1
      XCTAssertFalse(SkeletonMeshAsset.validBind(mirrored))
      var sheared = matrix_identity_float4x4
      sheared[1].x = 0.1
      XCTAssertFalse(SkeletonMeshAsset.validBind(sheared))
      let model = SkeletonAnatomyModel(assetParts: [])
      model.update(anatomyPose(), zone: .head)
      XCTAssertFalse(model.geometryLoaded)
      XCTAssertTrue(model.root.childNodes.isEmpty)
    }
  }

  private func meshFixture(singular: Bool = false, perspective: Bool = false,
    normal: SIMD3<Float> = SIMD3(0, 0, 1), color: Float = 1, index: UInt32 = 2,
    position: Float = 0) -> Data {
    var data = Data("SKN1".utf8)
    func append<T: FixedWidthInteger>(_ number: T) {
      var little = number.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func number(_ float: Float) { append(float.bitPattern) }
    append(UInt32(19))
    for part in SkeletonAnatomyPart.allCases {
      let name = Data(part.rawValue.utf8)
      append(UInt16(name.count)); data.append(name)
      for column in 0..<4 {
        for row in 0..<4 {
          number(column == 0 && row == 0 && singular ? 0
            : column == 0 && row == 3 && perspective ? 1 : column == row ? 1 : 0)
        }
      }
      append(UInt32(3)); append(UInt32(3))
      for vertex in [SIMD3<Float>(position, 0, 0), SIMD3<Float>(0.1, 0, 0), SIMD3<Float>(0, 0.1, 0)] {
        for value in [vertex.x, vertex.y, vertex.z, normal.x, normal.y, normal.z, color, color, color, Float(1)] { number(value) }
      }
      append(UInt32(0)); append(UInt32(1)); append(index)
    }
    return data
  }
#endif

private func point(_ name: String, _ skeleton: TargetingSkeleton) throws -> SIMD3<Double> {
  let point = try XCTUnwrap(skeleton.position(of: name))
  return SIMD3(point.x, point.y, point.z)
}
private func assertPoint(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>,
  file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001, file: file, line: line)
  XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001, file: file, line: line)
  XCTAssertEqual(actual.z, expected.z, accuracy: 0.00001, file: file, line: line)
}
private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
private func mapPose(_ pose: TargetingSkeleton, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> TargetingSkeleton {
  TargetingSkeleton(joints: pose.joints.map {
    let p = transform(SIMD3($0.position.x, $0.position.y, $0.position.z))
    return TargetingSkeletonJoint(name: $0.name, position: TargetingVector3(x: p.x, y: p.y, z: p.z))
  }, bones: [], capturedAt: Date())
}
private func anatomyPose(replacing: [String: SIMD3<Double>] = [:]) -> TargetingSkeleton {
  let coordinates: [(String, SIMD3<Double>)] = [
    ("head", SIMD3(0, 1.630, 0.005)), ("neck_1_joint", SIMD3(0, 1.490, 0)),
    ("spine_7_joint", SIMD3(0, 1.340, -0.025)), ("root", SIMD3(0, 0.950, 0)),
    ("leftShoulder", SIMD3(0.070, 1.470, 0)), ("rightShoulder", SIMD3(-0.070, 1.470, 0)),
    ("left_arm_joint", SIMD3(0.200, 1.435, 0)), ("right_arm_joint", SIMD3(-0.200, 1.435, 0)),
    ("left_forearm_joint", SIMD3(0.260, 1.125, 0)), ("right_forearm_joint", SIMD3(-0.260, 1.125, 0)),
    ("leftHand", SIMD3(0.290, 0.870, 0)), ("rightHand", SIMD3(-0.290, 0.870, 0)),
    ("left_upLeg_joint", SIMD3(0.100, 0.920, 0)), ("right_upLeg_joint", SIMD3(-0.100, 0.920, 0)),
    ("left_leg_joint", SIMD3(0.100, 0.490, 0)), ("right_leg_joint", SIMD3(-0.100, 0.490, 0)),
    ("leftFoot", SIMD3(0.100, 0.085, 0)), ("rightFoot", SIMD3(-0.100, 0.085, 0)),
  ]
  return TargetingSkeleton(joints: coordinates.map {
    let p = replacing[$0.0] ?? $0.1
    return TargetingSkeletonJoint(name: $0.0, position: TargetingVector3(x: p.x, y: p.y, z: p.z))
  }, bones: [], capturedAt: Date())
}
