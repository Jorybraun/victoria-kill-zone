import Foundation

enum TargetingAvailability: Equatable, Sendable {
  case available
  case notConfigured
}

struct TargetingSnapshot: Equatable, Sendable {
  let bodyDetected: Bool
  let confidence: Double
  let observedAt: Date
}

protocol TargetingSession: Sendable {
  var availability: TargetingAvailability { get }

  func start() async throws
  func stop() async
}

enum TargetingSessionError: Error, Equatable, Sendable {
  case notConfigured
}

struct UnavailableTargetingSession: TargetingSession {
  let availability = TargetingAvailability.notConfigured

  func start() async throws {
    throw TargetingSessionError.notConfigured
  }

  func stop() async {}
}
