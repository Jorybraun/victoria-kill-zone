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

  static func pauseGuidance(clockReady: Bool, roundHasStarted: Bool) -> String {
    if !clockReady {
      return "Synchronizing match timing. Keep this screen open; controls return when the connection is stable."
    }
    if roundHasStarted {
      return "Keep the shared play area, players and their phones in view. The match resumes automatically when everyone's tracking recovers."
    }
    return "Point at the shared play area to recover alignment. The host can begin once all players are ready."
  }
}
