import {env} from "cloudflare:workers";
import {abortAllDurableObjects, runInDurableObject} from "cloudflare:test";
import {afterEach, it} from "vitest";
import type {CombatSnapshot} from "@vkz/combat-protocol";
import {requestUpgrade} from "../tests/helpers.js";
import {installRuntimeProfile} from "./runtime-profile.js";
import {loadScenarios, runLoadScenario} from "./load-scenario.js";
import type {LoadRuntime} from "./load-runtime.js";

declare const __VKZ_LOAD_MS__: number;
declare const __VKZ_PROFILE__: boolean;
afterEach(async () => {await abortAllDurableObjects();});
const runtime: LoadRuntime = {
  environment: "workerd-test-client", clockMode: "receiveAnchor", upgrade: requestUpgrade,
  ...(__VKZ_PROFILE__ ? {installProfile: installRuntimeProfile} : {}),
  readDurable: matchId => runInDurableObject(env.COMBAT_ROOMS.getByName(matchId), (_instance, state) => {
      const row = state.storage.sql.exec<{checkpoint: string; authority_epoch: number; event_sequence: number}>("SELECT checkpoint, authority_epoch, event_sequence FROM room WHERE singleton = 1").one();
      const checkpoint = JSON.parse(row.checkpoint) as {snapshot: CombatSnapshot};
      return {epoch: row.authority_epoch, sequence: row.event_sequence, snapshot: checkpoint.snapshot,
        ledger: state.storage.sql.exec<{sequence: number; payload: string}>("SELECT sequence, payload FROM bullet_events ORDER BY sequence").toArray(),
        bullets: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets").one().count,
        unresolved: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM bullets WHERE terminal_sequence IS NULL").one().count,
        commands: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM commands").one().count,
        projectionRows: state.storage.sql.exec<{count: number}>("SELECT COUNT(*) AS count FROM projection_outbox").one().count,
        projectionProgress: state.storage.sql.exec<{queued_sequence: number; delivered_sequence: number}>("SELECT queued_sequence, delivered_sequence FROM projection_progress").one(),
        checkpointBytes: new TextEncoder().encode(row.checkpoint).byteLength, databaseBytes: state.storage.sql.databaseSize};
    }),
};
for (const scenario of loadScenarios) it(`four-player ${scenario}: measured input, gameplay and durable event convergence`,
  async ({annotate, signal}) => runLoadScenario(scenario, __VKZ_LOAD_MS__, runtime, annotate, signal));
