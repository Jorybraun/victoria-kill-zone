import Foundation

/// Player-facing descriptions derived from accepted state. These helpers never
/// change authority eligibility, cooldowns, damage, or projectile timing.
enum RealtimeArenaPresentation {
  enum AbilityStatus: Equatable {
    case active(seconds: Int)
    case cooldown(seconds: Int)
    case ready

    var detail: String {
      switch self {
      case .active(let seconds): "Active · \(seconds)s"
      case .cooldown(let seconds): "Ready in \(seconds)s"
      case .ready: "Ready"
      }
    }
  }

  static func weaponName(_ identifier: String?) -> String {
    switch identifier {
    case "pulse", "pulse-8": "Pulse blaster"
    case "sidearm": "Sidearm"
    case "match-rifle": "Match rifle"
    default: "Arena blaster"
    }
  }

  static func secondsRemaining(until end: Double?, at now: Double) -> Int {
    guard let end, end.isFinite, now.isFinite else {return 0}
    let remaining = ceil(max(0, end - now) / 1000)
    return Int(min(remaining, Double(Int32.max)))
  }

  static func slowFieldStatus(fields: [CombatWire.SlowField], localPlayerID: String,
    readyAt: Double, now: Double) -> AbilityStatus
  {
    guard now.isFinite else {return .ready}
    if let end = fields.filter({
      $0.ownerId == localPlayerID && $0.startsAtMs <= now && $0.endsAtMs > now
    }).map(\.endsAtMs).max() {
      return .active(seconds: secondsRemaining(until: end, at: now))
    }
    let wait = secondsRemaining(until: readyAt, at: now)
    return wait > 0 ? .cooldown(seconds: wait) : .ready
  }

  static func protectionDetail(until end: Double?, now: Double) -> String? {
    let remaining = secondsRemaining(until: end, at: now)
    return remaining > 0 ? "Spawn protection · \(remaining)s" : nil
  }

  static func reloadProgress(until end: Double, duration: Double, now: Double) -> Double {
    guard end.isFinite, duration.isFinite, duration > 0, now.isFinite else {return 0}
    return min(1, max(0, 1 - (end - now) / duration))
  }

  /// Copy for ADR 0013 sighting (Quick Duel): no shared frame exists, so nothing here may mention alignment/scanning.
  enum Sighting {
    static func title(stage: RealtimeArenaStage, clockReady: Bool) -> String {
      switch stage {
      case .connecting: "Connecting to match"
      case .awaitingMembers: "Waiting for opponent"
      case .running: "Live match"
      case .paused: clockReady ? "Camera paused" : "Stabilizing connection"
      case .reconnecting: "Reconnecting"
      case .respawning: "Eliminated"
      case .finished: "Match complete"
      case .unavailable: "Body tracking unavailable"
      }
    }

    static func guidance(stage: RealtimeArenaStage, clockReady: Bool, roundHasStarted: Bool) -> String {
      switch stage {
      case .awaitingMembers:
        return "Waiting for opponent"
      case .paused:
        if !clockReady {
          return "Rechecking match timing. Controls return automatically when the connection is stable."
        }
        if roundHasStarted {
          return "Keep your opponent in view. The match resumes automatically when camera tracking recovers."
        }
        return "Point your camera at your opponent. The host can start once both players are ready."
      case .running:
        return ""
      case .reconnecting:
        return "Your score is retained. Reconnecting before input resumes."
      case .respawning:
        return "Health and ammunition restore automatically. You can keep looking and moving."
      case .unavailable:
        return "Body tracking is unavailable on this device or configuration."
      default:
        return "Connecting to the match."
      }
    }

    static func rosterStatus(connected: Bool, health: Int) -> String {
      if !connected { return "Disconnected" }
      if health == 0 { return "Respawning" }
      return "\(health) health"
    }

    static func rosterAccessibilityStatus(connected: Bool) -> String {
      connected ? "connected" : "disconnected"
    }

    static let startTitle = "PLAY"
    /// The lobby promised Quick Duel but the authority spoke pre-ADR 0013
    /// rules — nothing to retry, the match itself is the wrong kind.
    static let incompatibleServerMessage =
      "This match was created by an outdated combat server. Leave and start a new Quick Duel."
    static let retryTrackingTitle = "Retry camera"
    static let allStages: [RealtimeArenaStage] = [
      .connecting, .awaitingMembers, .running, .paused, .reconnecting, .respawning, .finished, .unavailable,
    ]
  }
}
