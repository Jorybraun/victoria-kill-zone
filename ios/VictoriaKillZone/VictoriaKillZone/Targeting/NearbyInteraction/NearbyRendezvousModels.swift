import Foundation

/// Pure-Foundation geometry for the UWB rendezvous (ADR 0012). No `simd`
/// dependency so the solver and its tests run wherever Foundation does.
struct NearbyVector3: Equatable, Sendable {
  var x: Double
  var y: Double
  var z: Double

  static let zero = NearbyVector3(x: 0, y: 0, z: 0)

  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
  var length: Double { (x * x + y * y + z * z).squareRoot() }
  var horizontalLength: Double { (x * x + z * z).squareRoot() }

  var normalized: NearbyVector3? {
    let length = length
    guard length > 0, length.isFinite else { return nil }
    return NearbyVector3(x: x / length, y: y / length, z: z / length)
  }

  static func + (lhs: NearbyVector3, rhs: NearbyVector3) -> NearbyVector3 {
    NearbyVector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
  }

  static func - (lhs: NearbyVector3, rhs: NearbyVector3) -> NearbyVector3 {
    NearbyVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
  }

  static func * (lhs: NearbyVector3, rhs: Double) -> NearbyVector3 {
    NearbyVector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
  }

  func distance(to other: NearbyVector3) -> Double { (self - other).length }

  func dot(_ other: NearbyVector3) -> Double { x * other.x + y * other.y + z * other.z }

  func cross(_ other: NearbyVector3) -> NearbyVector3 {
    NearbyVector3(x: y * other.z - z * other.y, y: z * other.x - x * other.z,
      z: x * other.y - y * other.x)
  }
}

/// Column-major 4x4 rigid transform, the same layout `DuelFramePose` carries.
/// Only the rotation block and the translation column are read.
struct NearbyRigidPose: Equatable, Sendable {
  let columnMajor: [Double]

  /// Rejects anything but a rigid homogeneous transform: orthonormal,
  /// right-handed rotation columns and a `[0, 0, 0, 1]` last row. Untrusted
  /// poses (scaled, sheared, reflected) would silently distort the solve.
  init?(columnMajor: [Double]) {
    guard columnMajor.count == 16, columnMajor.allSatisfy(\.isFinite) else { return nil }
    let columns = (0..<3).map {
      NearbyVector3(x: columnMajor[$0 * 4], y: columnMajor[$0 * 4 + 1], z: columnMajor[$0 * 4 + 2])
    }
    guard columns.allSatisfy({ abs($0.length - 1) <= 0.01 }),
      abs(columns[0].dot(columns[1])) <= 0.01,
      abs(columns[0].dot(columns[2])) <= 0.01,
      abs(columns[1].dot(columns[2])) <= 0.01,
      columns[0].cross(columns[1]).dot(columns[2]) > 0,
      abs(columnMajor[3]) <= 1e-6, abs(columnMajor[7]) <= 1e-6,
      abs(columnMajor[11]) <= 1e-6, abs(columnMajor[15] - 1) <= 1e-6
    else { return nil }
    self.columnMajor = columnMajor
  }

  init?(_ pose: DuelFramePose) {
    self.init(columnMajor: pose.columnMajor)
  }

  var translation: NearbyVector3 {
    NearbyVector3(x: columnMajor[12], y: columnMajor[13], z: columnMajor[14])
  }

  /// Rotates a camera-frame vector into the world frame this pose lives in.
  func rotate(_ v: NearbyVector3) -> NearbyVector3 {
    NearbyVector3(
      x: columnMajor[0] * v.x + columnMajor[4] * v.y + columnMajor[8] * v.z,
      y: columnMajor[1] * v.x + columnMajor[5] * v.y + columnMajor[9] * v.z,
      z: columnMajor[2] * v.x + columnMajor[6] * v.y + columnMajor[10] * v.z)
  }

  func transform(_ v: NearbyVector3) -> NearbyVector3 { rotate(v) + translation }
}

/// 4-DOF inter-frame transform under `.gravity` world alignment: a yaw about
/// the shared up axis plus a 3D translation. Maps points from `source` frame
/// coordinates into `target` frame coordinates: `p_target = R(yaw) p_source + t`.
struct NearbyFrameTransform: Equatable, Sendable {
  static let identity = NearbyFrameTransform(yawRadians: 0, translation: .zero)

  let yawRadians: Double
  let translation: NearbyVector3

  init(yawRadians: Double, translation: NearbyVector3) {
    self.yawRadians = Self.wrap(yawRadians)
    self.translation = translation
  }

  var isFinite: Bool { yawRadians.isFinite && translation.isFinite }
  var yawDegrees: Double { yawRadians * 180 / .pi }

  func rotate(_ v: NearbyVector3) -> NearbyVector3 {
    let c = cos(yawRadians), s = sin(yawRadians)
    // Right-handed rotation about +Y (ARKit's gravity-aligned up axis).
    return NearbyVector3(x: c * v.x + s * v.z, y: v.y, z: -s * v.x + c * v.z)
  }

  func apply(_ p: NearbyVector3) -> NearbyVector3 { rotate(p) + translation }

  /// `self.columnMajor × m`, column-major: a pose expressed in `m`'s frame
  /// re-expressed in the frame this transform maps into.
  func apply(toColumnMajor m: [Double]) -> [Double] {
    let a = columnMajor
    var result = [Double](repeating: 0, count: 16)
    for column in 0..<4 {
      for row in 0..<4 {
        var sum = 0.0
        for k in 0..<4 { sum += a[k * 4 + row] * m[column * 4 + k] }
        result[column * 4 + row] = sum
      }
    }
    return result
  }

  var inverse: NearbyFrameTransform {
    let inverseYaw = -yawRadians
    let c = cos(inverseYaw), s = sin(inverseYaw)
    let t = translation
    let rotated = NearbyVector3(x: c * t.x + s * t.z, y: t.y, z: -s * t.x + c * t.z)
    return NearbyFrameTransform(yawRadians: inverseYaw, translation: rotated * -1)
  }

  /// `self ∘ other`: apply `other` first, then `self`.
  func composed(with other: NearbyFrameTransform) -> NearbyFrameTransform {
    NearbyFrameTransform(yawRadians: yawRadians + other.yawRadians,
      translation: rotate(other.translation) + translation)
  }

  /// Column-major 4x4 for consumers that render in the host frame.
  var columnMajor: [Double] {
    let c = cos(yawRadians), s = sin(yawRadians)
    return [
      c, 0, -s, 0,
      0, 1, 0, 0,
      s, 0, c, 0,
      translation.x, translation.y, translation.z, 1,
    ]
  }

  func yawDifference(to other: NearbyFrameTransform) -> Double {
    abs(Self.wrap(yawRadians - other.yawRadians))
  }

  func translationDifference(to other: NearbyFrameTransform) -> Double {
    translation.distance(to: other.translation)
  }

  static func wrap(_ radians: Double) -> Double {
    guard radians.isFinite else { return radians }
    var r = radians.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi }
    if r <= -.pi { r += 2 * .pi }
    return r
  }
}

/// One UWB reading from the local device toward `peerID`, stamped with the
/// local ARKit camera pose at that instant. `direction` is a unit vector in
/// the *camera* frame (NI's own convention) and is nil outside the antenna
/// cone or on hardware that withholds direction (U2 caveat, ADR 0012 §5).
struct NearbyRangingSample: Equatable, Sendable {
  static let maximumDistanceMeters: Double = 50

  let peerID: String
  let distanceMeters: Double
  let direction: NearbyVector3?
  let cameraPose: NearbyRigidPose
  let observedAt: Date

  var isValid: Bool {
    distanceMeters.isFinite && distanceMeters > 0 && distanceMeters <= Self.maximumDistanceMeters
      && (direction.map { $0.isFinite && abs($0.length - 1) < 0.05 } ?? true)
  }

  var hasDirection: Bool { direction != nil }

  /// The same reading with `observedAt` shifted by `-offset`, used to rebase
  /// a peer's wall clock onto the local clock.
  func rebased(by offset: TimeInterval) -> NearbyRangingSample {
    NearbyRangingSample(peerID: peerID, distanceMeters: distanceMeters, direction: direction,
      cameraPose: cameraPose, observedAt: observedAt.addingTimeInterval(-offset))
  }

  /// The peer's antenna position in this device's own world frame, when a
  /// direction is available.
  var peerPositionInLocalFrame: NearbyVector3? {
    guard let direction, let unit = direction.normalized else { return nil }
    return cameraPose.transform(unit * distanceMeters)
  }
}

/// Per-peer solve residual after the graph cross-check.
struct NearbyAlignmentResidual: Equatable, Sendable {
  let translationMeters: Double
  let yawDegrees: Double
}

/// Transform from one peer's ARKit world frame into the elected host frame,
/// plus how many independent links agreed on it.
struct NearbyPeerAlignment: Equatable, Sendable {
  let peerID: String
  let toHostFrame: NearbyFrameTransform
  let residual: NearbyAlignmentResidual
  let agreeingLinks: Int
}

/// Why a pair cannot be solved yet; drives the retry copy.
enum NearbyRendezvousRetryReason: Equatable, Sendable {
  /// No direction-bearing sample yet from one or both sides of the link;
  /// copy: "turn to face each other".
  case directionUnavailable(peerIDs: [String])
  /// Distance-only fallback needs more spread-out ranges.
  case insufficientMotion(peerIDs: [String])
  /// Links disagree beyond tolerance and no consistent subset exists.
  case inconsistentLinks(peerIDs: [String])
  /// A peer's discovery token has not arrived over the relay.
  case awaitingTokens(peerIDs: [String])
}

enum NearbyRendezvousFailure: String, Error, Equatable, Sendable {
  case unsupported, permissionDenied, tooManyPeers, unknownPeer, invalidToken
  case invalidSample, sessionLimitExceeded, invalidConfiguration, notConfigured
  case staleEpoch, cameraAssistanceRequiresCollaborationOff
}

/// Relay-lane contract for ADR 0012 §1. Two lanes share the match WebSocket:
///
///   - The merged worker lane (`ClientMessage {type:"niToken", token}` /
///     `ServerMessage {type:"niToken", playerId, token}`) carries one opaque
///     string per send, bounded at `maximumTokenBytes`, rate limited to ~1/s.
///     It transports the `tokens` envelope: this device's serialized
///     `NIDiscoveryToken` for the per-peer session dedicated to each peer,
///     keyed by target peer id. Sent rarely — on session (re)build only.
///   - The proposed `niRanging` lane (Integration handoff) carries `ranging`
///     envelopes at NI update rates; the token lane cannot absorb them.
///
/// Wire shape (JSON; the token lane sends it as the `token` string, the
/// ranging lane as `data`):
///   {"v":1,"kind":"tokens","epoch":7,"tokens":{"b":"<base64 token for b>"}}
///   {"v":1,"kind":"ranging","epoch":7,"samples":[{"peerID":"p2",
///     "distance":2.31,"direction":[0.1,-0.02,-0.99],"pose":[16 doubles],
///     "observedAt":1758572400.123}]}
enum NearbyRelayEnvelope: Equatable, Sendable {
  static let version = 1
  static let maximumBytes = 8 * 1024
  /// Worker `niTokenBytes` bound on the token lane.
  static let maximumTokenBytes = 4 * 1024
  static let maximumSamplesPerEnvelope = 8

  /// `tokens` is keyed by the TARGET peer id; each value is the serialized
  /// `NIDiscoveryToken` of the local `NISession` dedicated to that peer.
  case tokens(epoch: UInt16, tokens: [String: Data])
  case ranging(epoch: UInt16, samples: [NearbyRangingSample])

  var epoch: UInt16 {
    switch self {
    case .tokens(let epoch, _), .ranging(let epoch, _): epoch
    }
  }

  func encoded() throws -> Data {
    let wire: Wire
    var byteCap = Self.maximumBytes
    switch self {
    case .tokens(let epoch, let tokens):
      guard !tokens.isEmpty, tokens.count <= NearbyRendezvousPolicy.maximumPeers,
        tokens.keys.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
        tokens.values.allSatisfy({ !$0.isEmpty })
      else { throw NearbyRendezvousFailure.invalidToken }
      byteCap = Self.maximumTokenBytes
      wire = Wire(v: Self.version, kind: "tokens", epoch: epoch, tokens: tokens, samples: nil)
    case .ranging(let epoch, let samples):
      guard !samples.isEmpty, samples.count <= Self.maximumSamplesPerEnvelope,
        samples.allSatisfy(\.isValid)
      else { throw NearbyRendezvousFailure.invalidSample }
      wire = Wire(v: Self.version, kind: "ranging", epoch: epoch, tokens: nil,
        samples: samples.map(WireSample.init))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(wire)
    guard data.count <= byteCap else { throw NearbyRendezvousFailure.invalidToken }
    return data
  }

  /// The `niToken` lane's outbound string: the encoded JSON as UTF-8.
  func encodedTokenString() throws -> String {
    guard let string = String(data: try encoded(), encoding: .utf8)
    else { throw NearbyRendezvousFailure.invalidToken }
    return string
  }

  /// The `niToken` lane's inbound string decoded back to an envelope.
  static func decode(tokenString: String) throws -> NearbyRelayEnvelope {
    try decode(Data(tokenString.utf8))
  }

  static func decode(_ data: Data) throws -> NearbyRelayEnvelope {
    guard !data.isEmpty, data.count <= maximumBytes else { throw NearbyRendezvousFailure.invalidToken }
    let wire: Wire
    do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch {
      throw NearbyRendezvousFailure.invalidToken
    }
    guard wire.v == version, wire.epoch > 0 else { throw NearbyRendezvousFailure.invalidToken }
    switch wire.kind {
    case "tokens":
      guard data.count <= maximumTokenBytes, let tokens = wire.tokens, !tokens.isEmpty,
        tokens.count <= NearbyRendezvousPolicy.maximumPeers,
        tokens.keys.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
        tokens.values.allSatisfy({ !$0.isEmpty })
      else { throw NearbyRendezvousFailure.invalidToken }
      return .tokens(epoch: wire.epoch, tokens: tokens)
    case "ranging":
      guard let samples = wire.samples, !samples.isEmpty, samples.count <= maximumSamplesPerEnvelope
      else { throw NearbyRendezvousFailure.invalidSample }
      let decoded = try samples.map { try $0.sample() }
      return .ranging(epoch: wire.epoch, samples: decoded)
    default:
      throw NearbyRendezvousFailure.invalidToken
    }
  }

  private struct Wire: Codable {
    let v: Int
    let kind: String
    let epoch: UInt16
    let tokens: [String: Data]?
    let samples: [WireSample]?
  }

  private struct WireSample: Codable {
    let peerID: String
    let distance: Double
    let direction: [Double]?
    let pose: [Double]
    let observedAt: Double

    init(_ sample: NearbyRangingSample) {
      peerID = sample.peerID
      distance = sample.distanceMeters
      direction = sample.direction.map { [$0.x, $0.y, $0.z] }
      pose = sample.cameraPose.columnMajor
      observedAt = sample.observedAt.timeIntervalSince1970
    }

    func sample() throws -> NearbyRangingSample {
      guard let cameraPose = NearbyRigidPose(columnMajor: pose), observedAt.isFinite,
        !peerID.isEmpty, peerID.count <= 128
      else { throw NearbyRendezvousFailure.invalidSample }
      var vector: NearbyVector3?
      if let direction {
        guard direction.count == 3 else { throw NearbyRendezvousFailure.invalidSample }
        vector = NearbyVector3(x: direction[0], y: direction[1], z: direction[2])
      }
      let sample = NearbyRangingSample(peerID: peerID, distanceMeters: distance, direction: vector,
        cameraPose: cameraPose, observedAt: Date(timeIntervalSince1970: observedAt))
      guard sample.isValid else { throw NearbyRendezvousFailure.invalidSample }
      return sample
    }
  }
}

/// Targeting-side seam for the token/sample relay. The client-flow owner
/// adapts the combat socket to this protocol outside `Targeting/`; targeting
/// never touches the socket directly.
protocol NearbyRendezvousRelaying: Sendable {
  /// Existing worker lane: `ClientMessage {type:"niToken", token}`. Rare
  /// (only on session (re)build) — the worker rate limits it to ~1/s.
  func sendNearbyToken(_ token: String) async
  /// `ServerMessage {type:"niToken", playerId, token}`.
  func nearbyTokens() -> AsyncStream<(peerID: String, token: String)>
  /// Proposed lane (Integration handoff): `{type:"niRanging", data}` /
  /// `{type:"niRanging", playerId, data}` for encoded ranging envelopes.
  func sendNearbyRanging(_ data: Data) async
  func nearbyRanging() -> AsyncStream<(peerID: String, data: Data)>
}
