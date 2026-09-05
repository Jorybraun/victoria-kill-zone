import Foundation

enum RealtimeArenaStage: Equatable {
  case connecting, mapping, mapReady, waitingForMap, transferringMap, relocalizing
  case measuringReference, awaitingMembers, running, paused, reconnecting, respawning, finished, unavailable

  var title: String {
    switch self {
    case .connecting: "Connecting to match"
    case .mapping: "Scan the play area"
    case .mapReady: "Arena scan ready"
    case .waitingForMap: "Waiting for the host’s scan"
    case .transferringMap: "Sharing the arena"
    case .relocalizing: "Find the same area"
    case .measuringReference: "Align the arena"
    case .awaitingMembers: "Waiting for players to align"
    case .running: "Live match"
    case .paused: "Tracking paused"
    case .reconnecting: "Reconnecting"
    case .respawning: "Eliminated"
    case .finished: "Match complete"
    case .unavailable: "Arena unavailable"
    }
  }
}

struct RealtimeActionEligibility: Equatable {
  var fire = false
  var reload = false
  var shield = false
  var slowField = false
  var begin = false
  var reason = "Connecting"

  static func evaluate(snapshot: CombatWire.Snapshot?, localPlayerID: String, clockReady: Bool,
                       frameReady: Bool, sceneActive: Bool, canSubmit: Bool, poseFresh: Bool,
                       localFireAtMs: Double?, matchTimeMs: Double?) -> Self {
    guard let snapshot, let now = matchTimeMs, now.isFinite, let player = snapshot.players.first(where: {$0.playerId == localPlayerID}) else {return Self()}
    guard sceneActive, clockReady, canSubmit else {return Self(reason: "Synchronizing")}
    guard frameReady, poseFresh, player.connected, player.frameReady else {return Self(reason: "Align the arena")}
    if snapshot.phase == .calibrating || snapshot.phase == .paused {
      return Self(begin: snapshot.roundStartedAtMs == nil && player.role == "host"
        && snapshot.players.allSatisfy {$0.connected && $0.frameReady}, reason: "Waiting for players")
    }
    guard snapshot.phase == .running else {return Self(reason: "Match complete")}
    guard player.health > 0 else {return Self(reason: "Respawning")}
    guard (player.protectedUntilMs ?? 0) <= now else {return Self(reason: "Spawn protection")}
    let shielding = (player.shield.activeUntilMs ?? 0) > now
    let reloading = (player.reloadEndsAtMs ?? 0) > now
    let lastFire = max(player.lastFireAtMs ?? -.infinity, localFireAtMs ?? -.infinity)
    let cooldown = now - lastFire < snapshot.rules.weapon.cooldownMs
    return Self(fire: !shielding && !reloading && !cooldown && player.ammo > 0,
      reload: !shielding && !reloading && player.ammo < snapshot.rules.weapon.magazine,
      shield: shielding || (!reloading && player.shield.cooldownUntilMs <= now),
      slowField: player.slowFieldReadyAtMs <= now,
      reason: shielding ? "Shield raised" : reloading ? "Reloading" : player.ammo == 0 ? "Reload to continue" : cooldown ? "Recharging" : "Ready")
  }

  static func remainingRoundMs(snapshot: CombatWire.Snapshot?, now: Double?) -> Double? {
    guard let snapshot, let start = snapshot.roundStartedAtMs, let now, now.isFinite else {return nil}
    return max(0, snapshot.rules.durationMs - max(0, now - start))
  }
}
