import Foundation

enum BodyTargetingGeometry {
  static func observation(
    joints: [String: TargetingVector3],
    isTracked: Bool,
    ray: TargetingCameraRay,
    project: (TargetingVector3) -> NormalizedTargetingPoint?,
    capturedAt: Date
  ) -> TargetingObservation? {
    guard let root = joints["root"] else { return nil }
    let neck = joints["neck_1_joint"]
    let head = joints["head"] ?? neck.map {
      TargetingVector3(x: $0.x, y: $0.y + 0.15, z: $0.z)
    }
    let projectedHead = head.flatMap(project)
    let projectedRoot = project(root)
    let projectedNeck = neck.flatMap(project)
    let projectedBody = [projectedHead, projectedRoot].compactMap { $0 }
    let bodyBounds = rectangle(from: projectedBody, padding: 0.15)

    let headRegion: NormalizedTargetingEllipse?
    if let head, let center = projectedHead {
      let horizontal = project(head + TargetingVector3(x: 0.12, y: 0, z: 0))
      let vertical = project(head + TargetingVector3(x: 0, y: 0.12, z: 0))
      let radiusX = horizontal.map { abs($0.x - center.x) } ?? 0
      let radiusY = vertical.map { abs($0.y - center.y) } ?? 0
      headRegion = NormalizedTargetingEllipse(
        centerX: center.x,
        centerY: center.y,
        radiusX: radiusX,
        radiusY: radiusY
      )
    } else {
      headRegion = nil
    }

    let torsoProjection = torsoPoints(root: root, neck: neck, project: project)
    let torsoBounds = neck.map { _ in rectangle(from: torsoProjection, padding: 0) }
    let torsoRegion = torsoBounds.map { bounds in
      NormalizedTargetingPolygon(points: [
        NormalizedTargetingPoint(
          x: bounds.minX,
          y: bounds.minY,
          confidence: torsoProjection.map(\.confidence).min() ?? 0
        ),
        NormalizedTargetingPoint(
          x: bounds.minX + bounds.width,
          y: bounds.minY,
          confidence: torsoProjection.map(\.confidence).min() ?? 0
        ),
        NormalizedTargetingPoint(
          x: bounds.minX + bounds.width,
          y: bounds.minY + bounds.height,
          confidence: torsoProjection.map(\.confidence).min() ?? 0
        ),
        NormalizedTargetingPoint(
          x: bounds.minX,
          y: bounds.minY + bounds.height,
          confidence: torsoProjection.map(\.confidence).min() ?? 0
        ),
      ])
    }

    let boneNames = [
      ("head", "neck_1_joint"), ("neck_1_joint", "spine_7_joint"),
      ("spine_7_joint", "root"), ("neck_1_joint", "leftShoulder"),
      ("leftShoulder", "left_arm_joint"), ("left_arm_joint", "left_forearm_joint"),
      ("left_forearm_joint", "leftHand"), ("neck_1_joint", "rightShoulder"),
      ("rightShoulder", "right_arm_joint"), ("right_arm_joint", "right_forearm_joint"),
      ("right_forearm_joint", "rightHand"), ("root", "left_upLeg_joint"),
      ("left_upLeg_joint", "left_leg_joint"), ("left_leg_joint", "leftFoot"),
      ("root", "right_upLeg_joint"), ("right_upLeg_joint", "right_leg_joint"),
      ("right_leg_joint", "rightFoot"),
    ]
    let skeleton = TargetingSkeleton(
      joints: joints.map { TargetingSkeletonJoint(name: $0.key, position: $0.value) }
        .sorted { $0.name < $1.name },
      bones: boneNames.map { TargetingSkeletonBone(from: $0.0, to: $0.1) },
      capturedAt: capturedAt
    )

    return TargetingObservation(
      capturedAt: capturedAt,
      bodyConfidence: isTracked ? 0.9 : 0.5,
      headConfidence: joints["head"].map { _ in 0.9 },
      torsoConfidence: 0.9,
      bodyBounds: bodyBounds,
      torsoBounds: torsoBounds,
      headRegion: headRegion,
      torsoRegion: torsoRegion,
      aimZone3D: aimZone(joints: joints, ray: ray),
      skeleton: skeleton
    )
  }

  static func aimZone(
    joints: [String: TargetingVector3],
    ray: TargetingCameraRay
  ) -> TargetingHitZone? {
    guard let root = joints["root"] else { return nil }
    let neck = joints["neck_1_joint"]
    let head = joints["head"] ?? neck.map {
      TargetingVector3(x: $0.x, y: $0.y + 0.15, z: $0.z)
    }
    if let head, rayIntersectsSphere(ray, center: head, radius: 0.12) {
      return .head
    }
    if let neck, rayIntersectsCapsule(ray, start: root, end: neck, radius: 0.18) {
      return .torso
    }
    return nil
  }

  static func rayIntersectsSphere(
    _ ray: TargetingCameraRay,
    center: TargetingVector3,
    radius: Double
  ) -> Bool {
    let offset = ray.origin - center
    let a = ray.direction.dot(ray.direction)
    guard a > .ulpOfOne else { return false }
    let b = 2 * offset.dot(ray.direction)
    let c = offset.dot(offset) - radius * radius
    let discriminant = b * b - 4 * a * c
    guard discriminant >= 0 else { return false }
    let root = sqrt(discriminant)
    let near = (-b - root) / (2 * a)
    let far = (-b + root) / (2 * a)
    return max(near, far) >= 0
  }

  static func rayIntersectsCapsule(
    _ ray: TargetingCameraRay,
    start: TargetingVector3,
    end: TargetingVector3,
    radius: Double
  ) -> Bool {
    let segment = end - start
    let lengthSquared = segment.dot(segment)
    guard lengthSquared > .ulpOfOne else {
      return rayIntersectsSphere(ray, center: start, radius: radius)
    }
    let directionSegment = ray.direction.dot(segment)
    let originSegment = (ray.origin - start).dot(segment)
    let directionOrigin = ray.direction.dot(ray.origin - start)
    let denominator = lengthSquared - directionSegment * directionSegment
    let rayDistance: Double
    let segmentFraction: Double
    if abs(denominator) < .ulpOfOne {
      rayDistance = max(0, -directionOrigin)
      segmentFraction = min(1, max(0, originSegment / lengthSquared))
    } else {
      let rawRayDistance =
        (directionSegment * originSegment - directionOrigin * lengthSquared) / denominator
      rayDistance = max(0, rawRayDistance)
      let rawFraction =
        (originSegment - directionSegment * directionOrigin) / denominator
      segmentFraction = min(1, max(0, rawFraction))
    }
    let rayPoint = ray.origin + ray.direction * rayDistance
    let segmentPoint = start + segment * segmentFraction
    let delta = rayPoint - segmentPoint
    return delta.dot(delta) <= radius * radius
  }

  private static func torsoPoints(
    root: TargetingVector3,
    neck: TargetingVector3?,
    project: (TargetingVector3) -> NormalizedTargetingPoint?
  ) -> [NormalizedTargetingPoint] {
    guard let neck else { return [] }
    let offsets = [
      TargetingVector3(x: -0.18, y: -0.18, z: 0),
      TargetingVector3(x: 0.18, y: -0.18, z: 0),
      TargetingVector3(x: -0.18, y: 0.18, z: 0),
      TargetingVector3(x: 0.18, y: 0.18, z: 0),
    ]
    return ([root, neck] + offsets.flatMap { [root + $0, neck + $0] })
      .compactMap(project)
  }

  private static func rectangle(
    from points: [NormalizedTargetingPoint],
    padding: Double
  ) -> NormalizedTargetingRect {
    guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
    else {
      return NormalizedTargetingRect(minX: 0, minY: 0, width: 1, height: 1)
    }
    let lowerX = max(0, minX - padding)
    let lowerY = max(0, minY - padding)
    let upperX = min(1, maxX + padding)
    let upperY = min(1, maxY + padding)
    return NormalizedTargetingRect(
      minX: lowerX,
      minY: lowerY,
      width: max(0, upperX - lowerX),
      height: max(0, upperY - lowerY)
    )
  }
}
