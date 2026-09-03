import Foundation

// MARK: - Shared Arena Frame vocabulary (KIL-20)
//
// Platform-neutral value types for the two-phone shared-arena proof. Nothing in
// this file touches ARKit or the network; those adapters translate into these
// types so the lock policy, metrics, and codecs stay deterministic and testable
// on macOS under `swift test`.

/// Which frame-alignment method a harness run is exercising. The research
/// (docs/research/shared-arena-frame-options.md) names collaboration as primary
/// and the one-shot world map as fallback and control condition.
enum ArenaFrameMethod: String, CaseIterable, Codable, Sendable {
  case collaborative
  case worldMap
}

enum ArenaRole: String, Codable, Sendable {
  case host
  case guest
}

/// Mirrors `ARFrame.WorldMappingStatus` without importing ARKit.
enum ArenaMappingStatus: String, CaseIterable, Codable, Sendable {
  case notAvailable
  case limited
  case extending
  case mapped
}

/// Mirrors `ARCamera.TrackingState` without importing ARKit. Anything that is
/// not `.normal` is treated as lost by the lock policy — there is no partial
/// credit for limited tracking.
enum ArenaLocalTracking: Equatable, Sendable {
  case notAvailable
  case limited(ArenaLimitedReason)
  case normal

  var quality: ArenaTrackingQuality { self == .normal ? .normal : .lost }

  var label: String {
    switch self {
    case .notAvailable: "notAvailable"
    case .limited(let reason): "limited:\(reason.rawValue)"
    case .normal: "normal"
    }
  }
}

enum ArenaLimitedReason: String, Codable, Sendable {
  case initializing
  case excessiveMotion
  case insufficientFeatures
  case relocalizing
}

/// One phone's self-reported pose in the shared arena frame, as exchanged over
/// the peer channel. `timestampMs` is the sender's monotonic clock and
/// `sequence` is per sender; both must be strictly increasing.
struct ArenaPeerSample: Equatable, Sendable {
  let playerId: String
  let sequence: Int64
  let timestampMs: Int64
  let tracking: ArenaTrackingQuality
  let arenaFromPhone: ArenaRigidTransform

  var poseSample: ArenaPoseSample {
    ArenaPoseSample(
      sequence: sequence,
      timestampMs: timestampMs,
      tracking: tracking,
      arenaFromPhone: arenaFromPhone
    )
  }
}

enum ArenaPeerSampleCodecError: Error, Equatable, Sendable {
  case truncated
  case trailingBytes
  case invalidPlayerId
  case invalidTracking
  case nonPositiveSequence
  case nonPositiveTimestamp
  case invalidTransform(ArenaPrototypeError)
}

/// Fixed little-endian layout so both phones agree byte-for-byte regardless of
/// Swift `Codable` defaults. The rotation is carried as three column vectors and
/// the translation as a fourth; all as `Double` so the receiver can re-validate
/// orthonormality at the same tolerance the sender used.
enum ArenaPeerSampleCodec {
  static let maxPlayerIdBytes = 64

  static func encode(_ sample: ArenaPeerSample) throws -> Data {
    let playerIdBytes = Array(sample.playerId.utf8)
    guard !playerIdBytes.isEmpty, playerIdBytes.count <= maxPlayerIdBytes else {
      throw ArenaPeerSampleCodecError.invalidPlayerId
    }
    guard sample.sequence > 0 else { throw ArenaPeerSampleCodecError.nonPositiveSequence }
    guard sample.timestampMs > 0 else { throw ArenaPeerSampleCodecError.nonPositiveTimestamp }

    var data = Data()
    data.append(UInt8(playerIdBytes.count))
    data.append(contentsOf: playerIdBytes)
    appendLittleEndian(sample.sequence, to: &data)
    appendLittleEndian(sample.timestampMs, to: &data)
    data.append(sample.tracking == .normal ? 0 : 1)
    let m = sample.arenaFromPhone.columnMajor
    for index in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14] {
      appendLittleEndian(m[index].bitPattern, to: &data)
    }
    return data
  }

  static func decode(_ data: Data) throws -> ArenaPeerSample {
    var cursor = ByteCursor(data: data)
    let idLength = Int(try cursor.readUInt8())
    guard idLength > 0, idLength <= maxPlayerIdBytes else {
      throw ArenaPeerSampleCodecError.invalidPlayerId
    }
    let idBytes = try cursor.read(count: idLength)
    guard let playerId = String(bytes: idBytes, encoding: .utf8) else {
      throw ArenaPeerSampleCodecError.invalidPlayerId
    }
    let sequence = Int64(bitPattern: try cursor.readUInt64())
    let timestampMs = Int64(bitPattern: try cursor.readUInt64())
    guard sequence > 0 else { throw ArenaPeerSampleCodecError.nonPositiveSequence }
    guard timestampMs > 0 else { throw ArenaPeerSampleCodecError.nonPositiveTimestamp }
    let trackingByte = try cursor.readUInt8()
    let tracking: ArenaTrackingQuality
    switch trackingByte {
    case 0: tracking = .normal
    case 1: tracking = .lost
    default: throw ArenaPeerSampleCodecError.invalidTracking
    }

    var storage = ArenaRigidTransform.identityStorage
    for index in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14] {
      storage[index] = Double(bitPattern: try cursor.readUInt64())
    }
    guard cursor.isAtEnd else { throw ArenaPeerSampleCodecError.trailingBytes }

    let transform: ArenaRigidTransform
    do {
      transform = try ArenaRigidTransform(columnMajor: storage)
    } catch let error as ArenaPrototypeError {
      throw ArenaPeerSampleCodecError.invalidTransform(error)
    }
    return ArenaPeerSample(
      playerId: playerId,
      sequence: sequence,
      timestampMs: timestampMs,
      tracking: tracking,
      arenaFromPhone: transform
    )
  }

  private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
}

struct ByteCursor {
  private let data: Data
  private var offset: Int

  init(data: Data) {
    self.data = data
    offset = data.startIndex
  }

  var isAtEnd: Bool { offset == data.endIndex }

  mutating func read(count: Int) throws -> Data {
    guard count >= 0, data.endIndex - offset >= count else {
      throw ArenaPeerSampleCodecError.truncated
    }
    let slice = data[offset..<offset + count]
    offset += count
    return Data(slice)
  }

  mutating func readUInt8() throws -> UInt8 {
    try read(count: 1).first!
  }

  mutating func readUInt32() throws -> UInt32 {
    let bytes = try read(count: 4)
    return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
  }

  mutating func readUInt64() throws -> UInt64 {
    let bytes = try read(count: 8)
    return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
  }
}

// MARK: - Rigid transform helpers for sensor-derived matrices

extension ArenaRigidTransform {
  static let identity = try! ArenaRigidTransform(columnMajor: identityStorage)

  /// ARKit hands back `simd_float4x4` camera/anchor transforms whose rotation
  /// blocks are only orthonormal to single precision — well outside the 1e-6
  /// tolerance the strict initializer demands. Re-orthonormalize (Gram–Schmidt
  /// in double precision) before validating, so a genuinely rigid sensor pose
  /// is accepted while scaled, sheared, or reflected inputs are still rejected.
  static func rigidApproximation(columnMajor input: [Double]) throws -> ArenaRigidTransform {
    guard input.count == 16, input.allSatisfy(\.isFinite) else {
      throw ArenaPrototypeError.nonFinite
    }
    let x = ArenaVector3(x: input[0], y: input[1], z: input[2])
    let yRaw = ArenaVector3(x: input[4], y: input[5], z: input[6])
    let zRaw = ArenaVector3(x: input[8], y: input[9], z: input[10])

    // Reject anything that is not close to unit scale / orthogonal before
    // "repairing" it: a 10% scale or shear is a bug, not float noise.
    let scaleTolerance = 1e-3
    guard abs(x.length - 1) <= scaleTolerance,
      abs(yRaw.length - 1) <= scaleTolerance,
      abs(zRaw.length - 1) <= scaleTolerance,
      abs(x.dot(yRaw)) <= scaleTolerance,
      abs(x.dot(zRaw)) <= scaleTolerance,
      abs(yRaw.dot(zRaw)) <= scaleTolerance
    else {
      throw ArenaPrototypeError.nonOrthonormalTransform
    }
    guard x.dot(yRaw.cross(zRaw)) > 0 else {
      throw ArenaPrototypeError.nonOrthonormalTransform
    }

    let xUnit = try x.normalized()
    let yUnit = try (yRaw - xUnit * yRaw.dot(xUnit)).normalized()
    let zUnit = xUnit.cross(yUnit)

    var storage = identityStorage
    storage[0] = xUnit.x
    storage[1] = xUnit.y
    storage[2] = xUnit.z
    storage[4] = yUnit.x
    storage[5] = yUnit.y
    storage[6] = yUnit.z
    storage[8] = zUnit.x
    storage[9] = zUnit.y
    storage[10] = zUnit.z
    storage[12] = input[12]
    storage[13] = input[13]
    storage[14] = input[14]
    return try ArenaRigidTransform(columnMajor: storage)
  }

  /// Right-handed rotation about the gravity (+Y) axis in degrees, in
  /// (-180, 180]. ARKit world frames are gravity-aligned, so yaw is the only
  /// rotational degree of freedom two phones can disagree about.
  var yawDegrees: Double {
    // Forward for a camera is -Z; project the transformed -Z onto the XZ plane.
    let forward = applying(toDirection: ArenaVector3(x: 0, y: 0, z: -1))
    return atan2(-forward.x, -forward.z) * 180 / .pi
  }

  /// Residual between where the peer says it is (self-reported) and where this
  /// phone observes it (e.g. an `ARParticipantAnchor`). Translation in metres,
  /// yaw in degrees, both non-negative.
  static func residual(
    reported: ArenaRigidTransform,
    observed: ArenaRigidTransform
  ) -> ArenaAlignmentResidual {
    let translation = (reported.translation - observed.translation).length
    var yaw = abs(reported.yawDegrees - observed.yawDegrees)
    if yaw > 180 { yaw = 360 - yaw }
    return ArenaAlignmentResidual(translationMeters: translation, yawDegrees: yaw)
  }
}

struct ArenaAlignmentResidual: Equatable, Sendable {
  let translationMeters: Double
  let yawDegrees: Double
}
