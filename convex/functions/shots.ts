import { debugFireArgs, debugFireHandler } from "./lib/debugFire.js";
import { mutation } from "./lib/server.js";

/** `shots:debugFire` — the authoritative, host-only debug network path. */
export const debugFire = mutation({
  args: debugFireArgs,
  handler: debugFireHandler,
});
