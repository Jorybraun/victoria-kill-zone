import {type CombatEvent, type CombatPlayerState, type HitZone, type ProjectileState, type Vec3} from "@vkz/combat-protocol";
import {add, distance, EPSILON, lerp, mul, normalized, sphereBoundaries, sweepCollider, sweepShield} from "./geometry.js";
import {colliderPairs, phoneAt, sampleBoundaries} from "./history.js";
import {clone, type SimulationCheckpoint} from "./state.js";

export interface FlightSegment {fromMs: number; toMs: number; start: Vec3; end: Vec3; scale: number; geometryFromMs?: number; geometryToMs?: number}
export interface FlightPath {projectile: ProjectileState; segments: FlightSegment[]; changes: CombatEvent[]; expires: boolean; endTimeMs: number}
interface Collision {projectileId: string; targetId: string; atMs: number; distance: number; position: Vec3; shield: boolean; zone: HitZone}
interface CollisionGeometry {
  pairs: ReturnType<typeof colliderPairs>;
  phones?: [ReturnType<typeof phoneAt>, ReturnType<typeof phoneAt>];
}
const MAX_COLLISION_GEOMETRIES = 128;

/** Exact interval keys; the cache exists only while collecting one resolution's candidates. */
function collisionGeometry(state: SimulationCheckpoint): (targetId: string, fromMs: number, toMs: number) => CollisionGeometry {
  const targets = new Map<string, Map<number, Map<number, CollisionGeometry>>>();
  let entries = 0;
  return (targetId, fromMs, toMs) => {
    const starts = targets.get(targetId), ends = starts?.get(fromMs);
    const cached = ends?.get(toMs);
    if (cached) return cached;
    const geometry: CollisionGeometry = {pairs: colliderPairs(state, targetId, fromMs, toMs)};
    // Preserve exact history selection on misses; excess intervals are never retained.
    if (entries < MAX_COLLISION_GEOMETRIES) {
      const targetStarts = starts ?? new Map<number, Map<number, CollisionGeometry>>();
      const intervalEnds = ends ?? new Map<number, CollisionGeometry>();
      intervalEnds.set(toMs, geometry); targetStarts.set(fromMs, intervalEnds); targets.set(targetId, targetStarts);
      entries++;
    }
    return geometry;
  };
}

export function timeScaleAt(state: SimulationCheckpoint, position: Vec3, direction: Vec3, atMs: number): number {
  const probe = add(position, mul(direction, 1e-7));
  return state.snapshot.slowFields.reduce((scale, f) => f.startsAtMs <= atMs + EPSILON && f.endsAtMs > atMs + EPSILON
    && distance(probe, f.center) < f.radius ? Math.min(scale, f.scale) : scale, 1);
}

/** Exact sphere-boundary and field-expiration splits preserve distance and time.
 * Slow time affects flight only; input, tracking, reload and cooldown clocks stay real.
 */
export function integrateFlight(state: SimulationCheckpoint, projectile: ProjectileState, fromMs: number, toMs: number): FlightPath {
  const p = clone(projectile), segments: FlightSegment[] = [], changes: CombatEvent[] = [];
  let time = fromMs;
  const end = Math.min(toMs, p.expiresAtMs);
  const sampleTimes = sampleBoundaries(state, fromMs, end);
  let budget = 256;
  while (time < end - EPSILON && p.distanceTravelled < state.snapshot.rules.weapon.rangeMeters - EPSILON) {
    if (--budget === 0) throw new Error("Flight subdivision bound exceeded");
    const scale = timeScaleAt(state, p.position, p.direction, time);
    if (Math.abs(scale - p.timeScale) > EPSILON) {
      p.timeScale = scale; p.segmentOrigin = p.position; p.segmentStartedAtMs = time;
      changes.push({kind: "projectileSegment", projectileId: p.projectileId, atMs: time, position: p.position, timeScale: scale});
    }
    const velocity = p.speed * scale / 1000;
    let dt = end - time;
    dt = Math.min(dt, (state.snapshot.rules.weapon.rangeMeters - p.distanceTravelled) / velocity);
    for (const boundary of sampleTimes) if (boundary > time + EPSILON) dt = Math.min(dt, boundary - time);
    for (const field of state.snapshot.slowFields) {
      for (const temporal of [field.startsAtMs, field.endsAtMs]) if (temporal > time + EPSILON) dt = Math.min(dt, temporal - time);
      if (field.startsAtMs > time + EPSILON || field.endsAtMs <= time + EPSILON) continue;
      for (const boundary of sphereBoundaries(p.position, p.direction, field.center, field.radius)) dt = Math.min(dt, boundary / velocity);
    }
    if (dt <= EPSILON) throw new Error("Flight failed to advance");
    const start = p.position;
    p.position = add(start, mul(p.direction, velocity * dt));
    segments.push({fromMs: time, toMs: time + dt, start, end: p.position, scale});
    p.distanceTravelled += velocity * dt;
    time += dt;
  }
  // A boundary landing exactly on a tick must publish the new segment now.
  const finalScale = timeScaleAt(state, p.position, p.direction, time);
  if (Math.abs(finalScale - p.timeScale) > EPSILON) {
    p.timeScale = finalScale; p.segmentOrigin = p.position; p.segmentStartedAtMs = time;
    changes.push({kind: "projectileSegment", projectileId: p.projectileId, atMs: time, position: p.position, timeScale: finalScale});
  }
  return {projectile: p, segments, changes, expires: time >= p.expiresAtMs - EPSILON || p.distanceTravelled >= state.snapshot.rules.weapon.rangeMeters - EPSILON, endTimeMs: time};
}

function collisions(state: SimulationCheckpoint, path: FlightPath, geometryAt: ReturnType<typeof collisionGeometry>): Collision[] {
  const candidates: Collision[] = [];
  for (const segment of path.segments) {
    const ga = segment.geometryFromMs ?? segment.fromMs, gb = segment.geometryToMs ?? segment.toMs;
    for (const target of state.snapshot.players) {
      if (target.playerId === path.projectile.shooterId || target.health <= 0) continue;
      const geometry = geometryAt(target.playerId, ga, gb), pairs = geometry.pairs;
      if (!pairs) throw new Error("Missing collision history");
      for (const [a, b] of pairs) {
        const u = sweepCollider(segment.start, segment.end, a, b, path.projectile.radius);
        if (u !== null) candidates.push({projectileId: path.projectile.projectileId, targetId: target.playerId,
          atMs: segment.fromMs + (segment.toMs - segment.fromMs) * u, distance: distance(segment.start, segment.end) * u,
          position: lerp(segment.start, segment.end, u), shield: false, zone: a.zone});
      }
      if (target.shield.activeUntilMs === null || target.shield.energy <= 0) continue;
      const [a, b] = geometry.phones ??= [phoneAt(state, target.playerId, ga), phoneAt(state, target.playerId, gb)];
      if (!a || !b) throw new Error("Missing shield history");
      const na = normalized(a.normal), nb = normalized(b.normal);
      if (!na || !nb) continue;
      const offset = state.snapshot.rules.shield.offsetMeters;
      const u = sweepShield(segment.start, segment.end, add(a.position, mul(na, offset)), add(b.position, mul(nb, offset)), na, nb,
        state.snapshot.rules.shield.radius, path.projectile.radius);
      if (u !== null) candidates.push({projectileId: path.projectile.projectileId, targetId: target.playerId,
        atMs: segment.fromMs + (segment.toMs - segment.fromMs) * u, distance: distance(segment.start, segment.end) * u,
        position: lerp(segment.start, segment.end, u), shield: true, zone: "torso"});
    }
  }
  return candidates;
}
export function terminal(p: ProjectileState, reason: "bodyHit" | "shieldBlocked" | "missExpired" | "cancelled", atMs: number, position: Vec3,
  targetPlayerId: string | null = null, zone: HitZone | null = null, damage = 0): CombatEvent {
  return {kind: "projectileTerminal", projectileId: p.projectileId, shotId: p.shotId, shooterId: p.shooterId, reason, atMs, position, targetPlayerId, zone, damage};
}
function changed(player: CombatPlayerState): CombatEvent { return {kind: "playerChanged", player: clone(player)}; }

/** Resolve all shots in global impact-time order, avoiding projectile-array bias
 * when earlier hits break a shield or kill the nearest target.
 */
export function resolveFlights(state: SimulationCheckpoint, paths: FlightPath[]): {events: CombatEvent[]; survivors: ProjectileState[]} {
  // Sweep helpers only read their geometry. All candidates are collected before
  // the impact loop mutates health/shields; nothing is cached across resolutions.
  const geometryAt = collisionGeometry(state);
  const all = paths.flatMap(path => collisions(state, path, geometryAt)).sort((a, b) => a.atMs - b.atMs || a.projectileId.localeCompare(b.projectileId)
    || a.distance - b.distance || Number(b.shield) - Number(a.shield) || a.targetId.localeCompare(b.targetId) || a.zone.localeCompare(b.zone));
  const impacts = new Map<string, Collision>(), effects = new Map<string, CombatEvent[]>();
  for (const hit of all) {
    if (impacts.has(hit.projectileId)) continue;
    const target = state.snapshot.players.find(p => p.playerId === hit.targetId)!;
    if (target.health <= 0 || (target.protectedUntilMs !== null && target.protectedUntilMs > hit.atMs)) continue;
    const path = paths.find(p => p.projectile.projectileId === hit.projectileId)!;
    const events: CombatEvent[] = [];
    if (hit.shield) {
      const until = target.shield.activeUntilMs;
      if (until === null || until <= hit.atMs || until - state.snapshot.rules.shield.durationMs > hit.atMs || target.shield.energy <= 0) continue;
      target.shield.energy = Math.max(0, target.shield.energy - state.snapshot.rules.weapon.damage.torso);
      if (target.shield.energy === 0) target.shield.activeUntilMs = null;
      events.push(terminal(path.projectile, "shieldBlocked", hit.atMs, hit.position, target.playerId), changed(target));
    } else {
      const damage = Math.min(target.health, state.snapshot.rules.weapon.damage[hit.zone]);
      target.health -= damage;
      if (target.health === 0) {
        target.deaths++; target.reloadEndsAtMs = null; target.shield.activeUntilMs = null;
        target.respawnAtMs = hit.atMs + state.snapshot.rules.respawnMs;
        const shooter = state.snapshot.players.find(p => p.playerId === path.projectile.shooterId)!;
        shooter.kills++; events.push(changed(shooter));
      }
      events.push(terminal(path.projectile, "bodyHit", hit.atMs, hit.position, target.playerId, hit.zone, damage), changed(target));
    }
    impacts.set(hit.projectileId, hit); effects.set(hit.projectileId, events);
  }
  const output: {atMs: number; order: number; id: string; event: CombatEvent}[] = [], survivors: ProjectileState[] = [];
  for (const path of paths) {
    const hit = impacts.get(path.projectile.projectileId);
    for (const event of path.changes) {
      if (event.kind === "projectileSegment" && (!hit || event.atMs <= hit.atMs)) output.push({atMs: event.atMs, order: 0, id: path.projectile.projectileId, event});
    }
    if (hit) (effects.get(path.projectile.projectileId) ?? []).forEach((event, order) => output.push({atMs: hit.atMs, order: order + 1, id: path.projectile.projectileId, event}));
    else if (path.expires) output.push({atMs: path.endTimeMs, order: 1, id: path.projectile.projectileId, event: terminal(path.projectile, "missExpired", path.endTimeMs, path.projectile.position)});
    else survivors.push(path.projectile);
  }
  output.sort((a, b) => a.atMs - b.atMs || a.id.localeCompare(b.id) || a.order - b.order);
  return {events: output.map(x => x.event), survivors};
}
