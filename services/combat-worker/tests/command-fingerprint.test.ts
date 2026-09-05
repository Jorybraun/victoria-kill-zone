import { env } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, expect, it } from "vitest";
import { canonicalJson } from "../src/canonical.js";
import { commandFingerprint, matchesFingerprint } from "../src/command-fingerprint.js";
import { claims, command, connect } from "./helpers.js";

afterEach(async () => {await abortAllDurableObjects();});

it("keeps content identity independent of property order and bounded for large inputs", () => {
  const a = canonicalJson({payload: "x".repeat(12_000), sequence: 1});
  const b = canonicalJson({sequence: 1, payload: "x".repeat(12_000)});
  expect(commandFingerprint(a)).toBe(commandFingerprint(b));
  expect(commandFingerprint(a)).toHaveLength(71);
  expect(commandFingerprint(a.replace('"sequence":1', '"sequence":2'))).not.toBe(commandFingerprint(a));
  expect(matchesFingerprint(a, commandFingerprint(b), b)).toBe(true);
  expect(matchesFingerprint(a, commandFingerprint("different"), "different")).toBe(false);
});

it("persists compact identity and preserves exact retries of legacy canonical rows", async () => {
  const ticket = claims(), socket = await connect(ticket);
  try {
    const initial = await socket.next("snapshot");
    const input = command(initial, 1, {kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1});
    socket.send(input);
    await socket.next("ack", ack => ack.commandId === input.commandId);
    const canonical = canonicalJson(input);
    const stored = await runInDurableObject(env.COMBAT_ROOMS.getByName(ticket.matchId), (_instance, state) => {
      const row = state.storage.sql.exec<{fingerprint: string}>("SELECT fingerprint FROM commands WHERE player_id = ? AND client_sequence = 1", ticket.playerId).one();
      state.storage.sql.exec("UPDATE commands SET fingerprint = ? WHERE player_id = ? AND client_sequence = 1", canonical, ticket.playerId);
      return row.fingerprint;
    });
    expect(stored).toBe(commandFingerprint(canonical));
    socket.send(input);
    expect(await socket.next("ack", ack => ack.commandId === input.commandId)).toMatchObject({replayed: true});
    socket.send({...input, command: {kind: "frameReady", ready: false, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1}});
    expect(await socket.next("error")).toMatchObject({code: "idempotencyConflict", commandId: input.commandId});
  } finally {socket.close();}
});
