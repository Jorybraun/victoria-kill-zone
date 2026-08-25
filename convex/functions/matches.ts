import { randomBytes } from "@noble/hashes/utils.js";
import { makeFunctionReference } from "convex/server";
import { v } from "convex/values";
import {
  GAMEPLAY,
  isValidDisplayName,
  normalizeMatchCode,
} from "../domain/config.js";
import {
  classifyLocationSample,
  isWellFormedLocationSample,
  type LocationSample,
} from "../domain/geofence.js";
import {
  matchCodeFromBytes,
  planActivateMatch,
  planCreateMatch,
  planJoinMatch,
  planStartMatch,
} from "../domain/match.js";
import { resolveWinner } from "../domain/lifecycle.js";
import { hashSecret, sessionSecretFromBytes } from "../domain/session.js";
import { internalMutation, mutation, type Id, type MutationCtx } from "./lib/server.js";
import {
  appendEvent,
  authenticatePlayer,
  fail,
  listPlayers,
  loadMatchByCode,
  locationSampleValidator,
  toMatchState,
  toPlayerState,
} from "./lib/state.js";

const CODE_ATTEMPTS = 8;

const playerSession = v.object({
  matchId: v.id("matches"),
  code: v.string(),
  playerId: v.id("players"),
  sessionSecret: v.string(),
});

const activateReference = makeFunctionReference<
  "mutation",
  { matchId: Id<"matches">; expectedStartsAt: number },
  null
>("matches:activate");

const finishReference = makeFunctionReference<
  "mutation",
  { matchId: Id<"matches">; expectedEndsAt: number },
  null
>("matches:finish");

/** Create the duel and issue the host capability exactly once. */
export const create = mutation({
  args: {
    displayName: v.string(),
    arenaRadiusMeters: v.number(),
    // phase0.v1 arenaCenter. Optional during the migration window: the smaller
    // G2 create shape stays accepted, but a match created without a valid
    // center can never use shots:fire (its players stay LOCATION_STALE).
    arenaCenter: v.optional(locationSampleValidator),
  },
  returns: playerSession,
  handler: async (ctx, args) => {
    const displayName = displayNameOrFail(args.displayName);
    const now = Date.now();
    const center = validatedArenaCenter(args.arenaCenter, now);
    const code = await allocateMatchCode(ctx);
    const sessionSecret = sessionSecretFromBytes(randomBytes(32));
    const plan = planCreateMatch(
      {
        displayName,
        // Without a phase0 arenaCenter, zero is an internal demo origin and is
        // never exposed by the public spectator projection.
        centerLatitude: center === null ? 0 : center.latitude,
        centerLongitude: center === null ? 0 : center.longitude,
        hasArenaCenter: center !== null,
        radiusMeters: args.arenaRadiusMeters,
        now,
      },
      code,
    );

    const matchId = await ctx.db.insert("matches", {
      ...plan.match,
      startedAt: null,
      hostPlayerId: null,
    });
    const playerId = await ctx.db.insert("players", {
      ...plan.host,
      matchId,
      sessionHash: hashSecret(sessionSecret),
    });
    await ctx.db.patch(matchId, { hostPlayerId: playerId, updatedAt: now });
    await appendEvent(ctx, {
      matchId,
      type: "joined",
      actorPlayerId: playerId,
      targetPlayerId: null,
      zone: null,
      damage: null,
      message: `${displayName} JOINED`,
      createdAt: now,
    });

    return { matchId, code, playerId, sessionSecret };
  },
});

/** Join the only open slot and issue the guest capability exactly once. */
export const join = mutation({
  args: {
    displayName: v.string(),
    code: v.string(),
  },
  returns: playerSession,
  handler: async (ctx, args) => {
    const displayName = displayNameOrFail(args.displayName);
    const normalizedCode = normalizeMatchCode(args.code);
    if (normalizedCode === null) {
      fail("INVALID_CODE");
    }

    const match = await loadMatchByCode(ctx, normalizedCode);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }
    if (toMatchState(match).phase !== "lobby") {
      fail("MATCH_ALREADY_STARTED");
    }

    const now = Date.now();
    const players = await listPlayers(ctx, match._id);
    const plan = planJoinMatch(match, players.length, {
      displayName,
      hasArenaCenter: match.arenaCenterAt !== undefined && match.arenaCenterAt !== null,
      now,
    });
    if (!plan.ok) {
      fail(plan.reason);
    }

    const sessionSecret = sessionSecretFromBytes(randomBytes(32));
    const playerId = await ctx.db.insert("players", {
      ...plan.value.guest,
      matchId: match._id,
      sessionHash: hashSecret(sessionSecret),
    });
    await ctx.db.patch(match._id, {
      ...plan.value.matchPatch,
      phase: "lobby",
    });
    await appendEvent(ctx, {
      matchId: match._id,
      type: "joined",
      actorPlayerId: playerId,
      targetPlayerId: null,
      zone: null,
      damage: null,
      message: `${displayName} JOINED`,
      createdAt: now,
    });

    return { matchId: match._id, code: match.code, playerId, sessionSecret };
  },
});

export const setReady = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
    isReady: v.boolean(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const player = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }

    const phase = toMatchState(match).phase;
    if (phase !== "lobby") {
      fail("MATCH_ALREADY_STARTED");
    }

    const now = Date.now();
    if ((player.ready ?? false) !== args.isReady) {
      await ctx.db.patch(player._id, {
        ready: args.isReady,
        connected: true,
        lastSeenAt: now,
      });
      await appendEvent(ctx, {
        matchId: match._id,
        type: "ready",
        actorPlayerId: player._id,
        targetPlayerId: null,
        zone: null,
        damage: null,
        message: `${player.displayName} ${args.isReady ? "READY" : "NOT READY"}`,
        createdAt: now,
      });
    }

    return null;
  },
});

/** Host-only start enters countdown; a guarded job activates the duel. */
export const start = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const requester = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("MATCH_NOT_FOUND");
    }

    const players = await listPlayers(ctx, match._id);
    const now = Date.now();
    const plan = planStartMatch(
      toMatchState(match),
      players.map(toPlayerState),
      requester._id,
      now,
    );
    if (!plan.ok) {
      fail(plan.reason);
    }

    await ctx.db.patch(match._id, plan.value.matchPatch);
    await ctx.scheduler.runAt(plan.value.matchPatch.startsAt, activateReference, {
      matchId: match._id,
      expectedStartsAt: plan.value.matchPatch.startsAt,
    });
    return null;
  },
});

/** Guarded countdown activation. */
export const activate = internalMutation({
  args: {
    matchId: v.id("matches"),
    expectedStartsAt: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      return null;
    }

    const now = Date.now();
    const plan = planActivateMatch(toMatchState(match), args.expectedStartsAt, now);
    if (plan === null) {
      return null;
    }

    const players = await listPlayers(ctx, match._id);
    await ctx.db.patch(match._id, {
      ...plan.matchPatch,
      startedAt: args.expectedStartsAt,
    });
    for (const player of players) {
      await ctx.db.patch(player._id, plan.playerResetPatch);
    }
    await appendEvent(ctx, {
      matchId: match._id,
      type: "started",
      actorPlayerId: match.hostPlayerId,
      targetPlayerId: null,
      zone: null,
      damage: null,
      message: "DUEL STARTED",
      createdAt: now,
    });
    await ctx.scheduler.runAt(plan.matchPatch.endsAt, finishReference, {
      matchId: match._id,
      expectedEndsAt: plan.matchPatch.endsAt,
    });
    return null;
  },
});

/** Guarded duration finish and deterministic winner calculation. */
export const finish = internalMutation({
  args: {
    matchId: v.id("matches"),
    expectedEndsAt: v.number(),
  },
  returns: v.null(),
  handler: async (ctx, args) => {
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      return null;
    }

    const now = Date.now();
    const state = toMatchState(match);
    if (state.phase !== "running" || state.endsAt !== args.expectedEndsAt || now < args.expectedEndsAt) {
      return null;
    }

    const players = await listPlayers(ctx, match._id);
    const winnerPlayerId = resolveWinner(players.map(toPlayerState));
    await ctx.db.patch(match._id, {
      status: "ended",
      phase: "finished",
      winnerPlayerId: winnerPlayerId === null ? null : (winnerPlayerId as Id<"players">),
      endReason: "duration_elapsed",
      updatedAt: now,
    });
    const winner = players.find((player) => player._id === winnerPlayerId);
    await appendEvent(ctx, {
      matchId: match._id,
      type: "finished",
      actorPlayerId: winner?._id ?? null,
      targetPlayerId: null,
      zone: null,
      damage: null,
      message: winner === undefined ? "DUEL DRAW" : `${winner.displayName} WINS`,
      createdAt: now,
    });
    return null;
  },
});

function displayNameOrFail(value: string): string {
  const trimmed = value.trim();
  if (!isValidDisplayName(trimmed)) {
    fail("INVALID_DISPLAY_NAME");
  }
  return trimmed;
}

/**
 * phase0.v1 arenaCenter validation: a malformed sample (non-finite values,
 * out-of-range coordinates, negative accuracy) throws INVALID_LOCATION; a
 * well-formed but untrusted sample (accuracy above 20 m or an unacceptable
 * client-capture age/skew) cannot anchor an arena and throws INVALID_ARENA.
 * Both are thrown before any match, player, or event is written.
 */
function validatedArenaCenter(
  sample: LocationSample | undefined,
  now: number,
): LocationSample | null {
  if (sample === undefined) {
    return null;
  }
  if (!isWellFormedLocationSample(sample)) {
    fail("INVALID_LOCATION");
  }
  if (classifyLocationSample(sample, now) !== "trusted") {
    fail("INVALID_ARENA");
  }
  return sample;
}

async function allocateMatchCode(ctx: MutationCtx): Promise<string> {
  for (let attempt = 0; attempt < CODE_ATTEMPTS; attempt += 1) {
    const code = matchCodeFromBytes(randomBytes(GAMEPLAY.matchCodeLength));
    if ((await loadMatchByCode(ctx, code)) === null) {
      return code;
    }
  }

  return fail("MATCH_NOT_FOUND");
}
