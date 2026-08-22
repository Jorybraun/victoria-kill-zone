import { makeFunctionReference } from "convex/server";
import { convexTest, type TestConvex } from "convex-test";
import type { PlayerSession } from "../domain/contract.js";
import type { DebugFireResult } from "../domain/fire.js";
import type { MatchSnapshot, SpectatorSnapshot } from "../domain/snapshot.js";
import schema from "../functions/schema.js";

/**
 * Function-level harness for the registered Convex modules.
 *
 * `convex-test` normally discovers modules through `import.meta.glob` and the
 * generated directory. This slice deliberately ships no generated deployment
 * output, so the module map is declared explicitly; the `_generated` entry only
 * anchors the module root that `convex-test` resolves paths against.
 */
const modules: Record<string, () => Promise<unknown>> = {
  "../functions/_generated/api.ts": () => Promise.resolve({}),
  "../functions/matches.ts": () => import("../functions/matches.js"),
  "../functions/players.ts": () => import("../functions/players.js"),
  "../functions/shots.ts": () => import("../functions/shots.js"),
  "../functions/queries.ts": () => import("../functions/queries.js"),
};

type AuthenticatedArgs = {
  matchId: string;
  playerId: string;
  sessionSecret: string;
};

type DebugFireArgs = AuthenticatedArgs & { clientShotId: string };

export function testBackend(): TestConvex<typeof schema> {
  return convexTest(schema, modules);
}

export const api = {
  matches: {
    create: makeFunctionReference<
      "mutation",
      { displayName: string; arenaRadiusMeters: number },
      PlayerSession
    >("matches:create"),
    join: makeFunctionReference<"mutation", { displayName: string; code: string }, PlayerSession>(
      "matches:join",
    ),
    setReady: makeFunctionReference<
      "mutation",
      { matchId: string; playerId: string; sessionSecret: string; isReady: boolean },
      null
    >("matches:setReady"),
    start: makeFunctionReference<
      "mutation",
      { matchId: string; playerId: string; sessionSecret: string },
      null
    >("matches:start"),
    debugFire: makeFunctionReference<"mutation", DebugFireArgs, DebugFireResult>(
      "matches:debugFire",
    ),
  },
  shots: {
    debugFire: makeFunctionReference<"mutation", DebugFireArgs, DebugFireResult>("shots:debugFire"),
  },
  queries: {
    matchSnapshot: makeFunctionReference<"query", AuthenticatedArgs, MatchSnapshot>(
      "queries:matchSnapshot",
    ),
    spectatorSnapshot: makeFunctionReference<"query", { code: string }, SpectatorSnapshot | null>(
      "queries:spectatorSnapshot",
    ),
  },
  players: {
    heartbeat: makeFunctionReference<
      "mutation",
      { matchId: string; playerId: string; sessionSecret: string },
      null
    >("players:heartbeat"),
  },
  /** Internal scheduled work; never part of the public wire surface. */
  internal: {
    activate: makeFunctionReference<
      "mutation",
      { matchId: string; expectedStartsAt: number },
      null
    >("matches:activate"),
    finish: makeFunctionReference<"mutation", { matchId: string; expectedEndsAt: number }, null>(
      "matches:finish",
    ),
    expirePresence: makeFunctionReference<
      "mutation",
      { playerId: string; expectedLastSeenAt: number },
      null
    >("players:expirePresence"),
  },
};

export function auth(session: PlayerSession): AuthenticatedArgs {
  return {
    matchId: session.matchId,
    playerId: session.playerId,
    sessionSecret: session.sessionSecret,
  };
}
