import {type BodyObservation, type CombatEvent, type CombatPlayerState, type HitZone, type ProjectileState, type Vec3} from "@vkz/combat-protocol";
import {add, distance, EPSILON, lerp, mul, sweepCollider} from "./geometry.js";
import {clone, type SimulationCheckpoint} from "./state.js";

export function timeScaleAt(state: SimulationCheckpoint, position: Vec3, direction: Vec3, atMs: number): number {
  const probe = add(position, mul(direction, 1e-7));
  return state.snapshot.slowFields.reduce((scale, f) => f.startsAtMs <= atMs + EPSILON && f.endsAtMs > atMs + EPSILON
    && distance(probe, f.center) < f.radius ? Math.min(scale, f.scale) : scale, 1);
}

export function terminal(p: ProjectileState, reason: "bodyHit" | "shieldBlocked" | "missExpired" | "cancelled", atMs: number, position: Vec3,
  targetPlayerId: string | null = null, zone: HitZone | null = null, damage = 0): CombatEvent {
  return {kind: "projectileTerminal", projectileId: p.projectileId, shotId: p.shotId, shooterId: p.shooterId, reason, atMs, position, targetPlayerId, zone, damage};
}
function changed(player: CombatPlayerState): CombatEvent { return {kind: "playerChanged", player: clone(player)}; }

function applyShieldBlock(state: SimulationCheckpoint, projectile: ProjectileState, atMs: number, position: Vec3,
  target: CombatPlayerState): CombatEvent[] {
  target.shield.energy = Math.max(0, target.shield.energy - state.snapshot.rules.weapon.damage.torso);
  if (target.shield.energy === 0) target.shield.activeUntilMs = null;
  return [terminal(projectile, "shieldBlocked", atMs, position, target.playerId), changed(target)];
}
function applyBodyHit(state: SimulationCheckpoint, projectile: ProjectileState, atMs: number, position: Vec3,
  target: CombatPlayerState, zone: HitZone): CombatEvent[] {
  const damage = Math.min(target.health, state.snapshot.rules.weapon.damage[zone]);
  target.health -= damage;
  const events: CombatEvent[] = [];
  if (target.health === 0) {
    target.deaths++; target.reloadEndsAtMs = null; target.shield.activeUntilMs = null;
    target.respawnAtMs = atMs + state.snapshot.rules.respawnMs;
    const shooter = state.snapshot.players.find(p => p.playerId === projectile.shooterId)!;
    shooter.kills++; events.push(changed(shooter));
  }
  events.push(terminal(projectile, "bodyHit", atMs, position, target.playerId, zone, damage), changed(target));
  return events;
}

/** ADR 0013: a sighting verdict is the shooter's own observation, resolved
 * instantly in the shooter's camera space with no shared frame or rewind.
 */
export function resolveSighting(state: SimulationCheckpoint, projectile: ProjectileState, target: CombatPlayerState,
  observation: BodyObservation, atMs: number): CombatEvent[] {
  const start = projectile.position;
  const end = add(start, mul(projectile.direction, state.snapshot.rules.weapon.rangeMeters));
  let best: {u: number; zone: HitZone} | null = null;
  for (const collider of observation.colliders) {
    const u = sweepCollider(start, end, collider, collider, projectile.radius);
    if (u !== null && (best === null || u < best.u)) best = {u, zone: collider.zone};
  }
  if (best === null || target.health <= 0 || (target.protectedUntilMs !== null && target.protectedUntilMs > atMs))
    return [terminal(projectile, "missExpired", atMs, end)];
  const position = lerp(start, end, best.u);
  const until = target.shield.activeUntilMs;
  if (until !== null && until > atMs && until - state.snapshot.rules.shield.durationMs <= atMs && target.shield.energy > 0)
    return applyShieldBlock(state, projectile, atMs, position, target);
  return applyBodyHit(state, projectile, atMs, position, target, best.zone);
}
