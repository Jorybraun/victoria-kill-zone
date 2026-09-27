import { env, exports as workerExports } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { DEFAULT_RULES, PROTOCOL_VERSION, parseClientMessage, validateCombatProjection, validateReleaseManifestSummary, validateWorkerIdentity } from "@vkz/combat-protocol";
import { CombatSimulation } from "@vkz/combat-simulation";
import { ProjectionStore } from "../src/projection-store.js";
import { releaseManifestSummary, workerIdentity } from "../src/manifest.js";
import fixture from "../../../contracts/fixtures/combat.v1.json";
import { claims, connect } from "./helpers.js";

describe("release manifest exposure", () => {
  it("publishes the manifest and worker identity on /health", async () => {
    const response = await workerExports.default.fetch(new Request("https://combat.test/health"));
    expect(response.status).toBe(200);
    const body: Record<string, unknown> = await response.json();
    expect(body.service).toBe("vkz-combat");
    expect(body.protocol).toBe(PROTOCOL_VERSION);
    expect(validateReleaseManifestSummary(body.manifest)).toEqual(releaseManifestSummary());
    const worker = validateWorkerIdentity(body.worker);
    expect(worker).not.toBeNull();
    expect(worker!.releaseSha).toBe(releaseManifestSummary().releaseSha);
    expect(worker!.workerVersionTag).toBe(releaseManifestSummary().workerVersionTag);
    expect(worker!.versionId === null || typeof worker!.versionId === "string").toBe(true);
  });

  it("attaches release identity to the first snapshot", async () => {
    const socket = await connect(claims());
    try {
      const snapshot = await socket.next("snapshot");
      expect(snapshot.release?.manifest.protocolVersion).toBe(PROTOCOL_VERSION);
      expect(snapshot.release?.manifest.workerVersionTag).toBe("vkz-combat-2026.09");
      expect(validateWorkerIdentity(snapshot.release?.worker)).not.toBeNull();
    } finally {
      socket.socket.close();
    }
  });

  it("carries the worker identity on every durable projection", async () => {
    const identity = workerIdentity(env);
    const simulation = CombatSimulation.create({ matchId: "manifest-projection", authorityEpoch: 1, frameEpoch: 1, rules: DEFAULT_RULES,
      players: [{ playerId: "host", displayName: "Host", role: "host" }, { playerId: "guest", displayName: "Guest", role: "player" }] });
    simulation.advance([]);
    const snapshot = simulation.snapshot();
    await runInDurableObject(env.COMBAT_ROOMS.getByName("manifest-projection"), (instance, state) => {
      void instance;
      const store = new ProjectionStore(state.storage, identity);
      store.initialize();
      store.append(snapshot, [{ v: 1, matchId: snapshot.matchId, authorityEpoch: 1, frameEpoch: 1, eventSequence: 1,
        tick: snapshot.tick, matchTimeMs: snapshot.matchTimeMs, event: { kind: "phaseChanged", phase: snapshot.phase, reason: "fixture" } }]);
      const row = store.take();
      expect(row).not.toBeNull();
      const projection = validateCombatProjection(JSON.parse(row!.payload));
      expect(projection?.worker).toEqual(identity);
    });
  });

  it("accepts every fixture command envelope through the client message path", () => {
    for (const entry of fixture.envelopes) {
      expect(parseClientMessage(JSON.stringify(entry.message)), entry.id).toEqual(entry.message);
    }
    for (const entry of fixture.rejected) {
      expect(parseClientMessage(JSON.stringify(entry.message)), entry.id).toBeFalsy();
    }
  });
});
