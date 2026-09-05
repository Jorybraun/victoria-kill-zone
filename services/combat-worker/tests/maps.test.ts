import { env, exports as workerExports } from "cloudflare:workers";
import { abortAllDurableObjects, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { LIMITS, type CombatTicketClaims } from "@vkz/combat-protocol";
import { claims, command, connect, token } from "./helpers.js";

afterEach(async () => { await abortAllDurableObjects(); });

async function mapRequest(payload: CombatTicketClaims, options: { body?: BodyInit; frameEpoch?: number; contentType?: string } = {}): Promise<Response> {
  const headers = { Authorization: `Bearer ${await token(payload)}`, "Content-Type": options.contentType ?? "application/octet-stream" };
  const request = new Request(`https://combat.test/v1/matches/${encodeURIComponent(payload.matchId)}/frames/${options.frameEpoch ?? payload.frameEpoch}/map`, {
    method: options.body === undefined ? "GET" : "PUT", headers,
    ...(options.body === undefined ? {} : { body: options.body }),
  });
  return workerExports.default.fetch(request);
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((value) => value.toString(16).padStart(2, "0")).join("");
}

describe("immutable authenticated shared AR maps", () => {
  it("requires a frozen room, host upload, matching frame, and identical signed membership", async () => {
    const payload = claims();
    const bytes = new Uint8Array([1, 2, 3]);
    expect((await mapRequest(payload, { body: bytes })).status).toBe(404);
    const socket = await connect(payload);
    await socket.next("snapshot");
    expect((await mapRequest({ ...payload, playerId: "guest" }, { body: bytes })).status).toBe(403);
    expect((await mapRequest(payload, { body: bytes, frameEpoch: 2 })).status).toBe(409);
    expect((await mapRequest({ ...payload, authorityEpoch: 2 }, { body: bytes })).status).toBe(409);
    expect((await mapRequest({ ...payload, roster: payload.roster.map((member) => ({ ...member, displayName: "Changed" })) }, { body: bytes })).status).toBe(409);
    expect((await mapRequest(payload, { body: bytes, contentType: "text/plain" })).status).toBe(415);
    expect((await mapRequest(payload)).status).toBe(404);
    socket.close();
  });

  it("stores a full 8 MiB map in bounded chunks and returns its exact digest to every member", async () => {
    const payload = claims({ matchId: `map:${crypto.randomUUID()}` });
    const socket = await connect(payload);
    await socket.next("snapshot");
    const bytes = new Uint8Array(LIMITS.mapBytes).fill(37);
    const expected = await sha256(bytes);
    const uploaded = await mapRequest(payload, { body: bytes });
    expect(uploaded.status).toBe(201);
    expect(uploaded.headers.get("x-vkz-frame-id")).toBe(expected);
    expect(uploaded.headers.get("etag")).toBe(`"${expected}"`);
    const rows = await runInDurableObject(env.COMBAT_ROOMS.getByName(payload.matchId), (_instance, state) => state.storage.sql.exec<{ count: number; max_bytes: number; total: number }>("SELECT COUNT(*) AS count, MAX(length(payload)) AS max_bytes, SUM(length(payload)) AS total FROM map_chunks").one());
    expect(rows).toEqual({ count: 64, max_bytes: 128 * 1024, total: LIMITS.mapBytes });
    const downloaded = await mapRequest({ ...payload, playerId: "guest" });
    expect(downloaded.headers.get("Content-Type")).toBe("application/octet-stream");
    expect(downloaded.headers.get("Content-Length")).toBe(String(bytes.byteLength));
    expect(downloaded.headers.get("x-vkz-frame-id")).toBe(expected);
    expect(await sha256(new Uint8Array(await downloaded.arrayBuffer()))).toBe(expected);
    socket.close();
  });

  it("allows identical upload retry and refuses replacement content", async () => {
    const payload = claims();
    const socket = await connect(payload);
    await socket.next("snapshot");
    const bytes = new Uint8Array([7, 8, 9]);
    expect((await mapRequest(payload, { body: bytes })).status).toBe(201);
    expect((await mapRequest(payload, { body: bytes })).status).toBe(200);
    expect((await mapRequest(payload, { body: new Uint8Array([9, 8, 7]) })).status).toBe(409);
    expect(new Uint8Array(await (await mapRequest(payload)).arrayBuffer())).toEqual(bytes);
    socket.close();
  });

  it("rejects oversized streaming bodies without leaving any visible or partial map", async () => {
    const payload = claims();
    const socket = await connect(payload);
    await socket.next("snapshot");
    let remaining = LIMITS.mapBytes + 1;
    const body = new ReadableStream<Uint8Array>({ pull(controller) {
      const count = Math.min(128 * 1024, remaining);
      if (count === 0) { controller.close(); return; }
      controller.enqueue(new Uint8Array(count)); remaining -= count;
    } });
    expect((await mapRequest(payload, { body })).status).toBe(413);
    expect((await mapRequest(payload)).status).toBe(404);
    const count = await runInDurableObject(env.COMBAT_ROOMS.getByName(payload.matchId), (_instance, state) => state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM map_chunks").one().count);
    expect(count).toBe(0);
    socket.close();
  });

  it("keeps combat moving during an incomplete upload and limits concurrent upload memory", async () => {
    const payload = claims();
    const socket = await connect(payload);
    const initial = await socket.next("snapshot");
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
    const body = new ReadableStream<Uint8Array>({ start(value) { controller = value; value.enqueue(new Uint8Array([1])); } });
    const uploaded = mapRequest(payload, { body });
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect((await mapRequest(payload, { body: new Uint8Array([2]) })).status).toBe(429);
    expect((await mapRequest(payload)).status).toBe(404);
    socket.send(command(initial, 1, { kind: "reload" }));
    expect((await socket.next("ack")).clientSequence).toBe(1);
    controller?.enqueue(new Uint8Array([2, 3]));
    controller?.close();
    expect((await uploaded).status).toBe(201);
    expect(new Uint8Array(await (await mapRequest(payload)).arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]));
    socket.close();
  });
});
