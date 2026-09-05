import { randomBytes, bytesToHex } from "@noble/hashes/utils.js";
import { DEFAULT_RULES, LIMITS, validateCombatRules, type CombatTicketClaims } from "@vkz/combat-protocol";
import { v } from "convex/values";
import { mutation } from "./lib/server.js";
import { authenticatePlayer, fail, listPlayers } from "./lib/state.js";
import { signCombatTicket } from "./lib/combat-ticket.js";
import { verifyCombatProjection } from "./lib/combat-projection.js";
import { hashSecret } from "../domain/session.js";
import { resolveWinner } from "../domain/lifecycle.js";
import { appendEvent, toPlayerState } from "./lib/state.js";

// Convex's standard runtime provides deployment-scoped environment variables.
declare const process: {env: Record<string, string | undefined>};
const session = {matchId:v.id("matches"),playerId:v.id("players"),sessionSecret:v.string()};

function configuration(): {secret: string; endpoint: string} {
  const secret = process.env.COMBAT_TICKET_SECRET;
  const raw = process.env.COMBAT_WORKER_URL;
  if (secret === undefined || new TextEncoder().encode(secret).length < 32 || raw === undefined) fail("COMBAT_UNAVAILABLE");
  let url: URL;
  try { url = new URL(raw); } catch { return fail("COMBAT_UNAVAILABLE"); }
  // Credentials must never be put in a URL; production native sockets require TLS.
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") fail("COMBAT_UNAVAILABLE");
  return {secret,endpoint:url.origin};
}

/** Host freezes membership before issuing any capability; this starts calibration. */
export const prepare = mutation({
  args: session,
  returns: v.null(),
  handler: async (ctx, args) => {
    const caller = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) fail("MATCH_NOT_FOUND");
    if (match.hostPlayerId !== caller._id) fail("HOST_ONLY");
    if (match.combatMode !== "durableObject") fail("COMBAT_AUTHORITY_REQUIRED");
    configuration();
    if (match.combatPreparedAt !== undefined && match.status === "active") return null;
    if (match.phase !== "lobby") fail("MATCH_ALREADY_STARTED");
    const players = await listPlayers(ctx, match._id);
    if (players.length < 2 || players.length > LIMITS.players || players.length > match.maxPlayers) fail("PLAYERS_NOT_CONNECTED");
    const now = Date.now();
    if (players.some(p => !p.connected || now - p.lastSeenAt > 15_000)) fail("PLAYERS_NOT_CONNECTED");
    if (players.some(p => !p.ready)) fail("PLAYERS_NOT_READY");
    await ctx.db.patch(match._id, {
      status:"active",phase:"running",startsAt:null,startedAt:null,endsAt:null,
      combatPreparedAt:now,combatFrameEpoch:1,combatAuthorityEpoch:1,combatProjectionSequence:0,
      combatPhase:"calibrating",combatRulesJson:JSON.stringify(DEFAULT_RULES),updatedAt:now,
    });
    return null;
  },
});

/** A short-lived capability authorizes a connection, never a client-selected verdict. */
export const ticket = mutation({
  args: session,
  returns: v.object({endpoint:v.string(),ticket:v.string(),expiresAt:v.number(),authorityEpoch:v.number(),frameEpoch:v.number()}),
  handler: async (ctx, args) => {
    const player = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) fail("MATCH_NOT_FOUND");
    if (match.combatMode !== "durableObject" || match.combatPreparedAt === undefined || match.status !== "active") fail("COMBAT_AUTHORITY_REQUIRED");
    const {secret,endpoint} = configuration();
    const now = Date.now();
    if (player.lastCombatTicketAt !== undefined && now - player.lastCombatTicketAt < 1000) fail("CONNECTION_STALE");
    let rules: unknown;
    try { rules = JSON.parse(match.combatRulesJson ?? "null"); } catch { return fail("COMBAT_UNAVAILABLE"); }
    if (!validateCombatRules(rules)) fail("COMBAT_UNAVAILABLE");
    const roster = (await listPlayers(ctx, match._id)).map(member => ({
      playerId:String(member._id),displayName:member.displayName,
      role:member._id === match.hostPlayerId ? "host" as const : "player" as const,
    }));
    const claims: CombatTicketClaims = {
      v:1,iss:"vkz-lobby",aud:"vkz-combat",matchId:String(match._id),playerId:String(player._id),roster,
      authorityEpoch:match.combatAuthorityEpoch ?? 1,frameEpoch:match.combatFrameEpoch ?? 1,
      rules,iat:Math.floor(now / 1000),exp:Math.floor(now / 1000) + LIMITS.ticketLifetimeSeconds,
      nonce:bytesToHex(randomBytes(16)),
    };
    const signed = signCombatTicket(claims, secret);
    await ctx.db.patch(player._id, {lastCombatTicketAt:now});
    return {endpoint:`${endpoint}/v1/matches/${encodeURIComponent(match._id)}/connect`,ticket:signed,
      expiresAt:claims.exp * 1000,authorityEpoch:claims.authorityEpoch,frameEpoch:claims.frameEpoch};
  },
});

/** Trusted ordered projection only. No player capability can call this writer. */
export const publishProjection = mutation({
  args:{payload:v.string(),signature:v.string()},
  returns:v.object({eventSequence:v.number(),replayed:v.boolean()}),
  handler:async (ctx,args) => {
    const secret=process.env.COMBAT_PROJECTION_SECRET;
    if (secret === undefined) fail("COMBAT_UNAVAILABLE");
    const projection=verifyCombatProjection(args.payload,args.signature,secret);
    if (projection === null) fail("INVALID_SESSION");
    const matchId=ctx.db.normalizeId("matches",projection.matchId);
    if (matchId === null) fail("MATCH_NOT_FOUND");
    const match=await ctx.db.get(matchId);
    if (match === null) fail("MATCH_NOT_FOUND");
    if (match.combatMode !== "durableObject" || match.combatPreparedAt === undefined) fail("COMBAT_AUTHORITY_REQUIRED");
    const current=match.combatProjectionSequence ?? 0, digest=hashSecret(args.payload);
    if (projection.throughEventSequence <= current) {
      if (projection.throughEventSequence === current && match.combatProjectionDigest !== digest) fail("IDEMPOTENCY_CONFLICT");
      return {eventSequence:projection.throughEventSequence,replayed:true};
    }
    if (projection.fromEventSequence !== current + 1 || projection.authorityEpoch < (match.combatAuthorityEpoch ?? 1) ||
      projection.frameEpoch !== match.combatFrameEpoch || (match.status === "ended" && projection.phase !== "finished")) fail("IDEMPOTENCY_CONFLICT");
    const players=await listPlayers(ctx,matchId);
    const byId=new Map(players.map(p=>[String(p._id),p]));
    if (players.length !== projection.players.length || projection.players.some(p=> {
      const stored=byId.get(p.playerId);
      return stored === undefined || stored.displayName !== p.displayName ||
        p.role !== (stored._id === match.hostPlayerId ? "host" : "player");
    })) fail("INVALID_SESSION");
    const now=Date.now();
    const deadline=(time:number|null) => time === null ? null : now + time - projection.matchTimeMs;
    for (const terminal of projection.terminals) {
      const event=terminal.event;
      const prior=await ctx.db.query("combatShots").withIndex("by_match_and_projectile",q=>q.eq("matchId",matchId).eq("projectileId",event.projectileId)).unique();
      if (prior !== null) fail("IDEMPOTENCY_CONFLICT");
      const shooter=byId.get(event.shooterId), target=event.targetPlayerId === null ? null : byId.get(event.targetPlayerId);
      if (shooter === undefined || target === undefined) fail("INVALID_SESSION");
      await ctx.db.insert("combatShots",{matchId,projectileId:event.projectileId,shotId:event.shotId,shooterId:shooter._id,
        targetId:target?._id ?? null,zone:event.zone,damage:event.damage,reason:event.reason,matchTimeMs:event.atMs,
        authorityEpoch:projection.authorityEpoch,eventSequence:terminal.eventSequence,createdAt:now});
      shooter.shotsFired += 1;
      if (event.reason === "bodyHit") {
        shooter.shotsHit += 1; shooter.damageDealt += event.damage;
        if (event.zone === "head") shooter.headshots += 1;
        await appendEvent(ctx,{matchId,clientShotId:event.shotId,type:"hit",actorPlayerId:shooter._id,targetPlayerId:target?._id ?? null,
          zone:event.zone,damage:event.damage,message:`${shooter.displayName} HIT ${target?.displayName ?? "TARGET"}`,createdAt:now});
      }
    }
    for (const player of projection.players) {
      const stored=byId.get(player.playerId)!;
      Object.assign(stored,{health:player.health,ammo:player.ammo,kills:player.kills,deaths:player.deaths,connected:player.connected,
        lifeState:player.health <= 0 ? "respawning" : player.connected ? "alive" : "disconnected"});
      await ctx.db.patch(stored._id,{health:player.health,ammo:player.ammo,kills:player.kills,deaths:player.deaths,
        connected:player.connected,lifeState:player.health <= 0 ? "respawning" : player.connected ? "alive" : "disconnected",
        lastShotAt:deadline(player.lastFireAtMs),reloadEndsAt:deadline(player.reloadEndsAtMs),respawnAt:deadline(player.respawnAtMs),
        shotsFired:stored.shotsFired,shotsHit:stored.shotsHit,headshots:stored.headshots,damageDealt:stored.damageDealt});
    }
    const winner=projection.phase === "finished" ? resolveWinner(players.map(toPlayerState)) : null;
    const winnerPlayer=winner === null ? null : byId.get(winner);
    await ctx.db.patch(matchId,{combatAuthorityEpoch:projection.authorityEpoch,combatProjectionSequence:projection.throughEventSequence,
      combatProjectionDigest:digest,combatPhase:projection.phase,updatedAt:now,
      status:projection.phase === "finished" ? "ended" : "active",phase:projection.phase === "finished" ? "finished" : "running",
      startedAt:projection.roundStartedAtMs === null ? null : now - (projection.matchTimeMs - projection.roundStartedAtMs),
      endsAt:projection.roundStartedAtMs === null ? null : deadline(projection.roundStartedAtMs + match.durationMs),
      ...(projection.phase === "finished" ? {winnerPlayerId:winnerPlayer?._id ?? null,endReason:"duration_elapsed" as const} : {})});
    if (projection.phase === "finished" && match.combatPhase !== "finished") await appendEvent(ctx,{matchId,type:"finished",actorPlayerId:winnerPlayer?._id ?? null,
      targetPlayerId:null,zone:null,damage:null,message:winnerPlayer === null || winnerPlayer === undefined ? "MATCH DRAW" : `${winnerPlayer.displayName} WINS`,createdAt:now});
    return {eventSequence:projection.throughEventSequence,replayed:false};
  },
});
