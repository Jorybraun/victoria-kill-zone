import Foundation

/// Local presentation reservations. Authority results alone change game state.
/// IDs survive transient reconnects until a snapshot or result reconciles them.
struct RealtimeCommandState {
  enum Action {case start, fire, reload, shield, slowField}
  private struct Pending {
    let action: Action
    let order: Int
    let shotID: String?
    var spawnedAtMs: Double?
    var ammoReflected = false
  }
  private var pending: [String: Pending] = [:]
  private var order = 0
  private var noticeOrder = 0
  private var noticeExpiresAt = Date.distantPast
  private(set) var notice: String?

  func contains(_ action: Action) -> Bool {pending.values.contains {$0.action == action}}
  func availableAmmo(_ authoritativeAmmo: Int) -> Int {
    max(0, authoritativeAmmo - pending.values.filter {$0.action == .fire && !$0.ammoReflected}.count)
  }
  mutating func queued(_ action: Action, id: String, shotID: String? = nil) {
    guard pending[id] == nil, pending.count < 32 else {return}
    order += 1
    pending[id] = Pending(action: action, order: order, shotID: shotID)
  }
  mutating func projectileSpawned(shotID: String, atMs: Double) {
    guard atMs.isFinite else {return}
    for id in pending.keys where pending[id]?.shotID == shotID {pending[id]?.spawnedAtMs = atMs}
  }
  mutating func playerChanged(lastFireAtMs: Double?) {
    // A spawn precedes its playerChanged event, but transport batches can split
    // them. Release ammo reservation only once that accepted player state arrives.
    for id in pending.keys {
      guard let spawn = pending[id]?.spawnedAtMs else {continue}
      if lastFireAtMs == nil || spawn <= lastFireAtMs! {pending[id]?.ammoReflected = true}
    }
  }
  mutating func resolve(id: String, accepted: Bool, reason: String?, at now: Date) {
    guard let command = pending.removeValue(forKey: id) else {return}
    guard !accepted, command.order >= noticeOrder else {return}
    noticeOrder = command.order
    notice = Self.explanation(for: reason, action: command.action)
    noticeExpiresAt = now.addingTimeInterval(4)
  }
  mutating func reconcile(pendingIDs: Set<String>) {
    pending = pending.filter {pendingIDs.contains($0.key)}
  }
  mutating func tick(at now: Date) {
    if now >= noticeExpiresAt {notice = nil}
  }

  private static func explanation(for reason: String?, action: Action) -> String {
    switch reason {
    case "notReady" where action == .start:
      "Keep every player and their phone visible, then try Begin match again."
    case "notReady", "trackingLost", "poseStale", "poseMismatch":
      "Tracking needs a fresh view of players and the arena reference."
    case "notAlive": "You can act again after respawning."
    case "protected": "Wait for spawn protection to end."
    case "cooldown": "The weapon is recharging."
    case "reloading": "Wait for the reload to finish."
    case "outOfAmmo": "Your magazine is empty. Reload to continue."
    case "shieldActive": "Lower your shield before firing."
    case "abilityCooldown": "That ability is recharging."
    case "projectileLimit": "Too many shots are in flight. Try again shortly."
    case "tooLate", "futureInput": "The action arrived outside the timing window. Try again."
    case "notHost": "Only the host can begin the match."
    case "notRunning": "The match must be running before you can act."
    default: "The action was not accepted. Try again when the arena is ready."
    }
  }
}

/// Queuing readiness is not acknowledgement. Retry a rejected transition at a
/// bounded cadence until the authoritative player state agrees with the sensor.
struct RealtimeReadinessState {
  private var pendingID: String?
  private var pendingReady: Bool?
  private var sentAt = Date.distantPast

  func shouldSubmit(ready: Bool, authoritative: Bool, at now: Date) -> Bool {
    if let pendingReady, pendingReady != ready {return true}
    guard ready != authoritative else {return false}
    let age = now.timeIntervalSince(sentAt)
    return age >= (pendingID == nil ? 0.25 : 1)
  }
  mutating func queued(id: String, ready: Bool, at now: Date) {
    pendingID = id; pendingReady = ready; sentAt = now
  }
  mutating func resolve(id: String) {
    guard pendingID == id else {return}
    pendingID = nil; pendingReady = nil
  }
}
