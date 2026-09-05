import Foundation

enum SkeletonAnatomyPart: String, CaseIterable, Sendable {
  case skull, cervicalSpine, ribcage, spine, pelvis
  case leftClavicle, rightClavicle, leftUpperArm, rightUpperArm
  case leftForearm, rightForearm, leftThigh, rightThigh, leftShin, rightShin
  case leftHand, rightHand, leftFoot, rightFoot
}

/// A target anatomical bind frame. `size` contains reference lengths, never a
/// desired mesh bounding box: transverse humeral-root width and longitudinal
/// observed joint span. The imported source bind has the identical semantics.
struct SkeletonAnatomyPlacement: Equatable, Sendable {
  let part: SkeletonAnatomyPart
  let position: SIMD3<Double>
  let right: SIMD3<Double> // Subject left, the review world's +X.
  let up: SIMD3<Double> // Distal to proximal for limbs; superior for torso.
  let back: SIMD3<Double> // Anatomical anterior, the review world's +Z.
  let size: SIMD3<Double>
}

/// Rigid presentation retargeting only. Finer hand/foot articulation and limb
/// roll are cosmetic templates. Missing landmarks hide dependent anatomy; no
/// joint, collider, independent head yaw or sensed body width is invented.
enum SkeletonAnatomyLayout {
  static func placements(for skeleton: TargetingSkeleton,
    previous: [SkeletonAnatomyPart: SkeletonAnatomyPlacement] = [:]
  ) -> [SkeletonAnatomyPlacement] {
    var points: [String: SIMD3<Double>] = [:]
    for joint in skeleton.joints.prefix(32) where points[joint.name] == nil {
      let point = SIMD3<Double>(joint.position.x, joint.position.y, joint.position.z)
      if finite(point) { points[joint.name] = point }
    }
    // ARKit medial shoulder pivots are not the humeral roots. Using their small
    // separation makes the ribcage collapse even when the observed arms are wide.
    guard let root = points["root"], let neck = points["neck_1_joint"],
      let leftArm = points["left_arm_joint"], let rightArm = points["right_arm_joint"],
      let torso = axes(up: neck - root, across: leftArm - rightArm)
    else { return [] }
    let height = length(neck - root), width = length(leftArm - rightArm)
    guard (0.20...1.2).contains(height), (0.20...0.85).contains(width) else { return [] }
    var result: [SkeletonAnatomyPlacement] = []
    let torsoSize = SIMD3<Double>(width, height, width)
    for part: SkeletonAnatomyPart in [.ribcage, .spine, .leftClavicle, .rightClavicle] {
      result.append(placement(part, at: root, axes: torso, size: torsoSize))
    }
    if let leftHip = points["left_upLeg_joint"], let rightHip = points["right_upLeg_joint"],
      (0.10...0.55).contains(length(leftHip - rightHip)) {
      // Preserve the pelvis and sacrum's source relationship with the torso.
      result.append(placement(.pelvis, at: root, axes: torso, size: torsoSize))
    }
    if let head = points["head"], (0.06...0.40).contains(length(head - neck)),
      let headAxes = segmentAxes(up: head - neck, torso: torso, previous: previous[.skull]) {
      for part: SkeletonAnatomyPart in [.skull, .cervicalSpine] {
        result.append(placement(part, at: neck, axes: headAxes,
          size: SIMD3<Double>(width, length(head - neck), width)))
      }
    }
    let segments: [(SkeletonAnatomyPart, String, String)] = [
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
      guard let proximal = points[from], let distal = points[to],
        (0.025...1.2).contains(length(proximal - distal)),
        let frame = segmentAxes(up: proximal - distal, torso: torso, previous: previous[part])
      else { continue }
      result.append(placement(part, at: proximal, axes: frame,
        size: SIMD3<Double>(width, length(proximal - distal), width)))
    }
    for (part, proximalName, endpointName, allowedSpan) in [
      (SkeletonAnatomyPart.leftHand, "left_forearm_joint", "leftHand", 0.10...0.65),
      (.rightHand, "right_forearm_joint", "rightHand", 0.10...0.65),
      (.leftFoot, "left_leg_joint", "leftFoot", 0.15...0.80),
      (.rightFoot, "right_leg_joint", "rightFoot", 0.15...0.80),
    ] {
      guard let proximal = points[proximalName], let endpoint = points[endpointName],
        allowedSpan.contains(length(proximal - endpoint)),
        let frame = segmentAxes(up: proximal - endpoint, torso: torso, previous: previous[part])
      else { continue }
      result.append(placement(part, at: endpoint, axes: frame,
        size: SIMD3<Double>(width, length(proximal - endpoint), width)))
    }
    return result
  }

  private typealias Axes = (right: SIMD3<Double>, up: SIMD3<Double>, back: SIMD3<Double>)

  private static func axes(up: SIMD3<Double>, across: SIMD3<Double>) -> Axes? {
    guard let y = unit(up), let z = unit(cross(across, y)), let x = unit(cross(y, z)) else { return nil }
    return (x, y, z)
  }

  /// Transport the torso frame by the shortest rotation taking superior to the
  /// segment's distal→proximal axis. Unlike cross(across, limb), this does not
  /// flip the anterior axis when an arm passes through lateral extension.
  /// At the antipodal singularity, retain the previous cosmetic roll (or the
  /// torso lateral axis on first observation). This never adds sensed rotation.
  private static func segmentAxes(up: SIMD3<Double>, torso: Axes,
    previous: SkeletonAnatomyPlacement?) -> Axes? {
    guard let y = unit(up) else { return nil }
    let cosine = min(1, max(-1, dot(torso.up, y)))
    let x: SIMD3<Double>
    if cosine < -0.98 {
      let reference = previous?.right ?? torso.right
      guard let projected = unit(reference - y * dot(reference, y))
        ?? unit(torso.back - y * dot(torso.back, y)) else { return nil }
      x = projected
    } else {
      let v = cross(torso.up, y)
      x = torso.right + cross(v, torso.right) + cross(v, cross(v, torso.right)) / (1 + cosine)
    }
    return axes(up: y, across: x)
  }

  private static func placement(_ part: SkeletonAnatomyPart, at position: SIMD3<Double>,
    axes: Axes, size: SIMD3<Double>) -> SkeletonAnatomyPlacement {
    SkeletonAnatomyPlacement(part: part, position: position, right: axes.right,
      up: axes.up, back: axes.back, size: size)
  }
  private static func finite(_ value: SIMD3<Double>) -> Bool {
    Float(value.x).isFinite && Float(value.y).isFinite && Float(value.z).isFinite
  }
  private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
  private static func length(_ value: SIMD3<Double>) -> Double { dot(value, value).squareRoot() }
  private static func unit(_ value: SIMD3<Double>) -> SIMD3<Double>? {
    let magnitude = length(value)
    guard magnitude.isFinite, magnitude > 0.0001 else { return nil }
    return value / magnitude
  }
  private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3<Double>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
  }
}
