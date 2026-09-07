import Foundation

/// Version-one DEBUG experiment payload carried by the bounded local peer link.
/// No combat permission, body geometry, measured accuracy or saved-map claim.
struct SharedOriginWireMessage: Codable, Equatable, Sendable {
  static let maximumBytes = 4_096
  let version: Int
  let runID: UUID
  let epoch: UInt64
  let body: Body

  enum Body: Codable, Equatable, Sendable {
    case hello(sessionID: UUID, role: ArenaRole)
    case origin(originID: UUID)
    case pose(originID: UUID, sequence: UInt64, capturedUptimeMs: Double,
      sourceAgeMs: Double, trackingNormal: Bool, arenaFromPhone: [Double])
  }

  init(runID: UUID, epoch: UInt64, body: Body) {
    version = 1; self.runID = runID; self.epoch = epoch; self.body = body
  }

  func encoded() throws -> Data {
    try validate()
    let data = try JSONEncoder().encode(self)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {throw SharedOriginFailure.invalidMessage}
    return data
  }

  static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maximumBytes else {throw SharedOriginFailure.invalidMessage}
    let message: Self
    do {message = try JSONDecoder().decode(Self.self, from: data)}
    catch {throw SharedOriginFailure.invalidMessage}
    try message.validate()
    return message
  }

  private func validate() throws {
    guard version == 1, epoch > 0 else {throw SharedOriginFailure.invalidMessage}
    if case .pose(_, let sequence, let captured, let age, _, let matrix) = body {
      guard sequence > 0, captured.isFinite, captured >= 0, age.isFinite, age >= 0,
        age <= SharedOriginPolicy.maximumSampleAgeMs else {throw SharedOriginFailure.invalidMessage}
      do {_ = try ArenaRigidTransform(columnMajor: matrix)}
      catch {throw SharedOriginFailure.invalidMessage}
    }
  }
}

enum SharedOriginFailure: Error, Equatable, Sendable {
  case invalidCode, invalidEpoch, invalidMessage, invalidTransform
}
