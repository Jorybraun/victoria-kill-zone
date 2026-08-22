import { makeFunctionReference } from "convex/server";
import type { Id } from "./server.js";

/**
 * References to this module's own internal scheduled mutations.
 *
 * The Convex CLI normally emits these in `_generated/api`, which this slice
 * deliberately does not ship. Referencing them by registered name keeps
 * scheduling typed without a deployment, and avoids importing `matches.ts`
 * from the module it schedules.
 */
export const scheduled = {
  advanceToRunning: makeFunctionReference<"mutation", { matchId: Id<"matches"> }, null>(
    "matches:advanceToRunning",
  ),
  advanceToFinished: makeFunctionReference<"mutation", { matchId: Id<"matches"> }, null>(
    "matches:advanceToFinished",
  ),
};
