import { randomBytes } from "@noble/hashes/utils.js";
import { v } from "convex/values";
import { GAMEPLAY } from "../domain/config.js";
import { matchCodeFromBytes, planCreateMatch, planJoinMatch, planStartMatch } from "../domain/match.js";
import { digestsMatch } from "../domain/session.js";
import { mutation, type Doc, type Id, type MutationCtx } from "./lib/server.js";
import { authenticatePlayer, fail, listPlayers, loadMatchByCode, toPlayerState } from "./lib/state.js";

const DIGEST_LENGTH = 64;
const CODE_ATTEMPTS = 8;

const digest = v.string();

/**
 * Create a duel and its host player atomically.
 *
 * The client generates a random match-scoped session secret and sends only its
 * SHA-256 digest; the raw secret never reaches the backend at creation time.
 */
export const createMatch = mutation({
  args: {
    displayName: v.string(),
    deviceIdHash: digest,
    sessionHash: digest,
    centerLatitude: v.number(),
    centerLongitude: v.number(),
    radiusMeters: v.optional(v.number()),
  },
  returns: v.object({
    matchId: v.id("matches"),
    playerId: v.id("players"),
    code: v.string(),
    status: v.literal("setup"),
  }),
  handler: async (ctx, args) => {
    assertDigest(args.deviceIdHash);
    assertDigest(args.sessionHash);

    const now = Date.now();
    const code = await allocateMatchCode(ctx);
    const plan = planCreateMatch(
      {
        displayName: args.displayName,
        centerLatitude: args.centerLatitude,
        centerLongitude: args.centerLongitude,
        ...(args.radiusMeters === undefined ? {} : { radiusMeters: args.radiusMeters }),
        now,
      },
      code,
    );

    const matchId = await ctx.db.insert("matches", { ...plan.match, hostPlayerId: null });
    const playerId = await ctx.db.insert("players", {
      ...plan.host,
      matchId,
      deviceIdHash: args.deviceIdHash,
      sessionHash: args.sessionHash,
    });
    await ctx.db.patch(matchId, { hostPlayerId: playerId, updatedAt: now });
    await appendEvent(ctx, matchId, {
      type: "joined",
      actorPlayerId: playerId,
      message: `${plan.host.displayName} opened the arena`,
      createdAt: now,
    });

    return { matchId, playerId, code, status: "setup" as const };
  },
});

/**
 * Join an open duel as the guest. The two-player limit and the
 * `setup -> waiting` transition are server-owned. Re-joining from the same
 * device with the same session digest returns the existing player instead of
 * creating a duplicate.
 */
export const joinMatch = mutation({
  args: {
    code: v.string(),
    displayName: v.string(),
    deviceIdHash: digest,
    sessionHash: digest,
  },
  returns: v.object({
    matchId: v.id("matches"),
    playerId: v.id("players"),
    status: v.union(v.literal("setup"), v.literal("waiting")),
  }),
  handler: async (ctx, args) => {
    assertDigest(args.deviceIdHash);
    assertDigest(args.sessionHash);

    const match = await loadMatchByCode(ctx, args.code);
    if (match === null) {
      fail("match_not_found");
    }

    const now = Date.now();
    const players = await listPlayers(ctx, match._id);

    const existing = players.find((player) => player.deviceIdHash === args.deviceIdHash);
    if (existing !== undefined) {
      if (!digestsMatch(existing.sessionHash, args.sessionHash)) {
        fail("invalid_session");
      }

      await ctx.db.patch(existing._id, { connected: true, lastSeenAt: now });
      return {
        matchId: match._id,
        playerId: existing._id,
        status: match.status === "setup" ? ("setup" as const) : ("waiting" as const),
      };
    }

    const plan = planJoinMatch(match, players.length, { displayName: args.displayName, now });
    if (!plan.ok) {
      fail(plan.reason);
    }

    const playerId = await ctx.db.insert("players", {
      ...plan.value.guest,
      matchId: match._id,
      deviceIdHash: args.deviceIdHash,
      sessionHash: args.sessionHash,
    });
    await ctx.db.patch(match._id, plan.value.matchPatch);
    await appendEvent(ctx, match._id, {
      type: "joined",
      actorPlayerId: playerId,
      message: `${plan.value.guest.displayName} joined the duel`,
      createdAt: now,
    });

    return { matchId: match._id, playerId, status: "waiting" as const };
  },
});

/**
 * Host-only start. Requires two connected players, resets server-owned health
 * and ammunition, and stamps the authoritative `startedAt`/`endsAt` window.
 */
export const startMatch = mutation({
  args: {
    matchId: v.id("matches"),
    playerId: v.id("players"),
    sessionSecret: v.string(),
  },
  returns: v.object({
    status: v.literal("active"),
    startedAt: v.number(),
    endsAt: v.number(),
  }),
  handler: async (ctx, args) => {
    const requester = await authenticatePlayer(ctx, args.matchId, args.playerId, args.sessionSecret);
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      fail("match_not_found");
    }

    const now = Date.now();
    const players = await listPlayers(ctx, match._id);
    const plan = planStartMatch(match, players.map(toPlayerState), requester._id, now);
    if (!plan.ok) {
      fail(plan.reason);
    }

    await ctx.db.patch(match._id, plan.value.matchPatch);
    for (const player of players) {
      await ctx.db.patch(player._id, plan.value.playerResetPatch);
    }
    await appendEvent(ctx, match._id, {
      type: "started",
      actorPlayerId: requester._id,
      message: `${requester.displayName} started the duel`,
      createdAt: now,
    });

    return {
      status: "active" as const,
      startedAt: now,
      endsAt: now + match.durationMs,
    };
  },
});

function assertDigest(value: string): void {
  if (value.length !== DIGEST_LENGTH || !/^[0-9a-f]+$/.test(value)) {
    fail("invalid_session");
  }
}

/** Random match codes come from the runtime CSPRNG; formatting is pure domain. */
async function allocateMatchCode(ctx: MutationCtx): Promise<string> {
  for (let attempt = 0; attempt < CODE_ATTEMPTS; attempt += 1) {
    const code = matchCodeFromBytes(randomBytes(GAMEPLAY.matchCodeLength));
    const clash = await loadMatchByCode(ctx, code);
    if (clash === null) {
      return code;
    }
  }

  return fail("match_not_found");
}

async function appendEvent(
  ctx: MutationCtx,
  matchId: Id<"matches">,
  event: Pick<Doc<"events">, "type" | "message" | "createdAt"> & {
    actorPlayerId?: Id<"players">;
  },
): Promise<void> {
  await ctx.db.insert("events", {
    matchId,
    type: event.type,
    actorPlayerId: event.actorPlayerId ?? null,
    targetPlayerId: null,
    zone: null,
    damage: null,
    message: event.message,
    createdAt: event.createdAt,
  });
}
