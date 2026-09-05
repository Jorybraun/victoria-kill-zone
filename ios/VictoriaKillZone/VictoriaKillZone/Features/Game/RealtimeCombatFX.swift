import Foundation

/// Bounded presentation of accepted combat.v1 state. This never advances the
/// simulation, decides a collision, or changes the authority's flight speed.
struct RealtimeCombatPresentation {
  static let projectileCapacity = 128
  static let playerCapacity = 4
  static let extrapolationMs: Double = 100
  static let staleMs: Double = 250
  static let poseAgeMs: Double = 100

  struct Projectile {
    let id: String
    let origin: SIMD3<Double>
    let direction: SIMD3<Double>
    let segmentStartedAtMs: Double
    let spawnedAtMs: Double
    let expiresAtMs: Double
    let speed: Double
    let timeScale: Double
    let radius: Double
  }
  struct Shield {
    let id: String
    let center: SIMD3<Double>
    let orientation: SIMD4<Double>
    let radius: Double
    let energy: Double
    let expiresAtMs: Double
    let poseCapturedAtMs: Double
  }
  struct Field {
    let id: String
    let center: SIMD3<Double>
    let radius: Double
    let startsAtMs: Double
    let endsAtMs: Double
  }
  struct Timing {
    let matchTimeMs: Double
    let projectileTimeMs: Double
  }
  private(set) var projectiles: [Projectile] = []
  private(set) var shields: [Shield] = []
  private(set) var fields: [Field] = []
  private var matchID: String?
  private var authorityEpoch = -1
  private var frameEpoch = -1
  private var tick = -1
  private var sourceTimeMs: Double = 0
  private var anchorMatchTimeMs: Double?
  private var anchorLocalTime: TimeInterval = 0

  @discardableResult
  mutating func update(_ snapshot: CombatWire.Snapshot, matchTimeMs: Double, localTime: TimeInterval) -> Bool {
    guard matchTimeMs.isFinite, matchTimeMs >= 0, localTime.isFinite, localTime >= 0,
      snapshot.matchTimeMs.isFinite, snapshot.matchTimeMs >= 0,
      snapshot.authorityEpoch >= 0, snapshot.frameEpoch >= 0, snapshot.tick >= 0,
      snapshot.projectiles.count <= Self.projectileCapacity,
      snapshot.players.count <= Self.playerCapacity, snapshot.phonePoses.count <= Self.playerCapacity,
      snapshot.slowFields.count <= Self.playerCapacity
    else { discardVisuals(); return false }
    if snapshot.matchId == matchID {
      guard snapshot.authorityEpoch >= authorityEpoch, snapshot.frameEpoch >= frameEpoch else { return false }
      if snapshot.authorityEpoch == authorityEpoch, snapshot.frameEpoch == frameEpoch {
        guard snapshot.tick >= tick, snapshot.matchTimeMs >= sourceTimeMs else { return false }
      }
    }
    matchID = snapshot.matchId
    authorityEpoch = snapshot.authorityEpoch
    frameEpoch = snapshot.frameEpoch
    tick = snapshot.tick
    sourceTimeMs = snapshot.matchTimeMs
    guard snapshot.phase == .running,
      (-25...Self.staleMs).contains(matchTimeMs - snapshot.matchTimeMs)
    else { discardVisuals(); return false }
    anchorMatchTimeMs = matchTimeMs
    anchorLocalTime = localTime
    var ids = Set<String>()
    projectiles = snapshot.projectiles.compactMap { value in
      guard ids.insert(value.projectileId).inserted,
        let origin = Self.vector(value.segmentOrigin), let direction = Self.vector(value.direction),
        (0.98...1.02).contains((direction * direction).sum()),
        [value.segmentStartedAtMs, value.spawnedAtMs, value.expiresAtMs, value.speed, value.timeScale, value.radius].allSatisfy(\.isFinite),
        value.spawnedAtMs >= 0, value.segmentStartedAtMs >= value.spawnedAtMs,
        value.segmentStartedAtMs <= snapshot.matchTimeMs, value.expiresAtMs > value.segmentStartedAtMs,
        (0.001...10_000).contains(value.speed), (0.001...1).contains(value.timeScale),
        (0.001...1).contains(value.radius)
      else { return nil }
      return Projectile(id: value.projectileId, origin: origin, direction: direction,
        segmentStartedAtMs: value.segmentStartedAtMs, spawnedAtMs: value.spawnedAtMs,
        expiresAtMs: value.expiresAtMs, speed: value.speed, timeScale: value.timeScale, radius: value.radius)
    }
    ids.removeAll(keepingCapacity: true)
    shields = snapshot.players.compactMap { player in
      guard ids.insert(player.playerId).inserted, player.connected, player.frameReady, player.health > 0,
        let until = player.shield.activeUntilMs, until.isFinite, until > matchTimeMs,
        player.shield.energy.isFinite, player.shield.energy > 0,
        let pose = snapshot.phonePoses.first(where: { $0.playerId == player.playerId })?.pose,
        pose.tracking == "normal", pose.capturedAtMs.isFinite,
        let position = Self.vector(pose.position), let orientation = Self.quaternion(pose.orientation),
        snapshot.rules.shield.radius.isFinite, (0.05...2).contains(snapshot.rules.shield.radius),
        snapshot.rules.shield.offsetMeters.isFinite, (0...0.5).contains(snapshot.rules.shield.offsetMeters),
        snapshot.rules.shield.energy.isFinite, snapshot.rules.shield.energy > 0
      else { return nil }
      // Exactly the authority's ARKit -Z phone normal and disc offset.
      let normal = Self.phoneForward(orientation)
      return Shield(id: player.playerId, center: position + normal * snapshot.rules.shield.offsetMeters,
        orientation: orientation, radius: snapshot.rules.shield.radius,
        energy: min(1, player.shield.energy / snapshot.rules.shield.energy), expiresAtMs: until,
        poseCapturedAtMs: pose.capturedAtMs)
    }
    ids.removeAll(keepingCapacity: true)
    fields = snapshot.slowFields.compactMap { value in
      guard ids.insert(value.fieldId).inserted, let center = Self.vector(value.center),
        [value.radius, value.startsAtMs, value.endsAtMs].allSatisfy(\.isFinite),
        (0.05...10).contains(value.radius), value.startsAtMs >= 0, value.endsAtMs > value.startsAtMs
      else { return nil }
      return Field(id: value.fieldId, center: center, radius: value.radius,
        startsAtMs: value.startsAtMs, endsAtMs: value.endsAtMs)
    }
    return true
  }

  func timing(at localTime: TimeInterval) -> Timing? {
    guard let anchorMatchTimeMs, localTime.isFinite else { return nil }
    let elapsedMs = (localTime - anchorLocalTime) * 1000
    let now = anchorMatchTimeMs + elapsedMs
    guard elapsedMs >= 0, elapsedMs <= Self.staleMs,
      now - sourceTimeMs <= Self.staleMs else { return nil }
    // Hold at the last bounded extrapolation point if network updates pause.
    // A frozen projectile cannot keep flying forever after a lost connection.
    return Timing(matchTimeMs: now, projectileTimeMs: min(now, sourceTimeMs + Self.extrapolationMs))
  }

  static func position(_ projectile: Projectile, timing: Timing) -> SIMD3<Double>? {
    guard timing.matchTimeMs >= projectile.spawnedAtMs, timing.matchTimeMs < projectile.expiresAtMs,
      timing.projectileTimeMs >= projectile.segmentStartedAtMs else { return nil }
    let seconds = (timing.projectileTimeMs - projectile.segmentStartedAtMs) / 1000
    let point = projectile.origin + projectile.direction * (projectile.speed * projectile.timeScale * seconds)
    return finite(point) ? point : nil
  }

  static func shieldVisible(_ shield: Shield, timing: Timing) -> Bool {
    let age = timing.matchTimeMs - shield.poseCapturedAtMs
    return age >= 0 && age <= poseAgeMs && timing.matchTimeMs < shield.expiresAtMs
  }

  static func fieldVisible(_ field: Field, timing: Timing) -> Bool {
    timing.matchTimeMs >= field.startsAtMs && timing.matchTimeMs < field.endsAtMs
  }

  mutating func clear() { self = RealtimeCombatPresentation() }

  private mutating func discardVisuals() {
    projectiles.removeAll(keepingCapacity: true)
    shields.removeAll(keepingCapacity: true)
    fields.removeAll(keepingCapacity: true)
    anchorMatchTimeMs = nil
  }
  private static func finite(_ value: SIMD3<Double>) -> Bool {
    Float(value.x).isFinite && Float(value.y).isFinite && Float(value.z).isFinite
  }
  private static func vector(_ values: [Double]) -> SIMD3<Double>? {
    guard values.count == 3 else { return nil }
    let result = SIMD3<Double>(values[0], values[1], values[2])
    return finite(result) ? result : nil
  }
  private static func quaternion(_ values: [Double]) -> SIMD4<Double>? {
    guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
    let result = SIMD4<Double>(values[0], values[1], values[2], values[3])
    let squared = (result * result).sum()
    guard (0.99...1.01).contains(squared) else { return nil }
    return result / squared.squareRoot()
  }
  private static func phoneForward(_ q: SIMD4<Double>) -> SIMD3<Double> {
    SIMD3<Double>(-2 * (q.x * q.z + q.w * q.y), -2 * (q.y * q.z - q.w * q.x),
      -(1 - 2 * (q.x * q.x + q.y * q.y)))
  }
}

#if os(iOS) && canImport(SceneKit)
  import QuartzCore
  import SceneKit
  import UIKit

  /// Display-cadence SceneKit presentation on the existing AR scene. No second
  /// ARSession/delegate and no per-shot geometry or unbounded SCNActions.
  @MainActor
  final class RealtimeCombatFX {
    let root = SCNNode()
    private var state = RealtimeCombatPresentation()
    private var projectiles: [SCNNode] = []
    private var shields: [SCNNode] = []
    private var fields: [SCNNode] = []
    private var displayLink: CADisplayLink?
    private let displayTarget = RealtimeCombatDisplayTarget()

    init() {
      root.name = "accepted-realtime-combat"
      let projectile = SCNCapsule(capRadius: 0.5, height: 2)
      projectile.radialSegmentCount = 8
      projectile.capSegmentCount = 3
      projectile.firstMaterial = Self.material(UIColor(red: 1, green: 0.77, blue: 0.24, alpha: 1))
      for _ in 0..<RealtimeCombatPresentation.projectileCapacity {
        let node = SCNNode(geometry: projectile)
        node.name = "finite-projectile"
        node.isHidden = true
        root.addChildNode(node)
        projectiles.append(node)
      }
      let shieldDisc = SCNCylinder(radius: 1, height: 0.008)
      shieldDisc.radialSegmentCount = 32
      shieldDisc.firstMaterial = Self.material(UIColor(red: 0.16, green: 0.78, blue: 1, alpha: 0.07))
      let shieldRim = SCNTorus(ringRadius: 1, pipeRadius: 0.012)
      shieldRim.ringSegmentCount = 32
      shieldRim.pipeSegmentCount = 4
      shieldRim.firstMaterial = Self.material(UIColor(red: 0.28, green: 0.86, blue: 1, alpha: 0.75))
      let fieldSphere = SCNSphere(radius: 1)
      fieldSphere.segmentCount = 20
      fieldSphere.firstMaterial = Self.material(UIColor(red: 0.22, green: 0.65, blue: 1, alpha: 0.035))
      let fieldRing = SCNTorus(ringRadius: 1, pipeRadius: 0.0025)
      fieldRing.ringSegmentCount = 48
      fieldRing.pipeSegmentCount = 4
      fieldRing.firstMaterial = Self.material(UIColor(red: 0.26, green: 0.68, blue: 1, alpha: 0.30))
      for _ in 0..<RealtimeCombatPresentation.playerCapacity {
        let shield = SCNNode()
        shield.name = "accepted-phone-shield"
        for geometry in [shieldDisc, shieldRim] as [SCNGeometry] {
          let child = SCNNode(geometry: geometry)
          child.eulerAngles.x = .pi / 2
          shield.addChildNode(child)
        }
        shield.isHidden = true
        root.addChildNode(shield)
        shields.append(shield)
        let field = SCNNode(geometry: fieldSphere)
        field.name = "accepted-slow-field"
        for axis in 0..<3 {
          let ring = SCNNode(geometry: fieldRing)
          if axis == 1 { ring.eulerAngles.x = .pi / 2 }
          if axis == 2 { ring.eulerAngles.z = .pi / 2 }
          field.addChildNode(ring)
        }
        field.isHidden = true
        root.addChildNode(field)
        fields.append(field)
      }
      displayTarget.owner = self
    }

    func update(snapshot: CombatWire.Snapshot, matchTimeMs: Double) {
      _ = state.update(snapshot, matchTimeMs: matchTimeMs, localTime: CACurrentMediaTime())
      render(at: CACurrentMediaTime())
      guard !state.projectiles.isEmpty || !state.shields.isEmpty || !state.fields.isEmpty else {
        stopDisplayLink()
        return
      }
      if displayLink == nil {
        let link = CADisplayLink(target: displayTarget, selector: #selector(RealtimeCombatDisplayTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
    }

    func clear() {
      state.clear()
      stopDisplayLink()
      hideAll()
    }

    fileprivate func render(at localTime: TimeInterval) {
      guard let timing = state.timing(at: localTime) else {
        hideAll()
        stopDisplayLink()
        return
      }
      SCNTransaction.begin()
      SCNTransaction.disableActions = true
      for index in projectiles.indices {
        let node = projectiles[index]
        guard index < state.projectiles.count,
          let tip = RealtimeCombatPresentation.position(state.projectiles[index], timing: timing)
        else { node.isHidden = true; continue }
        let value = state.projectiles[index]
        let direction = simd_normalize(SIMD3<Float>(value.direction))
        let travelledThisSegment = max(0, timing.projectileTimeMs - value.segmentStartedAtMs) / 1000 * value.speed * value.timeScale
        let length = Float(min(0.28, max(value.radius * 2, min(travelledThisSegment, value.speed * value.timeScale * 0.035))))
        node.simdPosition = SIMD3<Float>(tip) - direction * length / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        node.simdScale = SIMD3<Float>(Float(value.radius * 2), length / 2, Float(value.radius * 2))
        node.isHidden = false
      }
      for index in shields.indices {
        let node = shields[index]
        guard index < state.shields.count,
          RealtimeCombatPresentation.shieldVisible(state.shields[index], timing: timing)
        else { node.isHidden = true; continue }
        let value = state.shields[index]
        node.simdPosition = SIMD3<Float>(value.center)
        node.simdOrientation = simd_quatf(vector: SIMD4<Float>(value.orientation))
        node.simdScale = SIMD3<Float>(repeating: Float(value.radius))
        node.opacity = CGFloat(0.35 + value.energy * 0.65)
        node.isHidden = false
      }
      for index in fields.indices {
        let node = fields[index]
        guard index < state.fields.count,
          RealtimeCombatPresentation.fieldVisible(state.fields[index], timing: timing)
        else { node.isHidden = true; continue }
        let value = state.fields[index]
        node.simdPosition = SIMD3<Float>(value.center)
        node.simdScale = SIMD3<Float>(repeating: Float(value.radius))
        // Geometry and expiration stay authoritative; only edge opacity pulses.
        node.opacity = CGFloat(0.80 + 0.20 * sin(timing.matchTimeMs / 180))
        node.isHidden = false
      }
      SCNTransaction.commit()
    }

    private func hideAll() {
      for node in projectiles { node.isHidden = true }
      for node in shields { node.isHidden = true }
      for node in fields { node.isHidden = true }
    }
    private func stopDisplayLink() {
      displayLink?.invalidate()
      displayLink = nil
    }
    private static func material(_ color: UIColor) -> SCNMaterial {
      let result = SCNMaterial()
      result.lightingModel = .constant
      result.diffuse.contents = color
      result.emission.contents = color
      result.isDoubleSided = true
      result.writesToDepthBuffer = false
      result.blendMode = .add
      return result
    }
  }

  @MainActor
  private final class RealtimeCombatDisplayTarget: NSObject {
    weak var owner: RealtimeCombatFX?
    @objc func step(_ link: CADisplayLink) {
      guard let owner else { link.invalidate(); return }
      owner.render(at: link.targetTimestamp)
    }
  }
#endif
