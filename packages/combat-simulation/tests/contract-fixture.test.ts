import {describe, expect, it} from "vitest";
import type {Member} from "@vkz/combat-protocol";
import {CombatSimulation} from "../src/index.js";
import fixtureJson from "../../../contracts/fixtures/combat.v1.json";

const fixture = fixtureJson as unknown as {
  protocolVersion: number;
  envelopes: {id: string; message: {envelope: Record<string, unknown>}}[];
  refusalReasons: string[];
  snapshot: {message: {snapshot: {
    matchId: string; authorityEpoch: number; frameEpoch: number;
    rules: Parameters<typeof CombatSimulation.create>[0]["rules"];
    players: (Member & Record<string, unknown>)[];
  }}};
};

describe("combat.v1 contract fixture", () => {
  const snapshot = fixture.snapshot.message.snapshot;
  const simulation = () => CombatSimulation.create({
    matchId: snapshot.matchId,
    authorityEpoch: snapshot.authorityEpoch,
    frameEpoch: snapshot.frameEpoch,
    rules: snapshot.rules,
    players: snapshot.players.map(p => ({playerId: p.playerId, displayName: p.displayName, role: p.role})),
  });
  it("matches the first admission snapshot the simulation emits", () => {
    const sim = simulation();
    sim.setConnected("p-host", true);
    expect(sim.snapshot()).toEqual(snapshot);
  });
  it("refuses a fixture fire command before the match starts with a contract reason", () => {
    const sim = simulation();
    const entry = fixture.envelopes.find(e => e.id === "fire-with-observation");
    const host = snapshot.players.find(p => p.role === "host");
    const envelope = {...entry!.message.envelope, playerId: host!.playerId};
    const events = sim.advance([envelope as never]);
    const reasons = events.flatMap(e => "reason" in e && typeof e.reason === "string" ? [e.reason] : []);
    expect(reasons.length).toBeGreaterThan(0);
    for (const reason of reasons) expect(fixture.refusalReasons).toContain(reason);
  });
});
