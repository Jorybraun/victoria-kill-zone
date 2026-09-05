import Foundation
import simd

/// Independent synthetic art inputs. These are not ARKit/device captures.
enum SkeletonReviewFixtures {
  typealias Points = [String: SIMD3<Double>]

  static let neutral: Points = [
    "head": [0, 1.630, 0.005], "neck_1_joint": [0, 1.490, 0],
    "spine_7_joint": [0, 1.340, -0.025], "root": [0, 0.950, 0],
    "leftShoulder": [0.070, 1.470, 0], "rightShoulder": [-0.070, 1.470, 0],
    "left_arm_joint": [0.200, 1.435, 0], "right_arm_joint": [-0.200, 1.435, 0],
    "left_forearm_joint": [0.260, 1.125, 0], "right_forearm_joint": [-0.260, 1.125, 0],
    "leftHand": [0.290, 0.870, 0], "rightHand": [-0.290, 0.870, 0],
    "left_upLeg_joint": [0.100, 0.920, 0], "right_upLeg_joint": [-0.100, 0.920, 0],
    "left_leg_joint": [0.100, 0.490, 0], "right_leg_joint": [-0.100, 0.490, 0],
    "leftFoot": [0.100, 0.085, 0], "rightFoot": [-0.100, 0.085, 0],
  ]

  static var bentElbows: Points {
    var points = neutral
    for (side, sign) in [("left", 1.0), ("right", -1.0)] {
      points["\(side)Hand"] = [sign * 0.260, 1.125, 0.257]
    }
    return points
  }

  /// Preserve the 0.43 m femur and 0.405 m shin lengths. Hips move down and
  /// posteriorly; knees move anteriorly. The upper body translates with root.
  static var crouch: Points {
    let ankleY = 0.085
    let kneeZ = 0.220
    let kneeY = ankleY + sqrt(0.405 * 0.405 - kneeZ * kneeZ)
    let hipZ = -0.080
    let hipY = kneeY + sqrt(0.430 * 0.430 - pow(kneeZ - hipZ, 2))
    let translation = SIMD3<Double>(0, hipY - 0.920, hipZ)
    var points = neutral.mapValues { $0 + translation }
    for (side, sign) in [("left", 1.0), ("right", -1.0)] {
      points["\(side)_leg_joint"] = [sign * 0.100, kneeY, kneeZ]
      points["\(side)Foot"] = [sign * 0.100, ankleY, 0]
    }
    return points
  }

  static var turned: Points { neutral.mapValues { [$0.z, $0.y, -$0.x] } }

  static var missingWristAnkle: Points {
    var points = neutral
    points.removeValue(forKey: "leftHand")
    points.removeValue(forKey: "rightFoot")
    return points
  }

  static func lateralArm(angle: Double) -> Points {
    var points = neutral
    let shoulder = points["left_arm_joint"]!
    let upperLength = simd_length(neutral["left_forearm_joint"]! - shoulder)
    let lowerLength = simd_length(neutral["leftHand"]! - neutral["left_forearm_joint"]!)
    let direction = SIMD3<Double>(sin(angle), -cos(angle), 0)
    points["left_forearm_joint"] = shoulder + direction * upperLength
    points["leftHand"] = shoulder + direction * (upperLength + lowerLength)
    return points
  }

  static func skeleton(_ points: Points, at time: Date = Date(timeIntervalSince1970: 0)) -> TargetingSkeleton {
    TargetingSkeleton(joints: points.sorted { $0.key < $1.key }.map {
      TargetingSkeletonJoint(name: $0.key, position: .init(x: $0.value.x, y: $0.value.y, z: $0.value.z))
    }, bones: [], capturedAt: time)
  }

  static func serialized(_ points: Points) -> [String: [Double]] {
    points.mapValues { [$0.x, $0.y, $0.z] }
  }

  static func segmentLengths(_ points: Points) -> [String: Double] {
    let names = [
      ("upperArm", "_arm_joint", "_forearm_joint"),
      ("forearm", "_forearm_joint", "Hand"),
      ("thigh", "_upLeg_joint", "_leg_joint"),
      ("shin", "_leg_joint", "Foot"),
    ]
    var result: [String: Double] = [:]
    for side in ["left", "right"] {
      for (label, from, to) in names {
        if let start = points[side + from], let end = points[side + to] {
          result[side + label] = simd_length(end - start)
        }
      }
    }
    return result
  }
}
