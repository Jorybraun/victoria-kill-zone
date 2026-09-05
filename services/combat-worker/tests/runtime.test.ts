import { env, exports as workerExports } from "cloudflare:workers";
import { abortAllDurableObjects, evictDurableObject, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { LIMITS } from "@vkz/combat-protocol";
import { claims, command, connect, requestUpgrade, token } from "./helpers.js";

afterEach(async () => { await abortAllDurableObjects(); });

describe("native authenticated WebSocket admission", () => {
  it("requires a bearer ticket and never accepts a token in the URL", async () => {
    const payload = claims();
    const missing = await workerExports.default.fetch(new Request(`https://combat.test/v1/matches/${payload.matchId}/connect`, { headers: { Upgrade: "websocket" } }));
    expect(missing.status).toBe(401);
    expect((await requestUpgrade(payload, { query: "?token=not-an-admission-channel" })).status).toBe(404);
    expect((await requestUpgrade(payload, { pathMatchId: crypto.randomUUID() })).status).toBe(401);
    const authorization = await token(payload);
    expect((await requestUpgrade(payload, { bearer: `${authorization.slice(0, -8)}AAAAAAAA` })).status).toBe(401);
  });

  it("rejects expired, wrong-algorithm, and non-member tickets", async () => {
    const payload = claims();
    expect((await requestUpgrade({ ...payload, iat: payload.iat - 200, exp: payload.iat - 80 })).status).toBe(401);
    expect((await requestUpgrade(payload, { bearer: await token(payload, { alg: "none", typ: "JWT" }) })).status).toBe(401);
    expect((await requestUpgrade({ ...payload, playerId: "outsider" })).status).toBe(401);
  });

  it("freezes roster/rules and replaces the same player's previous socket", async () => {
    const payload = claims();
    const first = await connect(payload);
    await first.next("snapshot");
    const replacement = await connect(payload);
    expect(await first.closed).toBe(4001);
    const snapshot = await replacement.next("snapshot");
    expect(snapshot.snapshot.players).toHaveLength(2);
    const changed = { ...payload, rules: { ...payload.rules, weapon: { ...payload.rules.weapon, speed: 9 } } };
    expect((await requestUpgrade(changed)).status).toBe(409);
    replacement.close();
  });

  it("admits at most the four signed members", async () => {
    const payload = claims({ roster: [
      { playerId: "host", displayName: "Host", role: "host" },
      ...[1, 2, 3].map((id) => ({ playerId: `player-${id}`, displayName: `Player ${id}`, role: "player" as const })),
    ] });
    const sockets = [];
    for (const member of payload.roster) {
      const socket = await connect({ ...payload, playerId: member.playerId });
      sockets.push(socket);
      expect((await socket.next("snapshot")).snapshot.players).toHaveLength(LIMITS.players);
    }
    expect((await requestUpgrade({ ...payload, roster: [...payload.roster, { playerId: "extra", displayName: "Extra", role: "player" }] })).status).toBe(401);
    for (const socket of sockets) socket.close();
  });

  it("invalidates the replaced phone's spatial readiness and latest pose", async () => {
    const payload = claims();
    const first = await connect(payload);
    const initial = await first.next("snapshot");
    first.send(command(initial, 1, { kind: "frameReady", ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1 }));
    first.send(command(initial, 2, { kind: "pose", observations: [], pose: { sequence: 1, capturedAtMs: initial.snapshot.matchTimeMs,
      position: [0, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal" } }));
    await first.next("ack", (ack) => ack.clientSequence === 2);
    const replacement = await connect(payload);
    const replaced = await replacement.next("snapshot");
    expect(replaced.snapshot.players.find((player) => player.playerId === "host")?.frameReady).toBe(false);
    expect(replaced.snapshot.phonePoses.some((pose) => pose.playerId === "host")).toBe(false);
    expect(replaced.clientSequence).toBe(2);
    expect(await first.closed).toBe(4001);
    replacement.close();
  });
});

describe("durable command processing", () => {
  it("persists a refusal before acknowledgment and replays it without changing state", async () => {
    const payload = claims();
    const socket = await connect(payload);
    const initial = await socket.next("snapshot");
    const input = command(initial, 1, { kind: "reload" });
    socket.send(input);
    const ack = await socket.next("ack");
    expect(ack).toMatchObject({ commandId: input.commandId, clientSequence: 1, replayed: false });
    const stub = env.COMBAT_ROOMS.getByName(payload.matchId);
    const row = await runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{ client_sequence: number; result_json: string }>("SELECT client_sequence, result_json FROM commands WHERE player_id = ?", "host").one());
    expect(row.client_sequence).toBe(1);
    expect(JSON.parse(row.result_json)).toMatchObject({ event: { kind: "commandResult", accepted: false } });
    socket.send(input);
    expect(await socket.next("ack")).toEqual({ ...ack, replayed: true });
    const count = await runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM commands").one().count);
    expect(count).toBe(1);
    socket.close();
  });

  it("rejects changed identities, skipped sequences, and mismatched epochs", async () => {
    const payload = claims();
    const socket = await connect(payload);
    const initial = await socket.next("snapshot");
    const input = command(initial, 1, { kind: "reload" });
    socket.send(input);
    await socket.next("ack");
    socket.send({ ...input, command: { kind: "start" } });
    expect(await socket.next("error")).toMatchObject({ code: "idempotencyConflict" });
    socket.send(command(initial, 3, { kind: "reload" }));
    expect(await socket.next("error")).toMatchObject({ code: "sequenceConflict" });
    socket.send({ ...command(initial, 2, { kind: "reload" }), authorityEpoch: 99 });
    expect(await socket.next("error")).toMatchObject({ code: "epochMismatch" });
    socket.close();
  });

  it("restores durable outcomes while requiring a new authority/frame readiness handshake", async () => {
    const payload = claims();
    const socket = await connect(payload);
    const initial = await socket.next("snapshot");
    const input = command(initial, 1, { kind: "reload" });
    socket.send(input);
    const original = await socket.next("ack");
    socket.close();
    await socket.closed;
    const stub = env.COMBAT_ROOMS.getByName(payload.matchId);
    await evictDurableObject(stub, { webSockets: "close" });
    const restored = await connect(payload);
    const snapshot = await restored.next("snapshot");
    expect(snapshot.snapshot.authorityEpoch).toBe(initial.snapshot.authorityEpoch + 1);
    expect(snapshot.snapshot.frameEpoch).toBe(initial.snapshot.frameEpoch);
    expect(snapshot.clientSequence).toBe(1);
    expect(snapshot.snapshot.players.every((player) => !player.frameReady)).toBe(true);
    expect(snapshot.snapshot.projectiles).toHaveLength(0);
    restored.send(input);
    expect(await restored.next("ack")).toEqual({ ...original, replayed: true });
    restored.send(command(initial, 2, { kind: "reload" }));
    expect(await restored.next("error")).toMatchObject({ code: "epochMismatch" });
    restored.close();
  });

  it("rolls back a failed durable command commit and never acknowledges it", async () => {
    const payload = claims();
    const socket = await connect(payload);
    const initial = await socket.next("snapshot");
    const stub = env.COMBAT_ROOMS.getByName(payload.matchId);
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec("CREATE TRIGGER reject_test_command BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT, 'test storage failure'); END");
    });
    socket.send(command(initial, 1, { kind: "reload" }));
    await socket.closed;
    expect(socket.messages.some((message) => message.type === "ack")).toBe(false);
    const recoveredStub = env.COMBAT_ROOMS.getByName(payload.matchId);
    const count = await runInDurableObject(recoveredStub, (_instance, state) => state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM commands").one().count);
    expect(count).toBe(0);
  });

  it("starts a ready two-phone match and persists one projectile before both phones see it", async () => {
    const payload = claims();
    const host = await connect(payload);
    const hostState = await host.next("snapshot");
    const guest = await connect({ ...payload, playerId: "guest" });
    const guestState = await guest.next("snapshot");
    const ready = { kind: "frameReady" as const, ready: true, residualMeters: 0.01, residualDegrees: 0.1, clockUncertaintyMs: 1 };
    guest.send(command(guestState, 1, ready));
    guest.send(command(guestState, 2, { kind: "pose", observations: [], pose: {
      sequence: 1, capturedAtMs: guestState.snapshot.matchTimeMs, position: [0, 0, -6], orientation: [0, 0, 0, 1], tracking: "normal",
    } }));
    host.send(command(hostState, 1, ready));
    host.send(command(hostState, 2, { kind: "pose", observations: [], pose: {
      sequence: 1, capturedAtMs: hostState.snapshot.matchTimeMs, position: [0, 0, 0], orientation: [0, 0, 0, 1], tracking: "normal",
    } }));
    host.send(command(hostState, 3, { kind: "start" }));
    host.send(command(hostState, 4, { kind: "fire", shotId: "projectile-first", poseSequence: 1, origin: [0, 0, 0], direction: [0, 0, -1] }));
    const acknowledged = await host.next("ack", (ack) => ack.clientSequence === 4);
    expect(acknowledged.replayed).toBe(false);
    const onHost = await host.next("events", (batch) => batch.events.some((event) => event.event.kind === "projectileSpawn"));
    const onGuest = await guest.next("events", (batch) => batch.events.some((event) => event.event.kind === "projectileSpawn"));
    const spawned = onHost.events.find((event) => event.event.kind === "projectileSpawn");
    expect(onGuest.events).toContainEqual(spawned);
    const persisted = await runInDurableObject(env.COMBAT_ROOMS.getByName(payload.matchId), (_instance, state) => state.storage.sql.exec<{ checkpoint: string }>("SELECT checkpoint FROM room").one().checkpoint);
    const checkpoint: unknown = JSON.parse(persisted);
    const expectedHost: unknown = expect.objectContaining({ playerId: "host", ammo: 7 });
    const expectedPlayers: unknown = expect.arrayContaining([expectedHost]);
    expect(checkpoint).toMatchObject({ snapshot: { phase: "running", players: expectedPlayers } });
    host.close(); guest.close();
  });
});

describe("bounded transport and idle lifecycle", () => {
  it("closes oversized, malformed, and binary frames", async () => {
    for (const message of ["x".repeat(LIMITS.messageBytes + 1), "not-json", new ArrayBuffer(4)]) {
      const socket = await connect(claims());
      await socket.next("snapshot");
      socket.socket.send(message);
      expect([1008, 1009]).toContain(await socket.closed);
    }
  });

  it("bounds socket input floods", async () => {
    const socket = await connect(claims(), false);
    await socket.next("snapshot");
    for (let index = 0; index < 120; index += 1) socket.socket.send(JSON.stringify({ type: "ping", nonce: `ping-${index}`, clientSentAtMs: index }));
    expect(await socket.closed).toBe(4008);
  });

  it("disconnects a non-acknowledging receiver before its outbound queue grows without bound", async () => {
    const socket = await connect(claims(), false);
    const initial = await socket.next("snapshot");
    const closed = new Promise<string>((resolve) => socket.socket.addEventListener("close", (event) => resolve(event.reason)));
    let sequence = 0;
    for (let batch = 0; batch < 14 && socket.socket.readyState === WebSocket.OPEN; batch += 1) {
      for (let index = 0; index < 20; index += 1) socket.send(command(initial, ++sequence, { kind: "reload" }));
      await new Promise((resolve) => setTimeout(resolve, 350));
    }
    expect(await closed).toBe("resume-required");
  });

  it("uses the alarm for idle retention cleanup without advancing combat", async () => {
    const payload = claims();
    const socket = await connect(payload);
    await socket.next("snapshot");
    socket.close();
    await socket.closed;
    const stub = env.COMBAT_ROOMS.getByName(payload.matchId);
    await runInDurableObject(stub, async (_instance, state) => {
      state.storage.sql.exec("UPDATE room SET last_activity_ms = ?", Date.now() - 25 * 60 * 60 * 1000);
      // Cleanup is permitted only after durable projection delivery completed.
      state.storage.sql.exec("DELETE FROM projection_outbox");
      await state.storage.setAlarm(Date.now() + 1000);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const tables = await runInDurableObject(stub, (_instance, state) => state.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'room'").toArray());
    expect(tables).toHaveLength(0);
    const recreated = await connect(payload);
    expect((await recreated.next("snapshot")).clientSequence).toBe(0);
    recreated.close();
  });

  it("retains undelivered spectator outcomes when idle retention expires", async () => {
    const payload = claims();
    const socket = await connect(payload);
    await socket.next("snapshot"); socket.close(); await socket.closed;
    const stub = env.COMBAT_ROOMS.getByName(payload.matchId);
    await runInDurableObject(stub, async (_instance, state) => {
      state.storage.sql.exec("UPDATE room SET last_activity_ms = ?", Date.now() - 25 * 60 * 60 * 1000);
      await state.storage.setAlarm(Date.now() + 1000);
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const counts = await runInDurableObject(stub, (_instance, state) => ({
      room: state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM room").one().count,
      pending: state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM projection_outbox").one().count,
    }));
    expect(counts.room).toBe(1); expect(counts.pending).toBeGreaterThan(0);
  });
});
