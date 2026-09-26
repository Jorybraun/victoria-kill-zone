import Foundation
import XCTest

@testable import VictoriaKillZone

/// Synthetic UWB ranging: every device lives in its own gravity-aligned ARKit
/// frame, related to the host frame by a yaw + translation. Samples are
/// generated from true positions, then perturbed, and the solver must recover
/// the inter-frame transforms without a device.
final class NearbyTargetingRendezvousTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)

  // MARK: Geometry

  func testTransformRoundTripsAndComposes() {
    let a = NearbyFrameTransform(yawRadians: 0.7, translation: NearbyVector3(x: 1, y: 0.2, z: -3))
    let b = NearbyFrameTransform(yawRadians: -2.1, translation: NearbyVector3(x: -4, y: 0, z: 0.5))
    let p = NearbyVector3(x: 2, y: 1, z: -1)
    XCTAssertTrue(close(a.inverse.apply(a.apply(p)), p))
    XCTAssertTrue(close(b.composed(with: a).apply(p), b.apply(a.apply(p))))
    XCTAssertEqual(NearbyFrameTransform(yawRadians: 3 * .pi, translation: .zero).yawRadians, .pi, accuracy: 1e-9)
  }

  func testNonRigidPosesAreRejected() {
    // Scaled rotation block.
    XCTAssertNil(NearbyRigidPose(columnMajor: [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1]))
    // Reflected (left-handed) rotation.
    XCTAssertNil(NearbyRigidPose(columnMajor: [-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
    // Non-homogeneous last row.
    XCTAssertNil(NearbyRigidPose(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0]))
    // A relayed ranging envelope carrying a scaled pose fails to decode.
    let json = """
      {"v":1,"kind":"ranging","epoch":7,"samples":[{"peerID":"p","distance":2,
      "pose":[2,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1],"observedAt":1000.0}]}
      """
    XCTAssertThrowsError(try NearbyRelayEnvelope.decode(Data(json.utf8))) {
      XCTAssertEqual($0 as? NearbyTargetingFailure, .invalidSample)
    }
  }

  func testRigidPoseTransformsPointsWithRotationAndTranslation() throws {
    let pose = try XCTUnwrap(Self.pose(position: NearbyVector3(x: 1, y: 1.5, z: 2), yaw: .pi / 2))
    // Camera-frame +X rotated by +90° about Y lands on world -Z.
    let world = pose.transform(NearbyVector3(x: 1, y: 0, z: 0))
    XCTAssertTrue(close(world, NearbyVector3(x: 1, y: 1.5, z: 1)))
    XCTAssertTrue(close(pose.transform(.zero), NearbyVector3(x: 1, y: 1.5, z: 2)))
  }

  // MARK: Pairwise solve

  func testClosedFormPairwiseRecoversFourDOFTransform() throws {
    let truth = NearbyFrameTransform(yawRadians: 1.1, translation: NearbyVector3(x: 3, y: 0.1, z: -2))
    let world = Self.twoDeviceWorld(remoteToLocal: truth)
    let outcome = NearbyPairwiseSolver.solve(local: world.local, remote: world.remote)
    guard case .solved(let solution) = outcome else { return XCTFail("expected solve, got \(outcome)") }
    XCTAssertEqual(solution.localFromRemote.yawRadians, truth.yawRadians, accuracy: 0.03)
    XCTAssertTrue(close(solution.localFromRemote.translation, truth.translation, tolerance: 0.15))
    XCTAssertGreaterThanOrEqual(solution.candidateCount, 3)
  }

  func testPairwiseRequiresDirectionOnBothSides() {
    let truth = NearbyFrameTransform(yawRadians: 0.4, translation: NearbyVector3(x: 2, y: 0, z: 1))
    let world = Self.twoDeviceWorld(remoteToLocal: truth)
    let distanceOnlyRemote = world.remote.map { Self.stripDirection($0) }
    let outcome = NearbyPairwiseSolver.solve(local: world.local, remote: distanceOnlyRemote)
    XCTAssertEqual(outcome, .needsDirection(localHas: true, remoteHas: false))
  }

  func testPairwiseIgnoresOutliersThroughMedianConsensus() throws {
    let truth = NearbyFrameTransform(yawRadians: -0.9, translation: NearbyVector3(x: -1, y: 0, z: 4))
    var world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 7)
    // A single multipath ghost on one side: wildly wrong direction.
    let ghost = world.local[3]
    world.local[3] = NearbyRangingSample(peerID: ghost.peerID, distanceMeters: ghost.distanceMeters + 1.5,
      direction: NearbyVector3(x: 0, y: 0, z: 1), cameraPose: ghost.cameraPose, observedAt: ghost.observedAt)
    guard case .solved(let solution) = NearbyPairwiseSolver.solve(local: world.local, remote: world.remote)
    else { return XCTFail("expected solve") }
    XCTAssertEqual(solution.localFromRemote.yawRadians, truth.yawRadians, accuracy: 0.05)
    XCTAssertTrue(close(solution.localFromRemote.translation, truth.translation, tolerance: 0.25))
  }

  // MARK: Graph cross-check

  func testGraphPicksConsistentSubsetAndFlagsConflict() {
    let hostFromB = NearbyFrameTransform(yawRadians: 0.5, translation: NearbyVector3(x: 1, y: 0, z: 2))
    let hostFromC = NearbyFrameTransform(yawRadians: -1.2, translation: NearbyVector3(x: -3, y: 0, z: 1))
    let cFromB = hostFromC.inverse.composed(with: hostFromB)
    var graph = NearbyFrameGraph()
    graph.setLink(from: "b", to: "host", transform: hostFromB)
    graph.setLink(from: "c", to: "host", transform: hostFromC)
    graph.setLink(from: "b", to: "c", transform: cFromB)
    guard case .solved(let b) = graph.alignment(of: "b", toHost: "host", participants: ["b", "c", "host"])
    else { return XCTFail("b should solve via direct and via c") }
    XCTAssertEqual(b.agreeingLinks, 2)
    XCTAssertEqual(b.toHostFrame.yawRadians, hostFromB.yawRadians, accuracy: 1e-6)

    // Corrupt the b→c link: two paths now disagree with no majority.
    graph.setLink(from: "b", to: "c",
      transform: NearbyFrameTransform(yawRadians: cFromB.yawRadians + 1, translation: cFromB.translation))
    guard case .inconsistent = graph.alignment(of: "b", toHost: "host", participants: ["b", "c", "host"])
    else { return XCTFail("disagreeing paths must surface as inconsistent") }
    XCTAssertEqual(graph.alignment(of: "d", toHost: "host", participants: ["b", "c", "d", "host"]), .unreachable)
  }

  // MARK: Distance-only fallback

  func testDistanceOnlyLeastSquaresRecoversTransformAfterMotion() {
    let truth = NearbyFrameTransform(yawRadians: 2.3, translation: NearbyVector3(x: 2.5, y: 0, z: -1.5))
    let world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 14, spreadMeters: 3)
    let ranges = NearbyDistanceOnlySolver.ranges(
      local: world.local.map { Self.stripDirection($0) }, remote: world.remote.map { Self.stripDirection($0) })
    guard case .solved(let solution) = NearbyDistanceOnlySolver.solve(ranges) else {
      return XCTFail("expected distance-only solve")
    }
    XCTAssertEqual(solution.localFromRemote.yawRadians, truth.yawRadians, accuracy: 0.08)
    XCTAssertTrue(close(solution.localFromRemote.translation, truth.translation, tolerance: 0.35))
  }

  func testDistanceOnlyRefusesWithoutGeometricSpread() {
    let truth = NearbyFrameTransform(yawRadians: 0.3, translation: NearbyVector3(x: 2, y: 0, z: 0))
    let world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 12, spreadMeters: 0.05)
    let ranges = NearbyDistanceOnlySolver.ranges(
      local: world.local.map { Self.stripDirection($0) }, remote: world.remote.map { Self.stripDirection($0) })
    guard case .insufficientMotion = NearbyDistanceOnlySolver.solve(ranges) else {
      return XCTFail("standing still must not produce a confident transform")
    }
  }

  func testDistanceOnlyRefusesWhenOnlyTheLocalSideMoved() {
    // One moving phone and one stationary phone: distance-only ranges leave
    // yaw unobservable, so the solver must refuse rather than emit an
    // arbitrary rotation.
    let truth = NearbyFrameTransform(yawRadians: 0.3, translation: NearbyVector3(x: 2, y: 0, z: 0))
    let world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 14, spreadMeters: 3,
      remoteSpreadMeters: 0.05)
    let ranges = NearbyDistanceOnlySolver.ranges(
      local: world.local.map { Self.stripDirection($0) }, remote: world.remote.map { Self.stripDirection($0) })
    guard case .insufficientMotion = NearbyDistanceOnlySolver.solve(ranges) else {
      return XCTFail("a stationary remote must not produce a confident transform")
    }
  }

  // MARK: Relay envelopes

  func testEnvelopesRoundTripAsOpaqueJSON() throws {
    let tokens = NearbyRelayEnvelope.tokens(epoch: 7,
      tokens: ["p2": Data([1, 2, 3, 250]), "p3": Data([4, 5])])
    XCTAssertEqual(try NearbyRelayEnvelope.decode(try tokens.encoded()), tokens)
    // The niToken lane carries the encoded JSON as its opaque string.
    let tokenString = try tokens.encodedTokenString()
    XCTAssertLessThanOrEqual(tokenString.utf8.count, NearbyRelayEnvelope.maximumTokenBytes)
    XCTAssertEqual(try NearbyRelayEnvelope.decode(tokenString: tokenString), tokens)
    let sample = NearbyRangingSample(peerID: "p2", distanceMeters: 2.31,
      direction: NearbyVector3(x: 0, y: 0, z: -1), cameraPose: Self.identityPose, observedAt: base)
    let ranging = NearbyRelayEnvelope.ranging(epoch: 7, samples: [sample])
    let decoded = try NearbyRelayEnvelope.decode(try ranging.encoded())
    guard case .ranging(7, let samples) = decoded, let first = samples.first else { return XCTFail() }
    XCTAssertEqual(first.peerID, "p2")
    XCTAssertEqual(first.distanceMeters, 2.31, accuracy: 1e-9)
    XCTAssertEqual(first.direction, sample.direction)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try tokens.encoded()) as? [String: Any])
    XCTAssertEqual(json["kind"] as? String, "tokens")
    XCTAssertEqual(json["v"] as? Int, 1)
    XCTAssertNotNil(json["tokens"] as? [String: String])
    XCTAssertThrowsError(try NearbyRelayEnvelope.decode(Data("{\"v\":2,\"kind\":\"tokens\"}".utf8)))
    // The worker's niTokenBytes bound applies to the token lane.
    XCTAssertThrowsError(try NearbyRelayEnvelope.tokens(epoch: 7,
      tokens: ["p2": Data(repeating: 1, count: 4_500)]).encoded())
    XCTAssertThrowsError(try NearbyRelayEnvelope.tokens(epoch: 7,
      tokens: ["a": Data([1]), "b": Data([2]), "c": Data([3]), "d": Data([4])]).encoded())
  }

  // MARK: Policy

  func testPolicyCapsPeersAtThreeAndRejectsBadRosters() {
    var policy = NearbyRendezvousPolicy()
    XCTAssertThrowsError(try policy.configure(epoch: 1, localPeerID: "a", hostPeerID: "a",
      roster: ["a", "b", "c", "d", "e"])) {
      XCTAssertEqual($0 as? NearbyTargetingFailure, .tooManyPeers)
    }
    XCTAssertThrowsError(try policy.configure(epoch: 1, localPeerID: "a", hostPeerID: "z", roster: ["a", "b"])) {
      XCTAssertEqual($0 as? NearbyTargetingFailure, .invalidConfiguration)
    }
    XCTAssertNoThrow(try policy.configure(epoch: 1, localPeerID: "a", hostPeerID: "a", roster: ["a", "b", "c", "d"]))
    XCTAssertThrowsError(try policy.configure(epoch: 1, localPeerID: "a", hostPeerID: "a", roster: ["a", "b"])) {
      XCTAssertEqual($0 as? NearbyTargetingFailure, .staleEpoch)
    }
    XCTAssertEqual(policy.snapshot.stage, .awaitingTokens)
    XCTAssertEqual(policy.snapshot.phase, .bootstrap)
  }

  func testPolicySolvesThreePlayersAndEmitsRelayTraffic() throws {
    // Host frame is "h"; "a" (local) and "b" have their own frames.
    let hostFromA = NearbyFrameTransform(yawRadians: 0.8, translation: NearbyVector3(x: 2, y: 0.05, z: -1))
    let hostFromB = NearbyFrameTransform(yawRadians: -1.7, translation: NearbyVector3(x: -1.5, y: 0, z: 3))
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 3, localPeerID: "a", hostPeerID: "h", roster: ["a", "b", "h"])
    // One discovery token per peer, keyed by the session's target peer.
    try policy.recordLocalTokens(["b": Data([9, 9]), "h": Data([8, 8])])
    XCTAssertEqual(policy.localToken(for: "b"), Data([9, 9]))
    XCTAssertEqual(policy.drainOutboundTokens().count, 1)

    let now = base
    // Each peer's tokens envelope is keyed by target; this device keeps the
    // entry addressed to "a".
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 3, tokens: ["a": Data([1])]).encoded(),
      from: "h", at: now)
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 3, tokens: ["a": Data([2])]).encoded(),
      from: "b", at: now)
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 3, tokens: ["a": Data([3])]).encoded(),
      from: "zz", at: now)
    XCTAssertEqual(policy.snapshot.rangingPeers, ["b", "h"])
    XCTAssertEqual(policy.token(for: "h"), Data([1]))
    XCTAssertEqual(policy.tokenGeneration(for: "h"), 1)
    XCTAssertEqual(policy.snapshot.stage, .ranging)

    let scene = Self.threeDeviceScene(hostFromA: hostFromA, hostFromB: hostFromB, at: now)
    for sample in scene.aSamples { policy.ingestLocalSample(sample, at: now.addingTimeInterval(0.5)) }
    for (from, samples) in scene.relayed {
      let data = try NearbyRelayEnvelope.ranging(epoch: 3, samples: samples).encoded()
      policy.receive(ranging: data, from: from, at: now.addingTimeInterval(0.5))
    }
    policy.solve(at: now.addingTimeInterval(1))
    XCTAssertEqual(policy.snapshot.stage, .solved)
    XCTAssertEqual(policy.snapshot.phase, .live)
    let local = try XCTUnwrap(policy.snapshot.localToHostFrame)
    XCTAssertEqual(local.yawRadians, hostFromA.yawRadians, accuracy: 0.05)
    XCTAssertTrue(close(local.translation, hostFromA.translation, tolerance: 0.25))
    let b = try XCTUnwrap(policy.snapshot.alignments["b"])
    XCTAssertEqual(b.toHostFrame.yawRadians, hostFromB.yawRadians, accuracy: 0.05)
    XCTAssertGreaterThanOrEqual(b.agreeingLinks, 2, "b is reachable directly and via a")

    policy.flushSamples()
    let outbound = policy.drainOutboundRanging()
    XCTAssertFalse(outbound.isEmpty)
    XCTAssertTrue(policy.drainOutboundTokens().isEmpty, "tokens only go out on session (re)build")
    for data in outbound {
      guard case .ranging(3, let samples) = try NearbyRelayEnvelope.decode(data) else { return XCTFail() }
      XCTAssertLessThanOrEqual(samples.count, NearbyRelayEnvelope.maximumSamplesPerEnvelope)
    }
  }

  func testPolicySurfacesRetryWhenDirectionNeverArrivesAndHedgeAdvances() throws {
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 2, localPeerID: "a", hostPeerID: "h", roster: ["a", "h"])
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 2, tokens: ["a": Data([1])]).encoded(),
      from: "h", at: base)
    let truth = NearbyFrameTransform(yawRadians: 0.2, translation: NearbyVector3(x: 1, y: 0, z: 1))
    let world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 5, at: base.addingTimeInterval(8),
      localID: "a", remoteID: "h")
    let late = base.addingTimeInterval(9)
    for sample in world.local { policy.ingestLocalSample(Self.stripDirection(sample), at: late) }
    let relayed = world.remote.map { Self.stripDirection($0) }
    policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 2, samples: relayed).encoded(),
      from: "h", at: late)
    policy.solve(at: late)
    XCTAssertEqual(policy.snapshot.stage, .needsRetry(.directionUnavailable(peerIDs: ["h"])))
    XCTAssertTrue(policy.directionAppearsUnavailable)
    XCTAssertTrue(policy.snapshot.collaborationMayStart, "plain NI never blocks ARKit collaboration")

    XCTAssertEqual(policy.advanceHedge(at: late), .cameraAssisted)
    XCTAssertFalse(policy.snapshot.collaborationMayStart,
      "isCameraAssistanceEnabled requires isCollaborationEnabled == false")
    XCTAssertEqual(policy.advanceHedge(at: late), .distanceOnly)
    XCTAssertTrue(policy.snapshot.collaborationMayStart)
    XCTAssertNil(policy.advanceHedge(at: late), "hedge is exhausted after distance-only")
  }

  func testPolicyIgnoresOtherEpochsAndStaleSamples() throws {
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 5, localPeerID: "a", hostPeerID: "h", roster: ["a", "h"])
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 4, tokens: ["a": Data([1])]).encoded(),
      from: "h", at: base)
    XCTAssertEqual(policy.snapshot.rangingPeers, [])
    let stale = NearbyRangingSample(peerID: "h", distanceMeters: 2, direction: NearbyVector3(x: 0, y: 0, z: -1),
      cameraPose: Self.identityPose, observedAt: base.addingTimeInterval(-30))
    policy.ingestLocalSample(stale, at: base)
    policy.flushSamples()
    XCTAssertTrue(policy.drainOutboundRanging().isEmpty)
  }

  func testHostStaysInBootstrapUntilEveryPeerAligns() throws {
    // The host's own frame is the target frame, so it cannot declare itself
    // solved while any other participant's link is still unresolved.
    let hostFromA = NearbyFrameTransform(yawRadians: 0.8, translation: NearbyVector3(x: 2, y: 0, z: -1))
    let hostFromB = NearbyFrameTransform(yawRadians: -1.7, translation: NearbyVector3(x: -1.5, y: 0, z: 3))
    var rng = SeededRandom(seed: 11)
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 4, localPeerID: "h", hostPeerID: "h", roster: ["h", "a", "b"],
      bootstrap: .cameraAssisted)
    try policy.recordLocalTokens(["a": Data([1]), "b": Data([2])])
    let now = base
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 4, tokens: ["h": Data([9])]).encoded(),
      from: "a", at: now)
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 4, tokens: ["h": Data([8])]).encoded(),
      from: "b", at: now)

    let pa = NearbyVector3(x: -1, y: 1.4, z: 0), ph = NearbyVector3(x: 2, y: 1.5, z: 2)
    let pb = NearbyVector3(x: 0, y: 1.45, z: -2.5)
    var aTowardH: [NearbyRangingSample] = [], bTowardH: [NearbyRangingSample] = []
    for index in 0..<4 {
      let at = now.addingTimeInterval(0.2 * Double(index))
      policy.ingestLocalSample(Self.sample(from: ph, to: pa, frame: .identity, yaw: 0.3,
        peerID: "a", observedAt: at, rng: &rng), at: at)
      policy.ingestLocalSample(Self.sample(from: ph, to: pb, frame: .identity, yaw: 0.3,
        peerID: "b", observedAt: at, rng: &rng), at: at)
      aTowardH.append(Self.sample(from: pa, to: ph, frame: hostFromA.inverse, yaw: 2.0,
        peerID: "h", observedAt: at, rng: &rng))
      bTowardH.append(Self.sample(from: pb, to: ph, frame: hostFromB.inverse, yaw: -1,
        peerID: "h", observedAt: at, rng: &rng))
    }
    // Only the a↔h link has both directions so far: a aligns, b is unreachable.
    policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 4, samples: aTowardH).encoded(),
      from: "a", at: now.addingTimeInterval(0.8))
    policy.solve(at: now.addingTimeInterval(1))
    XCTAssertNotNil(policy.snapshot.alignments["a"])
    XCTAssertNotEqual(policy.snapshot.stage, .solved)
    XCTAssertFalse(policy.snapshot.collaborationMayStart,
      "host must not leave camera-assisted bootstrap while a peer is unaligned")

    policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 4, samples: bTowardH).encoded(),
      from: "b", at: now.addingTimeInterval(1))
    policy.solve(at: now.addingTimeInterval(1.1))
    XCTAssertEqual(policy.snapshot.stage, .solved)
    XCTAssertTrue(policy.snapshot.collaborationMayStart)
  }

  func testPolicyRebasesPeerClockOffsets() throws {
    // The relayed phones' wall clocks run 10 s ahead; the per-peer offset
    // estimate must rebase their stamps so valid ranges are not discarded.
    let hostFromA = NearbyFrameTransform(yawRadians: 0.8, translation: NearbyVector3(x: 2, y: 0.05, z: -1))
    let hostFromB = NearbyFrameTransform(yawRadians: -1.7, translation: NearbyVector3(x: -1.5, y: 0, z: 3))
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 3, localPeerID: "a", hostPeerID: "h", roster: ["a", "b", "h"])
    let now = base
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 3, tokens: ["a": Data([1])]).encoded(),
      from: "h", at: now)
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 3, tokens: ["a": Data([2])]).encoded(),
      from: "b", at: now)
    let scene = Self.threeDeviceScene(hostFromA: hostFromA, hostFromB: hostFromB, at: now,
      remoteClockShift: 10)
    for sample in scene.aSamples { policy.ingestLocalSample(sample, at: now.addingTimeInterval(0.5)) }
    for (from, samples) in scene.relayed {
      let data = try NearbyRelayEnvelope.ranging(epoch: 3, samples: samples).encoded()
      policy.receive(ranging: data, from: from, at: now.addingTimeInterval(0.5))
    }
    policy.solve(at: now.addingTimeInterval(1))
    XCTAssertEqual(policy.snapshot.stage, .solved)
    let local = try XCTUnwrap(policy.snapshot.localToHostFrame)
    XCTAssertEqual(local.yawRadians, hostFromA.yawRadians, accuracy: 0.05)
    XCTAssertTrue(close(local.translation, hostFromA.translation, tolerance: 0.25))
  }

  func testClockOffsetOutlierEnvelopeIsDropped() throws {
    var policy = NearbyRendezvousPolicy()
    try policy.configure(epoch: 2, localPeerID: "a", hostPeerID: "h", roster: ["a", "h"])
    policy.receive(tokens: try NearbyRelayEnvelope.tokens(epoch: 2, tokens: ["a": Data([1])]).encoded(),
      from: "h", at: base)
    let truth = NearbyFrameTransform(yawRadians: 0.2, translation: NearbyVector3(x: 1, y: 0, z: 1))
    let world = Self.twoDeviceWorld(remoteToLocal: truth, samples: 6, at: base,
      localID: "a", remoteID: "h")
    // Five normal envelopes establish the offset estimate.
    for index in 0..<5 {
      let samples = world.remote.map {
        Self.sampleEnvelopeCopy($0, observedAt: $0.observedAt.addingTimeInterval(0.05 * Double(index)))
      }
      policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 2, samples: samples).encoded(),
        from: "h", at: base.addingTimeInterval(0.05 * Double(index) + 0.6))
    }
    for sample in world.local { policy.ingestLocalSample(sample, at: base.addingTimeInterval(1)) }
    policy.solve(at: base.addingTimeInterval(1.2))
    XCTAssertEqual(policy.snapshot.stage, .solved)

    // One corrupt envelope stamped an hour ahead must not move the median,
    // and its samples are dropped by the rebase + staleness checks.
    let outlier = world.remote.map {
      Self.sampleEnvelopeCopy($0, observedAt: $0.observedAt.addingTimeInterval(3_600))
    }
    policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 2, samples: outlier).encoded(),
      from: "h", at: base.addingTimeInterval(1.4))
    policy.receive(ranging: try NearbyRelayEnvelope.ranging(epoch: 2, samples: world.remote).encoded(),
      from: "h", at: base.addingTimeInterval(1.6))
    for sample in world.local { policy.ingestLocalSample(sample, at: base.addingTimeInterval(1.6)) }
    policy.solve(at: base.addingTimeInterval(1.8))
    XCTAssertEqual(policy.snapshot.stage, .solved)
    // `truth` maps remote (h) → local (a); localToHostFrame is its inverse.
    let local = try XCTUnwrap(policy.snapshot.localToHostFrame)
    XCTAssertEqual(local.yawRadians, truth.inverse.yawRadians, accuracy: 0.05)
    XCTAssertTrue(close(local.translation, truth.inverse.translation, tolerance: 0.25))
  }

  // MARK: Session planning (U2 hedge precondition)

  func testPlannerBuildsOneSessionPerPeerAndRefusesCameraAssistanceAfterCollab() throws {
    let tokens: [String: Data] = ["b": Data([1]), "c": Data([2])]
    let plans = try NearbySessionPlanner.plans(for: ["b", "c", "d"], tokens: { tokens[$0] },
      mode: .cameraAssisted, collaborationStarted: false)
    XCTAssertEqual(plans.map(\.peerID), ["b", "c"], "no token, no session")
    XCTAssertTrue(plans.allSatisfy(\.cameraAssistance))
    XCTAssertThrowsError(try NearbySessionPlanner.plans(for: ["b"], tokens: { tokens[$0] },
      mode: .cameraAssisted, collaborationStarted: true)) {
      XCTAssertEqual($0 as? NearbySessionPlanError, .cameraAssistanceAfterCollaboration)
    }
    XCTAssertNoThrow(try NearbySessionPlanner.plans(for: ["b"], tokens: { tokens[$0] },
      mode: .plain, collaborationStarted: true))
    XCTAssertThrowsError(try NearbySessionPlanner.plans(for: ["b", "c", "d", "e"], tokens: { tokens[$0] },
      mode: .plain, collaborationStarted: false)) {
      XCTAssertEqual($0 as? NearbySessionPlanError, .peerCapExceeded)
    }
  }

  // MARK: Helpers

  static let identityPose = NearbyRigidPose(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])!

  static func pose(position: NearbyVector3, yaw: Double) -> NearbyRigidPose? {
    let c = cos(yaw), s = sin(yaw)
    return NearbyRigidPose(columnMajor: [
      c, 0, -s, 0,
      0, 1, 0, 0,
      s, 0, c, 0,
      position.x, position.y, position.z, 1,
    ])
  }

  struct TwoDeviceWorld {
    var local: [NearbyRangingSample]
    var remote: [NearbyRangingSample]
  }

  /// Both devices wander in the host ("local") frame; the remote device
  /// reports everything in its own frame, related by `remoteToLocal`.
  static func twoDeviceWorld(remoteToLocal: NearbyFrameTransform, samples count: Int = 5,
    spreadMeters: Double = 1.5, remoteSpreadMeters: Double? = nil,
    at start: Date = Date(timeIntervalSince1970: 1_000),
    localID: String = "local", remoteID: String = "remote"
  ) -> TwoDeviceWorld {
    var rng = SeededRandom(seed: 42)
    var world = TwoDeviceWorld(local: [], remote: [])
    let localToRemote = remoteToLocal.inverse
    let remoteSpread = remoteSpreadMeters ?? spreadMeters
    for index in 0..<count {
      let t = Double(index) / Double(max(count - 1, 1))
      let localPos = NearbyVector3(x: -spreadMeters + 2 * spreadMeters * t, y: 1.4 + 0.05 * rng.next(),
        z: 0.3 * sin(3 * t))
      let remotePos = NearbyVector3(x: 3 + 0.25 * remoteSpread * rng.next(), y: 1.5,
        z: 2 - remoteSpread * t)
      let observedAt = start.addingTimeInterval(0.2 * Double(index))
      world.local.append(sample(from: localPos, to: remotePos, frame: .identity, yaw: 0.3 * t + rng.next(),
        peerID: remoteID, observedAt: observedAt, rng: &rng))
      world.remote.append(sample(from: remotePos, to: localPos, frame: localToRemote, yaw: -1.2 + rng.next(),
        peerID: localID, observedAt: observedAt, rng: &rng))
    }
    return world
  }

  /// A sample as device at `from` would report it about the peer at `to`,
  /// both given in the host frame; `frame` maps host → device frame.
  static func sample(from: NearbyVector3, to: NearbyVector3, frame: NearbyFrameTransform, yaw: Double,
    peerID: String, observedAt: Date, rng: inout SeededRandom
  ) -> NearbyRangingSample {
    let ownPos = frame.apply(from), peerPos = frame.apply(to)
    let cameraPose = pose(position: ownPos, yaw: yaw)!
    let delta = peerPos - ownPos
    let distance = delta.length + 0.03 * rng.next()
    // Rotate the world-frame bearing into the camera frame (inverse yaw).
    let c = cos(-yaw), s = sin(-yaw)
    var direction = NearbyVector3(x: c * delta.x + s * delta.z, y: delta.y, z: -s * delta.x + c * delta.z)
    direction = direction + NearbyVector3(x: 0.01 * rng.next(), y: 0.01 * rng.next(), z: 0.01 * rng.next())
    return NearbyRangingSample(peerID: peerID, distanceMeters: distance, direction: direction.normalized,
      cameraPose: cameraPose, observedAt: observedAt)
  }

  static func stripDirection(_ sample: NearbyRangingSample) -> NearbyRangingSample {
    NearbyRangingSample(peerID: sample.peerID, distanceMeters: sample.distanceMeters, direction: nil,
      cameraPose: sample.cameraPose, observedAt: sample.observedAt)
  }

  static func sampleEnvelopeCopy(_ sample: NearbyRangingSample, observedAt: Date) -> NearbyRangingSample {
    NearbyRangingSample(peerID: sample.peerID, distanceMeters: sample.distanceMeters,
      direction: sample.direction, cameraPose: sample.cameraPose, observedAt: observedAt)
  }

  struct ThreeDeviceScene {
    var aSamples: [NearbyRangingSample]
    var relayed: [(String, [NearbyRangingSample])]
  }

  static func threeDeviceScene(hostFromA: NearbyFrameTransform, hostFromB: NearbyFrameTransform,
    at start: Date, remoteClockShift: TimeInterval = 0
  ) -> ThreeDeviceScene {
    var rng = SeededRandom(seed: 7)
    let aFromHost = hostFromA.inverse, bFromHost = hostFromB.inverse
    var a: [NearbyRangingSample] = [], h: [NearbyRangingSample] = [], b: [NearbyRangingSample] = []
    for index in 0..<4 {
      let t = Double(index) * 0.3
      let pa = NearbyVector3(x: -1 + t, y: 1.4, z: 0), ph = NearbyVector3(x: 2, y: 1.5, z: 2 - t)
      let pb = NearbyVector3(x: 0.5 * t, y: 1.45, z: -2.5)
      let at = start.addingTimeInterval(0.2 * Double(index))
      a.append(sample(from: pa, to: ph, frame: aFromHost, yaw: 0.2, peerID: "h", observedAt: at, rng: &rng))
      a.append(sample(from: pa, to: pb, frame: aFromHost, yaw: 0.2, peerID: "b", observedAt: at, rng: &rng))
      h.append(sample(from: ph, to: pa, frame: .identity, yaw: 2.9, peerID: "a", observedAt: at, rng: &rng))
      h.append(sample(from: ph, to: pb, frame: .identity, yaw: 2.9, peerID: "b", observedAt: at, rng: &rng))
      b.append(sample(from: pb, to: pa, frame: bFromHost, yaw: -1, peerID: "a", observedAt: at, rng: &rng))
      b.append(sample(from: pb, to: ph, frame: bFromHost, yaw: -1, peerID: "h", observedAt: at, rng: &rng))
    }
    if remoteClockShift != 0 {
      h = h.map { $0.rebased(by: -remoteClockShift) }
      b = b.map { $0.rebased(by: -remoteClockShift) }
    }
    return ThreeDeviceScene(aSamples: a, relayed: [("h", h), ("b", b)])
  }

  /// Deterministic noise in [-1, 1] so failures reproduce.
  struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
      state ^= state << 13; state ^= state >> 7; state ^= state << 17
      return Double(state % 20_001) / 10_000 - 1
    }
  }

  private func close(_ a: NearbyVector3, _ b: NearbyVector3, tolerance: Double = 1e-6) -> Bool {
    (a - b).length <= tolerance
  }
}

/// ADR 0012 §4: an NI seed satisfies the collaborative alignment gate; the
/// ARKit participant-anchor merge becomes refinement evidence.
final class DuelFrameNearbySeedTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_000)
  private let matrix: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

  func testNearbySeedAlignsCollaborativeSessionWithoutPeerMerge() throws {
    var policy = try collaborativeWaiting()
    ingest(&policy, tracking: .normal, mergedPeers: 0, time: 0.3)
    XCTAssertEqual(policy.snapshot.stage, .relocalizingWorld)
    try policy.recordNearbySeed(seed(epoch: 1, time: 0.35), at: base.addingTimeInterval(0.35))
    XCTAssertEqual(policy.snapshot.alignmentEvidence, .nearbySeed)
    XCTAssertFalse(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.35)), "seed alone is not a pose")
    XCTAssertFalse(ingest(&policy, tracking: .normal, mergedPeers: 0, time: 0.4))
    XCTAssertEqual(policy.snapshot.stage, .aligned)
    XCTAssertTrue(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.4)))
    // A later participant anchor is refinement, not a gate change.
    ingest(&policy, tracking: .normal, mergedPeers: 1, time: 0.5)
    XCTAssertEqual(policy.snapshot.stage, .aligned)
    XCTAssertEqual(policy.snapshot.alignmentEvidence, .nearbySeedAndPeerMerge)
  }

  func testPeerMergeStillAlignsWithoutSeed() throws {
    var policy = try collaborativeWaiting()
    ingest(&policy, tracking: .normal, mergedPeers: 1, time: 0.4)
    XCTAssertEqual(policy.snapshot.stage, .aligned)
    XCTAssertEqual(policy.snapshot.alignmentEvidence, .peerMerge)
    XCTAssertNil(policy.snapshot.nearbySeed)
  }

  func testSeedRejectsWrongEpochModeAndStaleSolves() throws {
    var measured = DuelFramePolicy()
    try measured.beginCalibration(epoch: 1, at: base)
    XCTAssertThrowsError(try measured.recordNearbySeed(seed(epoch: 1, time: 0.1), at: base.addingTimeInterval(0.1))) {
      XCTAssertEqual($0 as? DuelFrameFailure, .invalidResidual)
    }
    var policy = try collaborativeWaiting()
    XCTAssertThrowsError(try policy.recordNearbySeed(seed(epoch: 2, time: 0.1), at: base.addingTimeInterval(0.1))) {
      XCTAssertEqual($0 as? DuelFrameFailure, .staleEpoch)
    }
    try policy.recordNearbySeed(seed(epoch: 1, time: 0.2), at: base.addingTimeInterval(0.2))
    XCTAssertThrowsError(try policy.recordNearbySeed(seed(epoch: 1, time: 0.1), at: base.addingTimeInterval(0.3))) {
      XCTAssertEqual($0 as? DuelFrameFailure, .invalidResidual)
    }
    policy.invalidate(reason: .trackingLost)
    XCTAssertNil(policy.snapshot.nearbySeed)
    XCTAssertThrowsError(try policy.recordNearbySeed(seed(epoch: 1, time: 0.4), at: base.addingTimeInterval(0.4))) {
      XCTAssertEqual($0 as? DuelFrameFailure, .mapNotReady)
    }
  }

  func testNewEpochDropsOldSeed() throws {
    var policy = try collaborativeWaiting()
    try policy.recordNearbySeed(seed(epoch: 1, time: 0.2), at: base.addingTimeInterval(0.2))
    try policy.beginCalibration(epoch: 2, captureRequired: false, mode: .collaborative, at: base.addingTimeInterval(1))
    XCTAssertNil(policy.snapshot.nearbySeed)
    XCTAssertEqual(policy.snapshot.alignmentEvidence, .none)
  }

  func testAlignedPoseIsExpressedInHostFrame() throws {
    // Observed poses arrive in the local ARKit frame; once an NI seed exists
    // the stored shared-frame pose is the observation mapped through the
    // seed's local→host transform.
    var policy = try collaborativeWaiting()
    let seedTransform = NearbyFrameTransform(yawRadians: .pi / 2,
      translation: NearbyVector3(x: 1, y: 0, z: 0))
    try policy.recordNearbySeed(DuelFrameNearbySeed(epoch: 1, hostPeerID: "host",
      localToHostFrame: seedTransform,
      residual: NearbyAlignmentResidual(translationMeters: 0.1, yawDegrees: 1),
      agreeingLinks: 2, solvedAt: base.addingTimeInterval(0.2)), at: base.addingTimeInterval(0.2))
    ingest(&policy, tracking: .normal, mergedPeers: 0, time: 0.3)
    XCTAssertEqual(policy.snapshot.stage, .aligned)
    let pose = try XCTUnwrap(policy.snapshot.localPose)
    let expected = seedTransform.columnMajor
    for index in 0..<16 {
      XCTAssertEqual(pose.columnMajor[index], expected[index], accuracy: 1e-9,
        "identity observation must equal the seed transform (index \(index))")
    }
    XCTAssertTrue(policy.snapshot.permitsSpatialFire(at: base.addingTimeInterval(0.3)))
  }

  private func seed(epoch: UInt16, time: Double) -> DuelFrameNearbySeed {
    DuelFrameNearbySeed(epoch: epoch, hostPeerID: "host",
      localToHostFrame: NearbyFrameTransform(yawRadians: 0.3, translation: NearbyVector3(x: 1, y: 0, z: -2)),
      residual: NearbyAlignmentResidual(translationMeters: 0.12, yawDegrees: 1.5),
      agreeingLinks: 2, solvedAt: base.addingTimeInterval(time))
  }

  private func collaborativeWaiting() throws -> DuelFramePolicy {
    var policy = DuelFramePolicy()
    try policy.beginCalibration(epoch: 1, captureRequired: false, mode: .collaborative, at: base)
    XCTAssertEqual(policy.snapshot.stage, .relocalizingWorld)
    return policy
  }

  @discardableResult
  private func ingest(_ policy: inout DuelFramePolicy, tracking: DuelFrameTracking,
    mergedPeers: Int, time: Double) -> Bool {
    let date = base.addingTimeInterval(time)
    var observation = DuelFrameObservation(epoch: 1,
      frameID: DuelFramePolicy.collaborativeFrameID(epoch: 1),
      phase: .worldRelocalization, tracking: tracking, isMapped: true,
      pose: tracking == .normal ? DuelFramePose(columnMajor: matrix, capturedAt: date, frameTimestamp: time) : nil,
      observedAt: date, failure: nil)
    observation.mergedPeers = mergedPeers
    return policy.ingest(observation, at: date)
  }
}
