import CryptoKit
import Foundation

struct DuelFrameReferenceSummary: Equatable, Sendable {
  let id: String
  let widthMeters: Double
  let heightMeters: Double
}

enum DuelFrameReferenceState: Equatable, Sendable {
  case unavailable, capturing, captured(DuelFrameReferenceSummary), failed(DuelFrameFailure)
}

/// A stationary natural scene feature, independently located by camera rays
/// intersecting observed plane geometry before the map is archived. This is not
/// a player marker and does not infer that future observations remain valid.
struct DuelFrameReference: Codable, Equatable, Sendable {
  static let maximumImageBytes = 1_048_576
  let id: String
  let imageData: Data
  let widthMeters: Double
  let heightMeters: Double
  let mapFromImage: [Double]
  let sampleCount: Int
  let maximumCornerDeviationMeters: Double

  var summary: DuelFrameReferenceSummary {
    DuelFrameReferenceSummary(id: id, widthMeters: widthMeters, heightMeters: heightMeters)
  }

  init(imageData: Data, widthMeters: Double, heightMeters: Double, mapFromImage: [Double],
    sampleCount: Int, maximumCornerDeviationMeters: Double) throws {
    self.id = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
    self.imageData = imageData
    self.widthMeters = widthMeters
    self.heightMeters = heightMeters
    self.mapFromImage = mapFromImage
    self.sampleCount = sampleCount
    self.maximumCornerDeviationMeters = maximumCornerDeviationMeters
    guard isValid else { throw DuelFrameFailure.referenceUnsuitable }
  }

  var isValid: Bool {
    !imageData.isEmpty && imageData.count <= Self.maximumImageBytes
      && id == SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
      && widthMeters.isFinite && heightMeters.isFinite
      && (0.25...2.5).contains(widthMeters) && (0.20...2.5).contains(heightMeters)
      && (0.3...3).contains(widthMeters / heightMeters)
      && (3...12).contains(sampleCount)
      && maximumCornerDeviationMeters.isFinite && (0...0.02).contains(maximumCornerDeviationMeters)
      && DuelFrameReferenceGeometry.isRigid(mapFromImage)
  }
}

struct DuelFrameReferenceObservation: Equatable, Sendable {
  let referenceID: String
  let mapFromImage: [Double]
  let isTracked: Bool
  let frameTimestamp: TimeInterval
  let capturedAt: Date
}

enum DuelFrameSensorTime {
  /// A queued delegate callback is older than the session's latest sensor
  /// frame. Subtract that backlog rather than timestamping receipt as capture.
  static func capturedAt(deliveredTimestamp: TimeInterval, latestTimestamp: TimeInterval, now: Date) -> Date? {
    guard deliveredTimestamp.isFinite, latestTimestamp.isFinite, deliveredTimestamp >= 0,
      latestTimestamp >= deliveredTimestamp else { return nil }
    let backlog = latestTimestamp - deliveredTimestamp
    guard backlog.isFinite else { return nil }
    return now.addingTimeInterval(-backlog)
  }
}

/// Anchor callbacks carry a sensor-frame timestamp but no trustworthy new wall
/// time. Resolve that timestamp only against a delivered camera frame; looking
/// up an old currentFrame must not make cached anchor evidence fresh again.
struct DuelFrameReferenceSensorEvent: Sendable {
  let referenceID: String
  let mapFromImage: [Double]
  let isTracked: Bool
  let frameTimestamp: TimeInterval

  func observation(cameraTimestamp: TimeInterval, cameraCapturedAt: Date) -> DuelFrameReferenceObservation? {
    let age = cameraTimestamp - frameTimestamp
    guard age.isFinite, age >= 0, age <= DuelFramePolicy.maximumSampleAge else { return nil }
    return DuelFrameReferenceObservation(referenceID: referenceID, mapFromImage: mapFromImage,
      isTracked: isTracked, frameTimestamp: frameTimestamp,
      capturedAt: cameraCapturedAt.addingTimeInterval(-age))
  }
}

/// Validates temporal identity separately from the shared-frame thresholds.
/// Identical transforms from new sensor frames are allowed; a cached sample is
/// never counted again or assigned a newer timestamp by this policy.
struct DuelFrameReferencePolicy: Sendable {
  private var lastTimestamp: TimeInterval?
  private var validatedReference: DuelFrameReference?

  mutating func measure(_ observation: DuelFrameReferenceObservation,
    expected: DuelFrameReference, now: Date) throws -> DuelFrameResidual? {
    // The provider constructs a new policy at each map installation. Cache the
    // immutable, fully validated descriptor once: hashing its image on every
    // 20 Hz observation would add avoidable work to the main actor.
    if validatedReference == nil {
      guard expected.isValid else { throw DuelFrameFailure.referenceUnavailable }
      validatedReference = expected
    }
    guard let reference = validatedReference, expected.id == reference.id,
      expected.mapFromImage == reference.mapFromImage,
      expected.widthMeters == reference.widthMeters, expected.heightMeters == reference.heightMeters,
      observation.referenceID == reference.id,
      observation.isTracked, observation.frameTimestamp.isFinite, observation.frameTimestamp >= 0,
      DuelFramePolicy.isFresh(observation.capturedAt, at: now),
      DuelFrameReferenceGeometry.isRigid(observation.mapFromImage)
    else { throw DuelFrameFailure.referenceUnavailable }
    if let lastTimestamp, observation.frameTimestamp <= lastTimestamp { return nil }
    lastTimestamp = observation.frameTimestamp
    let residual = try DuelFrameReferenceGeometry.residual(expected: reference.mapFromImage,
      observed: observation.mapFromImage)
    return DuelFrameResidual(translationMeters: residual.translationMeters,
      yawDegrees: residual.rotationDegrees, observedAt: observation.capturedAt)
  }
}

struct DuelFrameReferencePlane: Equatable, Sendable {
  let mapFromImage: [Double]
  let widthMeters: Double
  let heightMeters: Double
  let corners: [SIMD3<Double>]
}

enum DuelFrameReferenceGeometry {
  /// Corner order: image top-left, top-right, bottom-right, bottom-left. The
  /// ARImageAnchor plane is X/Z: +X image right, +Y outward, -Z image up.
  static func plane(corners p: [SIMD3<Double>], camera: SIMD3<Double>) throws -> DuelFrameReferencePlane {
    guard p.count == 4, p.allSatisfy(finite), finite(camera) else { throw DuelFrameFailure.referenceUnsuitable }
    let top = p[1] - p[0], bottom = p[2] - p[3], left = p[0] - p[3], right = p[1] - p[2]
    let width = (length(top) + length(bottom)) / 2, height = (length(left) + length(right)) / 2
    guard (0.25...2.5).contains(width), (0.20...2.5).contains(height),
      (0.3...3).contains(width / height),
      abs(length(top) - length(bottom)) <= width * 0.03,
      abs(length(left) - length(right)) <= height * 0.03,
      let x = unit(top + bottom), let rawUp = unit(left + right), abs(dot(x, rawUp)) < 0.035,
      let normal = unit(cross(x, rawUp)), let up = unit(cross(normal, x))
    else { throw DuelFrameFailure.referenceUnsuitable }
    let center = p.reduce(.zero, +) / 4
    guard let view = unit(camera - center), dot(normal, view) >= 0.85,
      p.allSatisfy({ abs(dot($0 - center, normal)) <= 0.01 }),
      p.allSatisfy({ (0.4...3.5).contains(length($0 - camera)) })
    else { throw DuelFrameFailure.referenceUnsuitable }
    let matrix = [x.x, x.y, x.z, 0, normal.x, normal.y, normal.z, 0,
      -up.x, -up.y, -up.z, 0, center.x, center.y, center.z, 1]
    guard isRigid(matrix) else { throw DuelFrameFailure.referenceUnsuitable }
    return DuelFrameReferencePlane(mapFromImage: matrix, widthMeters: width, heightMeters: height, corners: p)
  }

  static func maximumDeviation(_ samples: [DuelFrameReferencePlane]) throws -> Double {
    guard let first = samples.first, (3...12).contains(samples.count) else { throw DuelFrameFailure.referenceUnsuitable }
    var maximum = 0.0
    for sample in samples {
      guard sample.corners.count == 4 else { throw DuelFrameFailure.referenceUnsuitable }
      for index in 0..<4 { maximum = max(maximum, length(sample.corners[index] - first.corners[index])) }
    }
    guard maximum.isFinite, maximum <= 0.02 else { throw DuelFrameFailure.referenceUnsuitable }
    return maximum
  }

  static func residual(expected a: [Double], observed b: [Double]) throws -> (translationMeters: Double, rotationDegrees: Double) {
    guard isRigid(a), isRigid(b) else { throw DuelFrameFailure.invalidResidual }
    let translation = length(SIMD3(b[12] - a[12], b[13] - a[13], b[14] - a[14]))
    // Full rotation error is conservative: a small yaw cannot hide a large
    // pitch/roll disagreement. The existing yaw gate receives this upper bound.
    let trace = (0..<3).reduce(0.0) { sum, c in
      sum + (0..<3).reduce(0.0) { $0 + a[c * 4 + $1] * b[c * 4 + $1] }
    }
    return (translation, acos(min(1, max(-1, (trace - 1) / 2))) * 180 / .pi)
  }

  static func isRigid(_ m: [Double]) -> Bool {
    guard m.count == 16, m.allSatisfy(\.isFinite),
      [m[3], m[7], m[11]].allSatisfy({ abs($0) <= 0.00001 }), abs(m[15] - 1) <= 0.00001,
      [m[12], m[13], m[14]].allSatisfy({ abs($0) <= 1_000 }) else { return false }
    let x = SIMD3(m[0], m[1], m[2]), y = SIMD3(m[4], m[5], m[6]), z = SIMD3(m[8], m[9], m[10])
    return [x, y, z].allSatisfy({ abs(dot($0, $0) - 1) < 0.0001 })
      && abs(dot(x, y)) < 0.0001 && abs(dot(x, z)) < 0.0001 && abs(dot(y, z)) < 0.0001
      && dot(cross(x, y), z) > 0.9999
  }
  private static func finite(_ p: SIMD3<Double>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
  private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
  private static func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }
  private static func unit(_ a: SIMD3<Double>) -> SIMD3<Double>? {
    let l = length(a); return l.isFinite && l > 0.0001 ? a / l : nil
  }
  private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
  }
}

/// Bounded envelope inside the existing opaque authenticated map transfer. Old
/// raw AR archives remain readable; they carry no reference and cannot unlock.
enum DuelFrameCalibrationBundle {
  private static let magic = Data([86, 75, 90, 82, 69, 70, 49, 0]) // VKZREF1\0
  private static let maximumJSONBytes = 1_500_000

  static func encode(worldMap: Data, reference: DuelFrameReference) throws -> Data {
    guard !worldMap.isEmpty, reference.isValid else { throw DuelFrameFailure.invalidMap }
    let json = try JSONEncoder().encode(reference)
    guard json.count <= maximumJSONBytes, worldMap.count <= DuelFrameMap.maximumBytes,
      16 + json.count + worldMap.count <= DuelFrameMap.maximumBytes else { throw DuelFrameFailure.mapTooLarge }
    var data = magic
    for count in [json.count, worldMap.count] {
      var n = UInt32(count).littleEndian
      withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
    }
    data.append(json); data.append(worldMap)
    return data
  }

  static func decode(_ bytes: Data) throws -> (worldMap: Data, reference: DuelFrameReference?) {
    guard !bytes.isEmpty, bytes.count <= DuelFrameMap.maximumBytes else { throw DuelFrameFailure.invalidMap }
    guard bytes.starts(with: magic) else { return (bytes, nil) }
    guard bytes.count >= 16 else { throw DuelFrameFailure.invalidMap }
    let jsonCount = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
    let mapCount = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))) }
    guard (1...maximumJSONBytes).contains(jsonCount), mapCount > 0,
      jsonCount <= bytes.count - 16, mapCount == bytes.count - 16 - jsonCount else { throw DuelFrameFailure.invalidMap }
    let reference: DuelFrameReference
    do { reference = try JSONDecoder().decode(DuelFrameReference.self, from: bytes.subdata(in: 16..<(16 + jsonCount))) }
    catch { throw DuelFrameFailure.referenceUnsuitable }
    guard reference.isValid else { throw DuelFrameFailure.referenceUnsuitable }
    return (bytes.subdata(in: (16 + jsonCount)..<bytes.count), reference)
  }
}
