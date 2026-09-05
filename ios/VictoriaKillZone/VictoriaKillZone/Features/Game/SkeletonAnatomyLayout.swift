import Foundation

enum SkeletonAnatomyPart: String, CaseIterable, Sendable {
  case skull, cervicalSpine, ribcage, spine, pelvis
  case leftClavicle, rightClavicle, leftUpperArm, rightUpperArm
  case leftForearm, rightForearm, leftThigh, rightThigh, leftShin, rightShin
  case leftHand, rightHand, leftFoot, rightFoot
}

struct SkeletonAnatomyPlacement: Equatable, Sendable {
  let part: SkeletonAnatomyPart
  let position: SIMD3<Double>
  let right: SIMD3<Double>
  let up: SIMD3<Double>
  let back: SIMD3<Double>
  let size: SIMD3<Double>
}

/// Presentation retargeting only. Every rigid part requires observed landmarks;
/// no inferred joint, collider, or hit volume is created. Hands and feet use a
/// neutral anatomical template oriented from the observed proximal segment;
/// their finger/toe articulation is cosmetic, not tracking evidence.
enum SkeletonAnatomyLayout {
  static func placements(for skeleton: TargetingSkeleton) -> [SkeletonAnatomyPlacement] {
    var points: [String: SIMD3<Double>] = [:]
    for joint in skeleton.joints.prefix(32) where points[joint.name] == nil {
      let point = SIMD3<Double>(joint.position.x, joint.position.y, joint.position.z)
      if finite(point) { points[joint.name] = point }
    }
    var result: [SkeletonAnatomyPlacement] = []
    var torsoRight: SIMD3<Double>?
    if let root = points["root"], let neck = points["neck_1_joint"],
      let left = points["leftShoulder"], let right = points["rightShoulder"],
      let basis = axes(up: neck - root, across: right - left)
    {
      let height = length(neck - root)
      let width = length(right - left)
      if (0.20...1.2).contains(height), (0.12...0.85).contains(width) {
        torsoRight = basis.right
        result.append(placement(.ribcage, at: root + basis.up * height * 0.65, axes: basis,
          size: SIMD3<Double>(width * 0.88, height * 0.66, width * 0.78)))
        result.append(placement(.spine, at: (root + neck) / 2 + basis.back * width * 0.12, axes: basis,
          size: SIMD3<Double>(width * 0.15, height, width * 0.16)))
        if let head = points["head"], let headAxes = axes(up: head - neck, across: right - left),
          (0.06...0.40).contains(length(head - neck))
        {
          let skullWidth = min(0.24, max(0.13, width * 0.45))
          result.append(placement(.skull, at: head, axes: headAxes,
            size: SIMD3<Double>(skullWidth, skullWidth * 1.20, skullWidth)))
          result.append(placement(.cervicalSpine, at: (head + neck) / 2, axes: headAxes,
            size: SIMD3<Double>(skullWidth * 0.34, length(head - neck), skullWidth * 0.34)))
        }
      }
    }
    if let root = points["root"], let neck = points["neck_1_joint"],
      let leftHip = points["left_upLeg_joint"], let rightHip = points["right_upLeg_joint"],
      let basis = axes(up: neck - root, across: rightHip - leftHip)
    {
      let width = length(rightHip - leftHip)
      if (0.10...0.55).contains(width) {
        result.append(placement(.pelvis, at: root, axes: basis,
          size: SIMD3<Double>(width * 1.55, width, width * 0.90)))
      }
    }
    let segments: [(SkeletonAnatomyPart, String, String)] = [
      (.leftClavicle, "neck_1_joint", "left_arm_joint"),
      (.rightClavicle, "neck_1_joint", "right_arm_joint"),
      (.leftUpperArm, "left_arm_joint", "left_forearm_joint"),
      (.rightUpperArm, "right_arm_joint", "right_forearm_joint"),
      (.leftForearm, "left_forearm_joint", "leftHand"),
      (.rightForearm, "right_forearm_joint", "rightHand"),
      (.leftThigh, "left_upLeg_joint", "left_leg_joint"),
      (.rightThigh, "right_upLeg_joint", "right_leg_joint"),
      (.leftShin, "left_leg_joint", "leftFoot"),
      (.rightShin, "right_leg_joint", "rightFoot"),
    ]
    for (part, from, to) in segments {
      guard let start = points[from], let end = points[to] else { continue }
      let span = end - start
      let distance = length(span)
      guard (0.025...1.2).contains(distance), let up = unit(span) else { continue }
      let reference = torsoRight ?? (abs(up.x) < 0.85 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1))
      let fallback = abs(up.z) < 0.85 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
      guard let basis = axes(up: span, across: reference) ?? axes(up: span, across: fallback) else { continue }
      let width = min(0.080, max(0.018, distance * 0.16))
      result.append(placement(part, at: (start + end) / 2, axes: basis,
        size: SIMD3<Double>(width, distance, width)))
    }
    for (part, proximal, endpoint) in [
      (SkeletonAnatomyPart.leftHand, "left_forearm_joint", "leftHand"),
      (.rightHand, "right_forearm_joint", "rightHand"),
    ] {
      guard let elbow = points[proximal], let wrist = points[endpoint], let across = torsoRight,
        let basis = axes(up: wrist - elbow, across: across),
        (0.10...0.65).contains(length(wrist - elbow)) else { continue }
      let handLength = min(0.215, max(0.145, length(wrist - elbow) * 0.62))
      result.append(placement(part, at: wrist + basis.up * handLength * 0.5, axes: basis,
        size: SIMD3<Double>(handLength * 0.49, handLength, handLength * 0.25)))
    }
    for (part, proximal, endpoint) in [
      (SkeletonAnatomyPart.leftFoot, "left_leg_joint", "leftFoot"),
      (.rightFoot, "right_leg_joint", "rightFoot"),
    ] {
      guard let knee = points[proximal], let ankle = points[endpoint], let across = torsoRight,
        let basis = axes(up: knee - ankle, across: across),
        (0.15...0.80).contains(length(knee - ankle)) else { continue }
      let footLength = min(0.29, max(0.18, length(knee - ankle) * 0.54))
      result.append(placement(part, at: ankle - basis.up * 0.025 - basis.back * footLength * 0.23, axes: basis,
        size: SIMD3<Double>(footLength * 0.40, footLength * 0.28, footLength)))
    }
    return result
  }

  private typealias Axes = (right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>)

  private static func axes(up: SIMD3<Double>, across: SIMD3<Double>) -> Axes? {
    guard let y = unit(up), let z = unit(cross(across, y)), let x = unit(cross(y, z)) else { return nil }
    return (x, y, z)
  }

  private static func placement(_ part: SkeletonAnatomyPart, at position: SIMD3<Double>,
    axes: Axes, size: SIMD3<Double>) -> SkeletonAnatomyPlacement {
    SkeletonAnatomyPlacement(part: part, position: position, right: axes.right, up: axes.up, back: axes.back, size: size)
  }

  private static func finite(_ value: SIMD3<Double>) -> Bool {
    // SceneKit consumes Float transforms; a finite Double may still overflow.
    Float(value.x).isFinite && Float(value.y).isFinite && Float(value.z).isFinite
  }
  private static func length(_ value: SIMD3<Double>) -> Double { (value * value).sum().squareRoot() }
  private static func unit(_ value: SIMD3<Double>) -> SIMD3<Double>? {
    let magnitude = length(value)
    guard magnitude.isFinite, magnitude > 0.0001 else { return nil }
    return value / magnitude
  }
  private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3<Double>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
  }
}
