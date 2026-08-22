import { makeFunctionReference } from "convex/server";
import { convexTest, type TestConvex } from "convex-test";
import type { PlayerSession } from "../domain/contract.js";
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
};

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
  },
  /** Internal scheduled transitions; never part of the public wire surface. */
  internal: {
    advanceToRunning: makeFunctionReference<"mutation", { matchId: string }, null>(
      "matches:advanceToRunning",
    ),
    advanceToFinished: makeFunctionReference<"mutation", { matchId: string }, null>(
      "matches:advanceToFinished",
    ),
  },
};
