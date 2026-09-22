import Foundation

/// Player-facing descriptions derived from accepted state. These helpers never
/// change authority eligibility, cooldowns, damage, or projectile timing.
enum RealtimeArenaPresentation {
  struct ReferenceSetup: Equatable {
    let isVisible: Bool
    let captureAvailable: Bool

    init(stage: RealtimeArenaStage, isHost: Bool, usesSavedArena: Bool, usesQuickPlayFrame: Bool = false) {
      // Keep the next action in place while mapping quality changes. Visibility
      // is presentation only; actual capture still requires a usable live map.
      // Relocalized Quick Play shares the raw map and has no reference step.
      isVisible = isHost && !usesSavedArena && !usesQuickPlayFrame && [.mapping, .mapReady].contains(stage)
      captureAvailable = isVisible && stage == .mapReady
    }
  }

  /// Collaborative Quick Play (ADR 0011) has no host scan, share or timed
  /// relocalization: every phone maps continuously and links when peer data merges.
  struct CollaborativeSetup: Equatable {
    let title: String
    let guidance: String
    let showsProgress: Bool

    init(stage: RealtimeArenaStage, frameStage: DuelFrameStage, aligned: Int, total: Int) {
      if stage == .mapping || stage == .relocalizing || frameStage == .relocalizingWorld {
        title = "Linking play area"
        guidance = "Move toward the play area and look at the same floor and objects as the other players — the phones link automatically. Mapping keeps going while you play."
        showsProgress = true
        return
      }
      switch stage {
      case .awaitingMembers:
        title = "Aligned"
        guidance = "Aligned — waiting for players (\(aligned)/\(total)). Keep moving around; the shared map keeps growing."
        showsProgress = false
      case .paused where frameStage == .degraded:
        title = "Re-aligning"
        guidance = "Hold steady — re-aligning"
        showsProgress = true
      case .paused where frameStage == .lost:
        title = "Alignment lost"
        guidance = "Move toward the mapped play area and look at floor and fixed objects the other phones have seen."
        showsProgress = false
      default:
        title = stage.title
        guidance = "Joining the shared arena and synchronizing the match clock."
        showsProgress = stage == .connecting
      }
    }
  }

  static func showsScanControls(isHost: Bool, usesSavedArena: Bool, usesCollaborativeFrame: Bool,
    stage: RealtimeArenaStage, scanTimedOut: Bool) -> Bool
  {
    isHost && !usesSavedArena && !usesCollaborativeFrame && ([.mapping, .mapReady].contains(stage) || scanTimedOut)
  }

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
