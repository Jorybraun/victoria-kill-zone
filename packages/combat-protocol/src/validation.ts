import {LIMITS, type ClientMessage, type CombatCommand, type CombatRules, type CombatTicketClaims, type Member, type CombatPlayerState, type CombatProjection, type CombatEvent} from "./index.js";

type ObjectValue = Record<string, unknown>;
const record = (x: unknown): x is ObjectValue => typeof x === "object" && x !== null && !Array.isArray(x);
const keys = (x: ObjectValue, expected: string): boolean => {
  const names = expected.split(" ");
  return Object.keys(x).length === names.length && names.every(name => Object.hasOwn(x, name));
};
const number = (x: unknown, min: number, max: number): x is number =>
  typeof x === "number" && Number.isFinite(x) && x >= min && x <= max;
const integer = (x: unknown, min = 0, max = Number.MAX_SAFE_INTEGER): x is number => number(x, min, max) && Number.isSafeInteger(x);
const id = (x: unknown): x is string => typeof x === "string" && /^[A-Za-z0-9_:\-]{1,128}$/.test(x);
const time = (x: unknown): x is number => number(x, 0, Number.MAX_SAFE_INTEGER);
const vector = (x: unknown): x is [number, number, number] =>
  Array.isArray(x) && x.length === 3 && x.every(n => number(n, -1000, 1000));
const unit = (x: unknown, length: number): boolean => Array.isArray(x) && x.length === length &&
  x.every(n => number(n, -1.001, 1.001)) && Math.abs(x.reduce((sum: number, n: number) => sum + n*n, 0) - 1) <= 0.02;
const zone = (x: unknown): boolean => x === "head" || x === "torso" || x === "limbs";

function collider(x: unknown): boolean {
  if (!record(x) || !id(x.id) || !zone(x.zone) || !number(x.radius, 0.005, 0.75)) return false;
  return x.kind === "sphere"
    ? keys(x, "id kind zone center radius") && vector(x.center)
    : x.kind === "capsule" && keys(x, "id kind zone a b radius") && vector(x.a) && vector(x.b);
}

function observations(x: unknown): boolean {
  if (!Array.isArray(x) || x.length > LIMITS.players - 1) return false;
  const targets = new Set<unknown>();
  for (const item of x) {
    if (!record(item) || !keys(item, "targetPlayerId capturedAtMs associationConfidence uncertaintyMeters colliders") ||
      !id(item.targetPlayerId) || targets.has(item.targetPlayerId) || !time(item.capturedAtMs) ||
      !number(item.associationConfidence, 0, 1) || !number(item.uncertaintyMeters, 0, 10) ||
      !Array.isArray(item.colliders) || item.colliders.length < 1 || item.colliders.length > 32 ||
      !item.colliders.every(collider) || new Set(item.colliders.map(c => (c as ObjectValue).id)).size !== item.colliders.length) return false;
    targets.add(item.targetPlayerId);
  }
  return true;
}

function command(x: unknown): x is CombatCommand {
  if (!record(x)) return false;
  switch (x.kind) {
    case "start": case "reload": case "leave": return keys(x, "kind");
    case "pose": {
      const p = x.pose;
      return keys(x, "kind pose observations") && record(p) && keys(p, "sequence capturedAtMs position orientation tracking") &&
        integer(p.sequence) && time(p.capturedAtMs) && vector(p.position) && unit(p.orientation, 4) &&
        ["normal", "limited", "lost"].includes(String(p.tracking)) && observations(x.observations);
    }
    case "frameReady": return keys(x, "kind ready residualMeters residualDegrees clockUncertaintyMs") &&
      typeof x.ready === "boolean" && number(x.residualMeters, 0, 1000) && number(x.residualDegrees, 0, 180) && number(x.clockUncertaintyMs, 0, 60_000);
    case "fire": return keys(x, "kind shotId poseSequence origin direction") && id(x.shotId) && integer(x.poseSequence) && vector(x.origin) && unit(x.direction, 3);
    case "shield": return keys(x, "kind active poseSequence") && typeof x.active === "boolean" && integer(x.poseSequence);
    case "slowField": return keys(x, "kind poseSequence") && integer(x.poseSequence);
    default: return false;
  }
}

/** Reject malformed, oversized and identity-bearing client input before queueing. */
export function parseClientMessage(raw: string): ClientMessage | null {
  if (raw.length > LIMITS.messageBytes || new TextEncoder().encode(raw).length > LIMITS.messageBytes) return null;
  let x: unknown;
  try { x = JSON.parse(raw); } catch { return null; }
  if (!record(x)) return null;
  if (x.type === "command") {
    const e = x.envelope;
    if (!keys(x, "type envelope") || !record(e) || !keys(e, "v commandId clientSequence authorityEpoch frameEpoch sentAtMs command") ||
      e.v !== 1 || !id(e.commandId) || !integer(e.clientSequence, 1) || !integer(e.authorityEpoch, 1) || !integer(e.frameEpoch, 1) || !time(e.sentAtMs) || !command(e.command)) return null;
    return {type:"command", envelope:{v:1,commandId:e.commandId,clientSequence:e.clientSequence,authorityEpoch:e.authorityEpoch,frameEpoch:e.frameEpoch,sentAtMs:e.sentAtMs,command:e.command}};
  }
  if (x.type === "received" && keys(x, "type eventSequence") && integer(x.eventSequence)) return {type:"received",eventSequence:x.eventSequence};
  if (x.type === "resume" && keys(x, "type afterEventSequence") && integer(x.afterEventSequence)) return {type:"resume",afterEventSequence:x.afterEventSequence};
  if (x.type === "ping" && keys(x, "type nonce clientSentAtMs") && id(x.nonce) && time(x.clientSentAtMs)) return {type:"ping",nonce:x.nonce,clientSentAtMs:x.clientSentAtMs};
  return null;
}

export function validateCombatRules(x: unknown): x is CombatRules {
  if (!record(x) || !keys(x, "durationMs geometry respawnMs protectionMs weapon shield slowField") ||
    !integer(x.durationMs, 10_000, 3_600_000) || !["trackedBody", "phoneProxy"].includes(String(x.geometry)) ||
    !integer(x.respawnMs, 100, 60_000) || !integer(x.protectionMs, 0, 30_000)) return false;
  const w = x.weapon, s = x.shield, f = x.slowField;
  return record(w) && keys(w, "id kind damage cooldownMs magazine reloadMs speed projectileRadius lifetimeMs rangeMeters") &&
    ["sidearm", "pulse"].includes(String(w.id)) && ["hitscan", "projectile"].includes(String(w.kind)) &&
    record(w.damage) && keys(w.damage, "head torso limbs") && Object.values(w.damage).every(d => integer(d, 1, 100)) &&
    integer(w.cooldownMs, LIMITS.tickMs, 5000) && integer(w.magazine, 1, 100) && integer(w.reloadMs, 100, 10_000) &&
    number(w.speed, 0.1, 1000) && number(w.projectileRadius, 0.001, 0.25) && integer(w.lifetimeMs, 50, 30_000) && number(w.rangeMeters, 0.1, 100) &&
    record(s) && keys(s, "radius offsetMeters durationMs cooldownMs energy") && number(s.radius, 0.05, 1) && number(s.offsetMeters, 0, 0.5) &&
    integer(s.durationMs, 50, 10_000) && integer(s.cooldownMs, s.durationMs, 120_000) && integer(s.energy, 1, 1000) &&
    record(f) && keys(f, "radius durationMs cooldownMs scale") && number(f.radius, 0.1, 10) && integer(f.durationMs, 50, 10_000) &&
    integer(f.cooldownMs, f.durationMs, 120_000) && number(f.scale, 0.05, 1);
}

/** Claims are still untrusted until the runtime verifies their HMAC signature. */
export function validateTicketClaims(x: unknown, nowSeconds: number): CombatTicketClaims | null {
  if (!record(x) || !keys(x, "v iss aud matchId playerId roster authorityEpoch frameEpoch rules iat exp nonce") ||
    x.v !== 1 || x.iss !== "vkz-lobby" || x.aud !== "vkz-combat" || !id(x.matchId) || !id(x.playerId) || !id(x.nonce) ||
    !integer(x.authorityEpoch, 1) || !integer(x.frameEpoch, 1) || !integer(x.iat) || !integer(x.exp) || !Number.isFinite(nowSeconds) ||
    x.iat > nowSeconds + 5 || x.exp <= nowSeconds || x.exp <= x.iat || x.exp - x.iat > LIMITS.ticketLifetimeSeconds ||
    !validateCombatRules(x.rules) || !Array.isArray(x.roster) || x.roster.length < 2 || x.roster.length > LIMITS.players) return null;
  const ids = new Set<string>();
  const roster: Member[] = [];
  let hosts = 0;
  for (const m of x.roster) {
    if (!record(m) || !keys(m, "playerId displayName role") || !id(m.playerId) || ids.has(m.playerId) ||
      typeof m.displayName !== "string" || m.displayName.trim().length === 0 || m.displayName.length > 24 ||
      /[\u0000-\u001f\u007f]/.test(m.displayName) || (m.role !== "host" && m.role !== "player")) return null;
    ids.add(m.playerId);
    roster.push({playerId:m.playerId,displayName:m.displayName,role:m.role});
    if (m.role === "host") hosts++;
  }
  if (hosts !== 1 || !ids.has(x.playerId)) return null;
  return {v:1,iss:"vkz-lobby",aud:"vkz-combat",matchId:x.matchId,playerId:x.playerId,roster,
    authorityEpoch:x.authorityEpoch,frameEpoch:x.frameEpoch,rules:x.rules,iat:x.iat,exp:x.exp,nonce:x.nonce};
}

const nullableTime = (x: unknown): boolean => x === null || time(x);
function projectedPlayer(x: unknown): x is CombatPlayerState {
  if (!record(x) || !keys(x,"playerId displayName role health ammo kills deaths connected frameReady lastFireAtMs reloadEndsAtMs respawnAtMs protectedUntilMs shield slowFieldReadyAtMs")) return false;
  const s=x.shield;
  return id(x.playerId) && typeof x.displayName === "string" && x.displayName.trim().length > 0 && x.displayName.length <= 24 &&
    (x.role === "host" || x.role === "player") && integer(x.health,0,100) && integer(x.ammo,0,100) && integer(x.kills,0,1_000_000) && integer(x.deaths,0,1_000_000) &&
    typeof x.connected === "boolean" && typeof x.frameReady === "boolean" && [x.lastFireAtMs,x.reloadEndsAtMs,x.respawnAtMs,x.protectedUntilMs].every(nullableTime) &&
    record(s) && keys(s,"activeUntilMs cooldownUntilMs energy") && nullableTime(s.activeUntilMs) && time(s.cooldownUntilMs) && number(s.energy,0,1000) && time(x.slowFieldReadyAtMs);
}
function projectedTerminal(x: unknown): x is Extract<CombatEvent,{kind:"projectileTerminal"}> {
  if (!record(x) || !keys(x,"kind projectileId shotId shooterId reason atMs position targetPlayerId zone damage") || x.kind !== "projectileTerminal") return false;
  if (![x.projectileId,x.shotId,x.shooterId].every(id) || !time(x.atMs) || !vector(x.position) || !integer(x.damage,0,100) ||
    !(x.targetPlayerId === null || id(x.targetPlayerId)) || !(x.zone === null || zone(x.zone))) return false;
  if (x.reason === "bodyHit") return x.targetPlayerId !== null && x.zone !== null && x.damage > 0;
  return ["shieldBlocked","missExpired","cancelled"].includes(String(x.reason)) && x.damage === 0 && x.zone === null &&
    (x.reason === "shieldBlocked" ? x.targetPlayerId !== null : x.targetPlayerId === null);
}

/** Validation is independent of the authority HMAC check at the lobby boundary. */
export function validateCombatProjection(x: unknown): CombatProjection | null {
  if (!record(x) || !keys(x,"v matchId authorityEpoch frameEpoch fromEventSequence throughEventSequence matchTimeMs roundStartedAtMs phase players terminals") ||
    x.v !== 1 || !id(x.matchId) || !integer(x.authorityEpoch,1) || !integer(x.frameEpoch,1) || !integer(x.fromEventSequence,1) ||
    !integer(x.throughEventSequence,x.fromEventSequence) || !time(x.matchTimeMs) ||
    !(x.roundStartedAtMs === null || (time(x.roundStartedAtMs) && x.roundStartedAtMs <= x.matchTimeMs)) ||
    !(x.phase === "calibrating" || x.phase === "running" || x.phase === "paused" || x.phase === "finished") ||
    !Array.isArray(x.players) || x.players.length < 2 || x.players.length > LIMITS.players || !x.players.every(projectedPlayer) ||
    !Array.isArray(x.terminals) || x.terminals.length > 64) return null;
  const players=x.players;
  const ids=new Set(players.map(p=>p.playerId));
  if (ids.size !== players.length || players.filter(p=>p.role === "host").length !== 1) return null;
  const terminals: CombatProjection["terminals"][number][]=[];
  let previous=x.fromEventSequence - 1;
  for (const terminal of x.terminals) {
    if (!record(terminal) || !keys(terminal,"eventSequence event") || !integer(terminal.eventSequence,previous+1,x.throughEventSequence) ||
      !projectedTerminal(terminal.event) || terminal.event.atMs > x.matchTimeMs || !ids.has(terminal.event.shooterId) ||
      (terminal.event.targetPlayerId !== null && (!ids.has(terminal.event.targetPlayerId) || terminal.event.targetPlayerId === terminal.event.shooterId))) return null;
    previous=terminal.eventSequence;
    terminals.push({eventSequence:terminal.eventSequence,event:terminal.event});
  }
  return {v:1,matchId:x.matchId,authorityEpoch:x.authorityEpoch,frameEpoch:x.frameEpoch,fromEventSequence:x.fromEventSequence,
    throughEventSequence:x.throughEventSequence,matchTimeMs:x.matchTimeMs,roundStartedAtMs:x.roundStartedAtMs,phase:x.phase,players,terminals};
}
