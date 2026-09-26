import Foundation

/// Closed-form pairwise inter-frame solve (ADR 0012 §3). Bidirectional
/// distance+direction plus each device's own camera pose yields two point
/// correspondences between the two world frames; under `.gravity` alignment
/// that fixes yaw and translation without any shared map.
enum NearbyPairwiseSolver {
  /// Samples from the two sides must be taken within this skew to be paired.
  static let maximumPairSkew: TimeInterval = 0.5
  /// The two phones range the same link; readings that disagree by more than
  /// this are not the same instant (or one side is reflecting) and are skipped.
  static let maximumDistanceDisagreementMeters: Double = 0.6
  /// Below this horizontal separation the bearing is too noisy to fix yaw.
  static let minimumHorizontalSeparationMeters: Double = 0.4

  struct Solution: Equatable, Sendable {
    /// Maps `remote` frame coordinates into `local` frame coordinates.
    let localFromRemote: NearbyFrameTransform
    let residual: NearbyAlignmentResidual
    let candidateCount: Int
  }

  enum Outcome: Equatable, Sendable {
    case solved(Solution)
    /// One or both sides have no direction-bearing sample yet.
    case needsDirection(localHas: Bool, remoteHas: Bool)
    /// Direction exists on both sides but no sample pair lines up in time
    /// or geometry.
    case insufficientPairs
  }

  /// `local` are this device's readings toward the peer; `remote` are the
  /// peer's readings toward this device (relayed). Each side's `cameraPose`
  /// is in its own world frame.
  static func solve(local: [NearbyRangingSample], remote: [NearbyRangingSample]) -> Outcome {
    let localDirected = local.filter { $0.isValid && $0.hasDirection }
    let remoteDirected = remote.filter { $0.isValid && $0.hasDirection }
    guard !localDirected.isEmpty, !remoteDirected.isEmpty else {
      return .needsDirection(localHas: !localDirected.isEmpty, remoteHas: !remoteDirected.isEmpty)
    }
    var candidates: [NearbyFrameTransform] = []
    for a in localDirected {
      guard let peerInLocal = a.peerPositionInLocalFrame else { continue }
      for b in remoteDirected {
        guard abs(a.observedAt.timeIntervalSince(b.observedAt)) <= maximumPairSkew,
          abs(a.distanceMeters - b.distanceMeters) <= maximumDistanceDisagreementMeters,
          let localInRemote = b.peerPositionInLocalFrame
        else { continue }
        if let candidate = closedForm(localPose: a.cameraPose.translation, peerInLocal: peerInLocal,
          remotePose: b.cameraPose.translation, localInRemote: localInRemote) {
          candidates.append(candidate)
        }
      }
    }
    guard let consensus = NearbyConsensus.median(of: candidates) else { return .insufficientPairs }
    return .solved(Solution(localFromRemote: consensus.transform, residual: consensus.residual,
      candidateCount: candidates.count))
  }

  /// Two correspondences: the remote's own position ↔ where we see it, and
  /// where it sees us ↔ our own position. Yaw comes from the horizontal
  /// bearing between the two devices expressed in both frames; translation
  /// from both correspondences averaged.
  static func closedForm(localPose: NearbyVector3, peerInLocal: NearbyVector3,
    remotePose: NearbyVector3, localInRemote: NearbyVector3
  ) -> NearbyFrameTransform? {
    let bearingLocal = localPose - peerInLocal
    let bearingRemote = localInRemote - remotePose
    guard bearingLocal.horizontalLength >= minimumHorizontalSeparationMeters,
      bearingRemote.horizontalLength >= minimumHorizontalSeparationMeters
    else { return nil }
    let yaw = horizontalAngle(bearingLocal) - horizontalAngle(bearingRemote)
    let rotation = NearbyFrameTransform(yawRadians: yaw, translation: .zero)
    let fromOurPosition = localPose - rotation.rotate(localInRemote)
    let fromPeerPosition = peerInLocal - rotation.rotate(remotePose)
    let translation = (fromOurPosition + fromPeerPosition) * 0.5
    let transform = NearbyFrameTransform(yawRadians: yaw, translation: translation)
    return transform.isFinite ? transform : nil
  }

  /// Angle in the horizontal plane consistent with `NearbyFrameTransform.rotate`:
  /// rotating (1,0,0) by θ lands at angle θ.
  static func horizontalAngle(_ v: NearbyVector3) -> Double { atan2(-v.z, v.x) }
}

/// Robust aggregation shared by the pairwise and graph solvers: the circular
/// median yaw and the component-wise median translation, with residuals as
/// median absolute deviations.
enum NearbyConsensus {
  struct Result: Equatable, Sendable {
    let transform: NearbyFrameTransform
    let residual: NearbyAlignmentResidual
  }

  static func median(of candidates: [NearbyFrameTransform]) -> Result? {
    let finite = candidates.filter(\.isFinite)
    guard !finite.isEmpty else { return nil }
    // Circular median: the candidate yaw minimizing total angular deviation.
    var bestYaw = finite[0].yawRadians, bestCost = Double.infinity
    for candidate in finite {
      let cost = finite.reduce(0.0) { $0 + abs(NearbyFrameTransform.wrap($1.yawRadians - candidate.yawRadians)) }
      if cost < bestCost { bestCost = cost; bestYaw = candidate.yawRadians }
    }
    let translation = NearbyVector3(
      x: scalarMedian(finite.map(\.translation.x)),
      y: scalarMedian(finite.map(\.translation.y)),
      z: scalarMedian(finite.map(\.translation.z)))
    let transform = NearbyFrameTransform(yawRadians: bestYaw, translation: translation)
    let yawDeviation = scalarMedian(finite.map { $0.yawDifference(to: transform) })
    let translationDeviation = scalarMedian(finite.map { $0.translationDifference(to: transform) })
    return Result(transform: transform, residual: NearbyAlignmentResidual(
      translationMeters: translationDeviation, yawDegrees: yawDeviation * 180 / .pi))
  }

  static func scalarMedian(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .nan }
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
  }
}

/// Cross-checks pairwise links across the whole squad (up to 6 links at four
/// players) and elects, per peer, the transform to the host frame that the
/// largest consistent subset of direct and two-hop paths agrees on.
struct NearbyFrameGraph: Equatable, Sendable {
  static let yawToleranceRadians = 5.0 * .pi / 180
  static let translationToleranceMeters = 0.35

  struct Link: Hashable, Sendable {
    let from: String
    let to: String
  }

  /// `links[Link(from: b, to: a)]` maps frame `b` into frame `a`.
  private(set) var links: [Link: NearbyFrameTransform] = [:]

  mutating func setLink(from source: String, to target: String, transform: NearbyFrameTransform) {
    guard source != target, transform.isFinite else { return }
    links[Link(from: source, to: target)] = transform
    links[Link(from: target, to: source)] = transform.inverse
  }

  mutating func removeLinks(involving peerID: String) {
    links = links.filter { $0.key.from != peerID && $0.key.to != peerID }
  }

  func transform(from source: String, to target: String) -> NearbyFrameTransform? {
    source == target ? .identity : links[Link(from: source, to: target)]
  }

  enum PeerOutcome: Equatable, Sendable {
    case solved(NearbyPeerAlignment)
    case unreachable
    case inconsistent
  }

  /// Every candidate path of length ≤ 2 from `peerID`'s frame to the host
  /// frame. The consensus is the candidate with the most agreeing candidates
  /// (itself included); ties break toward the direct link.
  func alignment(of peerID: String, toHost hostID: String, participants: [String]) -> PeerOutcome {
    guard peerID != hostID else {
      return .solved(NearbyPeerAlignment(peerID: peerID, toHostFrame: .identity,
        residual: NearbyAlignmentResidual(translationMeters: 0, yawDegrees: 0), agreeingLinks: 0))
    }
    var candidates: [NearbyFrameTransform] = []
    if let direct = transform(from: peerID, to: hostID) { candidates.append(direct) }
    for via in participants where via != peerID && via != hostID {
      guard let first = transform(from: peerID, to: via), let second = transform(from: via, to: hostID)
      else { continue }
      candidates.append(second.composed(with: first))
    }
    guard !candidates.isEmpty else { return .unreachable }
    var bestSupport: [NearbyFrameTransform] = []
    for candidate in candidates {
      let support = candidates.filter {
        $0.yawDifference(to: candidate) <= Self.yawToleranceRadians
          && $0.translationDifference(to: candidate) <= Self.translationToleranceMeters
      }
      if support.count > bestSupport.count { bestSupport = support }
    }
    // Two or more disagreeing paths with no majority is a real conflict; a
    // single path stands on its own.
    if candidates.count >= 2, bestSupport.count * 2 <= candidates.count {
      return .inconsistent
    }
    guard let consensus = NearbyConsensus.median(of: bestSupport) else { return .inconsistent }
    return .solved(NearbyPeerAlignment(peerID: peerID, toHostFrame: consensus.transform,
      residual: consensus.residual, agreeingLinks: bestSupport.count))
  }
}

/// U2 hedge (b), ADR 0012 §5: when no side of a link reports direction, a
/// few steps during rendezvous give ≥6 ranges at distinct poses and the
/// 4-DOF transform falls out of a least-squares fit on range residuals.
enum NearbyDistanceOnlySolver {
  static let minimumRanges = 6
  /// Ranges taken from nearly the same spot are one equation, not several.
  static let minimumHorizontalSpreadMeters: Double = 0.5
  static let maximumPairSkew: TimeInterval = 0.5
  static let iterations = 40
  static let yawSeeds = 16

  struct Range: Equatable, Sendable {
    let localPosition: NearbyVector3
    let remotePosition: NearbyVector3
    let distanceMeters: Double
  }

  struct Solution: Equatable, Sendable {
    let localFromRemote: NearbyFrameTransform
    let rmsResidualMeters: Double
    let rangeCount: Int
  }

  enum Outcome: Equatable, Sendable {
    case solved(Solution)
    case insufficientRanges(count: Int)
    case insufficientMotion
  }

  /// Pairs each local distance reading with the peer's own pose at the same
  /// instant (from its relayed samples toward us).
  static func ranges(local: [NearbyRangingSample], remote: [NearbyRangingSample]) -> [Range] {
    let remoteSorted = remote.filter(\.isValid).sorted { $0.observedAt < $1.observedAt }
    guard !remoteSorted.isEmpty else { return [] }
    return local.filter(\.isValid).compactMap { sample in
      var nearest = remoteSorted[0]
      var skew = abs(sample.observedAt.timeIntervalSince(nearest.observedAt))
      for candidate in remoteSorted {
        let delta = abs(sample.observedAt.timeIntervalSince(candidate.observedAt))
        if delta < skew { skew = delta; nearest = candidate }
      }
      guard skew <= maximumPairSkew else { return nil }
      let distance = (sample.distanceMeters + nearest.distanceMeters) / 2
      return Range(localPosition: sample.cameraPose.translation,
        remotePosition: nearest.cameraPose.translation, distanceMeters: distance)
    }
  }

  static func solve(_ ranges: [Range]) -> Outcome {
    guard ranges.count >= minimumRanges else { return .insufficientRanges(count: ranges.count) }
    // With only distances, a stationary remote leaves yaw unobservable: the
    // local motion alone produces a single circle of fits. Both sides must
    // have spread before the transform is trustworthy.
    guard horizontalSpread(ranges.map(\.localPosition)) >= minimumHorizontalSpreadMeters,
      horizontalSpread(ranges.map(\.remotePosition)) >= minimumHorizontalSpreadMeters
    else { return .insufficientMotion }
    let localMean = mean(ranges.map(\.localPosition)), remoteMean = mean(ranges.map(\.remotePosition))
    var best: (transform: NearbyFrameTransform, rms: Double)?
    for seed in 0..<yawSeeds {
      let yaw = Double(seed) / Double(yawSeeds) * 2 * .pi
      let rotation = NearbyFrameTransform(yawRadians: yaw, translation: .zero)
      var params = [yaw, 0, 0, 0]
      let t0 = localMean - rotation.rotate(remoteMean)
      params[1] = t0.x; params[2] = t0.y; params[3] = t0.z
      guard let refined = gaussNewton(ranges, initial: params) else { continue }
      if best.map({ refined.rms < $0.rms }) ?? true { best = refined }
    }
    guard let best, best.transform.isFinite, best.rms.isFinite else { return .insufficientMotion }
    return .solved(Solution(localFromRemote: best.transform, rmsResidualMeters: best.rms,
      rangeCount: ranges.count))
  }

  private static func gaussNewton(_ ranges: [Range], initial: [Double])
    -> (transform: NearbyFrameTransform, rms: Double)?
  {
    var p = initial
    var damping = 1e-3
    var lastCost = cost(ranges, p)
    for _ in 0..<iterations {
      // Normal equations J^T J δ = -J^T r for the 4 parameters (θ, tx, ty, tz).
      var jtj = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
      var jtr = [Double](repeating: 0, count: 4)
      let c = cos(p[0]), s = sin(p[0])
      for range in ranges {
        let b = range.remotePosition
        let q = NearbyVector3(x: c * b.x + s * b.z + p[1], y: b.y + p[2], z: -s * b.x + c * b.z + p[3])
        let e = range.localPosition - q
        let n = e.length
        guard n > 1e-6 else { continue }
        let unit = e * (1 / n)
        let dRdTheta = NearbyVector3(x: -s * b.x + c * b.z, y: 0, z: -c * b.x - s * b.z)
        let residual = n - range.distanceMeters
        let jacobian = [
          -(unit.x * dRdTheta.x + unit.y * dRdTheta.y + unit.z * dRdTheta.z),
          -unit.x, -unit.y, -unit.z,
        ]
        for i in 0..<4 {
          jtr[i] += jacobian[i] * residual
          for j in 0..<4 { jtj[i][j] += jacobian[i] * jacobian[j] }
        }
      }
      for i in 0..<4 { jtj[i][i] += damping * max(jtj[i][i], 1e-9) }
      guard let delta = solveLinear(jtj, jtr.map { -$0 }) else { return nil }
      let candidate = zip(p, delta).map(+)
      let candidateCost = cost(ranges, candidate)
      if candidateCost < lastCost {
        p = candidate
        lastCost = candidateCost
        damping = max(damping / 3, 1e-9)
        if delta.allSatisfy({ abs($0) < 1e-7 }) { break }
      } else {
        damping *= 4
        if damping > 1e6 { break }
      }
    }
    let transform = NearbyFrameTransform(yawRadians: p[0],
      translation: NearbyVector3(x: p[1], y: p[2], z: p[3]))
    return (transform, (lastCost / Double(ranges.count)).squareRoot())
  }

  private static func cost(_ ranges: [Range], _ p: [Double]) -> Double {
    let transform = NearbyFrameTransform(yawRadians: p[0],
      translation: NearbyVector3(x: p[1], y: p[2], z: p[3]))
    return ranges.reduce(0.0) {
      let predicted = $1.localPosition.distance(to: transform.apply($1.remotePosition))
      let r = predicted - $1.distanceMeters
      return $0 + r * r
    }
  }

  /// Gaussian elimination with partial pivoting for the 4x4 normal system.
  private static func solveLinear(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
    let n = rhs.count
    var a = matrix, b = rhs
    for col in 0..<n {
      var pivot = col
      for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
      guard abs(a[pivot][col]) > 1e-12 else { return nil }
      if pivot != col { a.swapAt(pivot, col); b.swapAt(pivot, col) }
      for row in (col + 1)..<n {
        let factor = a[row][col] / a[col][col]
        guard factor != 0 else { continue }
        for k in col..<n { a[row][k] -= factor * a[col][k] }
        b[row] -= factor * b[col]
      }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
      var sum = b[row]
      for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
      x[row] = sum / a[row][row]
    }
    return x.allSatisfy(\.isFinite) ? x : nil
  }

  static func horizontalSpread(_ points: [NearbyVector3]) -> Double {
    var spread = 0.0
    for (i, a) in points.enumerated() {
      for b in points[(i + 1)...] {
        spread = max(spread, (a - b).horizontalLength)
      }
    }
    return spread
  }

  private static func mean(_ points: [NearbyVector3]) -> NearbyVector3 {
    guard !points.isEmpty else { return .zero }
    return points.reduce(NearbyVector3.zero, +) * (1 / Double(points.count))
  }
}
