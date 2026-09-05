import Foundation
import simd

struct RealtimeBodyAssociation: Equatable, Sendable {
  let playerID: String
  let confidence: Double
  let handDistanceMeters: Double
  let marginMeters: Double
  let capturedAt: Date
}

/// Conservative identity heuristic in an already independently aligned frame.
/// Hands and phone positions are observed. Distance/margin/radii are gameplay
/// parameters requiring device validation, never a claim of anatomical accuracy.
enum RealtimeAssociationPolicy {
  static let maximumAge = 0.1
  static let maximumHandDistance = 0.45
  static let minimumMargin = 0.35

  static func associate(skeleton: TargetingSkeleton?, observationConfidence: Double,
                        phonePoses: [CombatWire.PlayerPose], players: [CombatWire.Player],
                        localPlayerID: String, matchTimeMs: Double, now: Date,
                        frameReady: Bool) -> RealtimeBodyAssociation? {
    guard frameReady, let skeleton, fresh(skeleton.capturedAt, at: now),
      observationConfidence.isFinite, observationConfidence >= 0.8, matchTimeMs.isFinite else {return nil}
    let hands = ["leftHand", "rightHand"].compactMap {skeleton.position(of: $0)}.filter(valid)
    guard !hands.isEmpty else {return nil}
    let eligible = Set(players.filter {$0.playerId != localPlayerID && $0.connected && $0.frameReady && $0.health > 0}.map(\.playerId))
    let candidates = phonePoses.compactMap {sample -> (id: String, distance: Double)? in
      let age = matchTimeMs - sample.pose.capturedAtMs
      guard eligible.contains(sample.playerId), sample.pose.tracking == "normal", age.isFinite, age >= 0, age <= 100,
        sample.pose.position.count == 3, sample.pose.position.allSatisfy(\.isFinite) else {return nil}
      let phone = TargetingVector3(x: sample.pose.position[0], y: sample.pose.position[1], z: sample.pose.position[2])
      guard let nearest = hands.map({distance($0, phone)}).min() else {return nil}
      return (sample.playerId, nearest)
    }.sorted {$0.distance == $1.distance ? $0.id < $1.id : $0.distance < $1.distance}
    guard let first = candidates.first, first.distance <= maximumHandDistance else {return nil}
    let margin = candidates.dropFirst().first.map {$0.distance - first.distance} ?? 1
    guard margin >= minimumMargin else {return nil}
    let confidence = min(observationConfidence, 1 - 0.15 * first.distance / maximumHandDistance)
    guard confidence >= 0.8 else {return nil}
    return RealtimeBodyAssociation(playerID: first.id, confidence: confidence, handDistanceMeters: first.distance,
      marginMeters: margin, capturedAt: skeleton.capturedAt)
  }

  static func colliders(_ skeleton: TargetingSkeleton) -> [CombatWire.Collider] {
    var result: [CombatWire.Collider] = []
    if let head = skeleton.position(of: "head"), valid(head) {
      result.append(.init(id: "head", kind: "sphere", zone: .head, center: values(head), a: nil, b: nil, radius: 0.12))
    }
    let pairs: [(String, String, String, HitZone, Double)] = [
      ("torso", "root", "neck_1_joint", .torso, 0.18),
      ("left-upper-arm", "left_arm_joint", "left_forearm_joint", .limbs, 0.065),
      ("left-forearm", "left_forearm_joint", "leftHand", .limbs, 0.055),
      ("right-upper-arm", "right_arm_joint", "right_forearm_joint", .limbs, 0.065),
      ("right-forearm", "right_forearm_joint", "rightHand", .limbs, 0.055),
      ("left-thigh", "left_upLeg_joint", "left_leg_joint", .limbs, 0.09),
      ("left-shin", "left_leg_joint", "leftFoot", .limbs, 0.07),
      ("right-thigh", "right_upLeg_joint", "right_leg_joint", .limbs, 0.09),
      ("right-shin", "right_leg_joint", "rightFoot", .limbs, 0.07),
    ]
    for (id, from, to, zone, radius) in pairs {
      guard let a = skeleton.position(of: from), let b = skeleton.position(of: to), valid(a), valid(b),
        distance(a, b) >= 0.02, distance(a, b) <= 3 else {continue}
      result.append(.init(id: id, kind: "capsule", zone: zone, center: nil, a: values(a), b: values(b), radius: radius))
    }
    return result
  }

  static func hitSkeleton(targetPlayerID: String?, association: RealtimeBodyAssociation?, skeleton: TargetingSkeleton?, now: Date) -> TargetingSkeleton? {
    guard let targetPlayerID, let association, association.playerID == targetPlayerID,
      fresh(association.capturedAt, at: now), let skeleton, fresh(skeleton.capturedAt, at: now) else {return nil}
    return skeleton
  }

  static func fresh(_ capturedAt: Date, at now: Date) -> Bool {
    let age = now.timeIntervalSince(capturedAt)
    return age.isFinite && age >= 0 && age <= maximumAge
  }
  private static func values(_ p: TargetingVector3) -> [Double] {[p.x, p.y, p.z]}
  private static func valid(_ p: TargetingVector3) -> Bool {[p.x, p.y, p.z].allSatisfy {$0.isFinite && abs($0) <= 1000}}
  private static func distance(_ a: TargetingVector3, _ b: TargetingVector3) -> Double {
    let delta = a - b; return sqrt(delta.dot(delta))
  }
}

enum RealtimePoseBuilder {
  static func pose(_ sample: DuelFramePose, sequence: Int, matchTimeMs: Double, now: Date) -> CombatWire.Pose? {
    guard sample.isValid, RealtimeAssociationPolicy.fresh(sample.capturedAt, at: now), matchTimeMs.isFinite else {return nil}
    let m = sample.columnMajor
    let rotation = simd_double3x3(columns: (SIMD3(m[0], m[1], m[2]), SIMD3(m[4], m[5], m[6]), SIMD3(m[8], m[9], m[10])))
    let q = simd_normalize(simd_quatd(rotation)).vector
    let captured = matchTimeMs - now.timeIntervalSince(sample.capturedAt) * 1000
    guard captured >= 0, [q.x, q.y, q.z, q.w].allSatisfy(\.isFinite) else {return nil}
    return .init(sequence: sequence, capturedAtMs: captured, position: [m[12], m[13], m[14]], orientation: [q.x, q.y, q.z, q.w], tracking: "normal")
  }
}
