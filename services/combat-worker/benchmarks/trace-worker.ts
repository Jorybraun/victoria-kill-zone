import {CombatRoom as ProductionRoom} from "../src/room.js";
import {ARM_PREFIX, TRACE_PREFIX, installFirstPauseTrace, type ObservedRoom} from "./first-pause-trace.js";
export {default} from "../src/index.js";

/** Selected only by the benchmark config. Production has no trace RPC or route. */
export class CombatRoom extends ProductionRoom {
  private readonly trace;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.trace = installFirstPauseTrace(this as unknown as ObservedRoom,
      record => {console.info(TRACE_PREFIX + JSON.stringify(record));});
  }
  async beginTrace(): Promise<void> {
    await (this as unknown as ObservedRoom).queue.run(() => {
      this.trace.begin(); console.info(ARM_PREFIX + "{}");
    });
  }
}
