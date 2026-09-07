import Foundation

enum MapLabFrameTracking: Equatable, Sendable {
  case normal, relocalizing, limited(MapLabFeedback), unavailable
}

struct MapLabFrameSample: Sendable {
  let timestamp: TimeInterval
  let capturedAt: TimeInterval
  let tracking: MapLabFrameTracking
  let usableMap: Bool
}

/// Offline recognition only. There is no combat readiness, world transform or
/// persistent success flag in this policy.
struct MapLabFramePolicy {
  enum Mode: Equatable { case capture, recognition }
  static let attemptSeconds: TimeInterval = 30
  static let maximumFrameAge: TimeInterval = 0.25
  private(set) var state: MapLabSessionState = .idle
  private(set) var generation: UInt64 = 0
  private var mode = Mode.capture
  private var deadline: TimeInterval?
  private var lastTimestamp: TimeInterval?
  private var lastCapturedAt: TimeInterval?
  private var sawRelocalizing = false

  mutating func begin(_ mode: Mode, at now: TimeInterval) -> UInt64 {
    generation &+= 1
    self.mode = mode
    deadline = now + Self.attemptSeconds
    lastTimestamp = nil; lastCapturedAt = nil; sawRelocalizing = false
    state = mode == .capture ? .scanning(feedback: .starting, canSave: false) : .recognizing
    return generation
  }

  mutating func receive(_ sample: MapLabFrameSample, generation token: UInt64, at now: TimeInterval) {
    guard token == generation, isActive else { return }
    tick(at: now)
    guard isActive, sample.timestamp.isFinite, sample.timestamp >= 0,
      sample.capturedAt.isFinite, now >= sample.capturedAt,
      now - sample.capturedAt <= Self.maximumFrameAge,
      lastTimestamp.map({ sample.timestamp > $0 }) ?? true else { return }
    lastTimestamp = sample.timestamp; lastCapturedAt = sample.capturedAt
    if mode == .capture {
      let ready = sample.tracking == .normal && sample.usableMap
      if ready { deadline = nil }
      else if deadline == nil { deadline = now + Self.attemptSeconds }
      let feedback: MapLabFeedback
      switch sample.tracking {
      case .normal: feedback = ready ? .ready : .mapping
      case .limited(let reason): feedback = reason
      case .relocalizing, .unavailable: feedback = .starting
      }
      state = .scanning(feedback: feedback, canSave: ready)
    } else {
      if sample.tracking == .relocalizing { sawRelocalizing = true }
      if sample.tracking == .normal, sawRelocalizing {
        state = .recognized; deadline = nil
      } else if state == .recognized {
        // After losing tracking, require a new recognition attempt rather than
        // treating a return to ordinary world tracking as another map match.
        interrupt()
      }
    }
  }

  mutating func tick(at now: TimeInterval) {
    guard isActive else { return }
    if let deadline, now >= deadline { state = .failed(.timedOut); return }
    if let lastCapturedAt, now - lastCapturedAt > Self.maximumFrameAge {
      if state == .recognized { interrupt() }
      else if case .scanning(_, true) = state {
        state = .scanning(feedback: .starting, canSave: false)
        deadline = now + Self.attemptSeconds
      }
    }
  }

  mutating func interrupt() { generation &+= 1; state = .interrupted; deadline = nil }
  mutating func stop() { generation &+= 1; state = .idle; deadline = nil; lastCapturedAt = nil }

  private var isActive: Bool {
    switch state { case .scanning, .recognizing, .recognized: true; default: false }
  }
}
