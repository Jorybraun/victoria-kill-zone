import { v } from "convex/values";
import type { PlayerSession } from "../domain/contract.js";
import { planActivation, resolvePhase, shouldFinish } from "../domain/lifecycle.js";
import {
  isFiniteArenaRadius,
  isValidMatchCode,
  matchCodeFromBytes,
  planCreateMatch,
  planJoinMatch,
  planSetReady,
  planStartMatch,
} from "../domain/match.js";
import { scheduled } from "./lib/scheduled.js";
import { issueSessionSecret, matchCodeBytes } from "./lib/session.js";
import { internalMutation, mutation, type Id, type MutationCtx } from "./lib/server.js";
import {
  advancePhase,
  authenticatePlayer,
  fail,
  hostPlayer,
  listPlayers,
  matchByCode,
  schedulePresenceExpiry,
  toLobbyPlayer,
} from "./lib/store.js";

const authenticatedArgs = {
  matchId: v.string(),
  playerId: v.string(),
  sessionSecret: v.string(),
};

const CODE_ALLOCATION_ATTEMPTS = 8;

async function allocateMatchCode(ctx: MutationCtx): Promise<string> {
  for (let attempt = 0; attempt < CODE_ALLOCATION_ATTEMPTS; attempt += 1) {
    const code = matchCodeFromBytes(matchCodeBytes());
    if ((await matchByCode(ctx, code)) === null) {
      return code;
    }
  }

  return fail("INVALID_CODE");
}

/** `matches:create` — opens a lobby and returns the host's match-scoped session. */
export const create = mutation({
  args: { displayName: v.string(), arenaRadiusMeters: v.number() },
  handler: async (ctx, args): Promise<PlayerSession> => {
    const now = Date.now();
    // Checked before the code is even allocated: the sanitized error carries
    // only the frozen code, never the rejected value, and no match, player, or
    // event exists for a duel whose arena was never a measurement.
    if (!isFiniteArenaRadius(args.arenaRadiusMeters)) {
      fail("INVALID_ARENA_RADIUS");
    }

    const plan = planCreateMatch({
      displayName: args.displayName,
      arenaRadiusMeters: args.arenaRadiusMeters,
      code: await allocateMatchCode(ctx),
      now,
    });

    if (!plan.ok) {
      fail(plan.code);
    }

    const session = issueSessionSecret();
    const matchId = await ctx.db.insert("matches", plan.value.match);
    const playerId = await ctx.db.insert("players", {
      ...plan.value.host,
      matchId,
      sessionHash: session.hash,
    });

    await ctx.db.insert("events", {
      matchId,
      type: "joined",
      message: plan.value.message,
      actorPlayerId: playerId,
      createdAt: now,
    });
    await schedulePresenceExpiry(ctx, playerId, now);

    return {
      matchId,
      code: plan.value.match.code,
      playerId,
      sessionSecret: session.secret,
    };
  },
});

/** `matches:join` — adds the second player to a lobby by duel code. */
export const join = mutation({
  args: { displayName: v.string(), code: v.string() },
  handler: async (ctx, args): Promise<PlayerSession> => {
    const now = Date.now();
    if (!isValidMatchCode(args.code)) {
      fail("INVALID_CODE");
    }

    const found = await matchByCode(ctx, args.code);
    if (found === null) {
      fail("MATCH_NOT_FOUND");
    }

    const match = await advancePhase(ctx, found, now);
    const players = await listPlayers(ctx, match._id);
    const plan = planJoinMatch({
      displayName: args.displayName,
      code: args.code,
      phase: resolvePhase(match, now),
      players: players.map(toLobbyPlayer),
      now,
    });

    if (!plan.ok) {
      fail(plan.code);
    }

    const session = issueSessionSecret();
    const playerId = await ctx.db.insert("players", {
      ...plan.value.guest,
      matchId: match._id,
      sessionHash: session.hash,
    });

    await ctx.db.insert("events", {
      matchId: match._id,
      type: "joined",
      message: plan.value.message,
      actorPlayerId: playerId,
      createdAt: now,
    });
    await schedulePresenceExpiry(ctx, playerId, now);

    return {
      matchId: match._id,
      code: match.code,
      playerId,
      sessionSecret: session.secret,
    };
  },
});

/** `matches:setReady` — records the caller's own readiness while in the lobby. */
export const setReady = mutation({
  args: { ...authenticatedArgs, isReady: v.boolean() },
  handler: async (ctx, args): Promise<null> => {
    const now = Date.now();
    const { match, player } = await authenticatePlayer(ctx, args);
    const plan = planSetReady({
      phase: resolvePhase(match, now),
      displayName: player.displayName,
      isReady: args.isReady,
    });

    if (!plan.ok) {
      fail(plan.code);
    }

    if (player.ready !== plan.value.ready) {
      await ctx.db.patch(player._id, { ready: plan.value.ready });
      await ctx.db.insert("events", {
        matchId: match._id,
        type: "ready",
        message: plan.value.message,
        actorPlayerId: player._id,
        createdAt: now,
      });
    }

    return null;
  },
});

/** `matches:start` — host-only; starts the server-timed countdown. */
export const start = mutation({
  args: authenticatedArgs,
  handler: async (ctx, args): Promise<null> => {
    const now = Date.now();
    const { match, player } = await authenticatePlayer(ctx, args);
    const players = await listPlayers(ctx, match._id);
    const plan = planStartMatch({
      phase: resolvePhase(match, now),
      actorRole: player.role,
      players: players.map(toLobbyPlayer),
      now,
    });

    if (!plan.ok) {
      fail(plan.code);
    }

    await ctx.db.patch(match._id, {
      phase: plan.value.phase,
      startsAt: plan.value.startsAt,
    });

    // Subscriptions only rerun on a write, so the countdown boundary is
    // persisted by scheduled work rather than left for the next client call to
    // notice. The duel's end time belongs to that activation, not to the
    // countdown, so a running match always carries an `endsAt`.
    await ctx.scheduler.runAt(plan.value.startsAt, scheduled.activate, {
      matchId: match._id,
      expectedStartsAt: plan.value.startsAt,
    });

    return null;
  },
});

/**
 * `internal.matches:activate` — fires at `startsAt`.
 *
 * The single writer of `endsAt` and of the `started` event: the duel becomes
 * playable at the server-owned boundary, and the guard makes an early,
 * duplicated, or superseded run a no-op.
 */
export const activate = internalMutation({
  args: { matchId: v.id("matches"), expectedStartsAt: v.number() },
  handler: async (ctx, args): Promise<null> => {
    const now = Date.now();
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      return null;
    }

    const plan = planActivation(match, args.expectedStartsAt, now);
    if (plan === null) {
      return null;
    }

    await ctx.db.patch(match._id, { phase: plan.phase, endsAt: plan.endsAt });
    await ctx.db.insert("events", {
      matchId: match._id,
      type: "started",
      message: plan.message,
      ...hostActor(await hostPlayer(ctx, match._id)),
      createdAt: now,
    });

    await ctx.scheduler.runAt(plan.endsAt, scheduled.finish, {
      matchId: match._id,
      expectedEndsAt: plan.endsAt,
    });

    return null;
  },
});

function hostActor(host: { _id: Id<"players"> } | null): { actorPlayerId?: Id<"players"> } {
  return host === null ? {} : { actorPlayerId: host._id };
}

/** `internal.matches:finish` — fires at the `endsAt` it was scheduled for. */
export const finish = internalMutation({
  args: { matchId: v.id("matches"), expectedEndsAt: v.number() },
  handler: async (ctx, args): Promise<null> => {
    const match = await ctx.db.get(args.matchId);
    if (match === null) {
      return null;
    }

    if (shouldFinish(match, args.expectedEndsAt, Date.now())) {
      await ctx.db.patch(match._id, { phase: "finished" });
    }

    return null;
  },
});
