import { createHmac, randomBytes } from "node:crypto";
import { createTestHarness } from "wrangler";
import type { CombatTicketClaims } from "@vkz/combat-protocol";
import { parseCheckpoint } from "@vkz/combat-simulation";
import type { LoadSocket } from "./load-client.js";
import type { DurableLoadState, LoadRuntime } from "./load-runtime.js";

type DurableRow = {
  checkpoint: string;
  authority_epoch: number;
  event_sequence: number;
  ledger_json: string;
  bullets: number;
  unresolved: number;
  commands: number;
  projection_rows: number;
  queued_sequence: number;
  delivered_sequence: number;
};

// One statement observes the checkpoint, counts, projection cursor and ordered
// ledger together, even while the room continues committing idle authority ticks.
const DURABLE_STATE_SQL = `
  SELECT checkpoint, authority_epoch, event_sequence,
    (SELECT json_group_array(json_object('sequence', sequence, 'payload', payload))
      FROM (SELECT sequence, payload FROM bullet_events ORDER BY sequence)) AS ledger_json,
    (SELECT COUNT(*) FROM bullets) AS bullets,
    (SELECT COUNT(*) FROM bullets WHERE terminal_sequence IS NULL) AS unresolved,
    (SELECT COUNT(*) FROM commands) AS commands,
    (SELECT COUNT(*) FROM projection_outbox) AS projection_rows,
    (SELECT queued_sequence FROM projection_progress WHERE singleton = 1) AS queued_sequence,
    (SELECT delivered_sequence FROM projection_progress WHERE singleton = 1) AS delivered_sequence
  FROM room WHERE singleton = 1
`;

function decodeLedger(encoded: string): DurableLoadState["ledger"] {
  const decoded: unknown = JSON.parse(encoded);
  if (!Array.isArray(decoded)) throw new Error("Durable load ledger is not an array");
  const entries: unknown[] = decoded;
  return entries.map(entry => {
    if (entry === null || typeof entry !== "object" || !("sequence" in entry) || !("payload" in entry)
      || typeof entry.sequence !== "number" || !Number.isSafeInteger(entry.sequence) || entry.sequence < 1 || typeof entry.payload !== "string") {
      throw new Error("Durable load ledger has an invalid row");
    }
    return { sequence: entry.sequence, payload: entry.payload };
  });
}

/** Node drives real authenticated WebSockets into a separate local workerd process. */
export async function createNodeRuntime(signal?: AbortSignal): Promise<{ runtime: LoadRuntime; close(): Promise<void> }> {
  if (signal?.aborted) throw new Error("Load cancelled");
  // Per-run signing material lives only in memory. Override both declared secrets
  // and the projection URL so no developer credentials or remote projection are used.
  const ticketKey = randomBytes(32).toString("hex");
  const server = createTestHarness({ workers: [{
    configPath: new URL("../wrangler.jsonc", import.meta.url),
    vars: { CONVEX_URL: "" },
    secrets: { COMBAT_TICKET_SECRET: ticketKey, COMBAT_PROJECTION_SECRET: randomBytes(32).toString("hex") },
  }] });
  const sockets = new Set<LoadSocket>();
  let closePromise: Promise<void> | undefined;
  const close = (): Promise<void> => closePromise ??= (async () => {
    try {
      for (const socket of sockets) if (socket.readyState === 1) socket.close(1000, "load-complete");
      sockets.clear();
    } finally { await server.close(); }
  })();
  let abortStartup: () => void = () => {};
  const cancelled = new Promise<never>((_resolve, reject) => {
    abortStartup = () => { reject(new Error("Load cancelled")); };
    signal?.addEventListener("abort", abortStartup, { once: true });
  });
  const startup = (async () => {
    try { await server.listen(); }
    finally {
      if (signal?.aborted) {
        // close() may have completed before a late listen() creates its resources.
        // Serialize a final teardown even when that late startup fails.
        await close();
        await server.close();
      }
    }
    if (signal?.aborted) throw new Error("Load cancelled");
    return server.getWorker("vkz-combat");
  })();
  let worker: Awaited<typeof startup>;
  try { worker = await Promise.race([startup, cancelled]); }
  catch (error) { await close(); throw error; }
  finally { signal?.removeEventListener("abort", abortStartup); }

  const signedTicket = (ticket: CombatTicketClaims): string => {
    const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
    const payload = Buffer.from(JSON.stringify(ticket)).toString("base64url");
    const content = `${header}.${payload}`;
    return `${content}.${createHmac("sha256", ticketKey).update(content).digest("base64url")}`;
  };
  const runtime: LoadRuntime = {
    environment: "node-client-workerd-authority",
    clockMode: "native",
    async upgrade(ticket) {
      if (closePromise) throw new Error("Node load runtime is closed");
      // Harness fetch preserves a 101 response and its Miniflare WebSocket;
      // Node's global fetch cannot perform this authenticated upgrade.
      const response = await worker.fetch(`/v1/matches/${encodeURIComponent(ticket.matchId)}/connect`, {
        headers: { Upgrade: "websocket", Authorization: `Bearer ${signedTicket(ticket)}` },
      });
      const socket = response.webSocket;
      if (closePromise) {
        // Cancellation can close the harness while its upgrade is still pending.
        // Never hand that late socket to an already stopped scenario.
        if (socket !== null && socket.readyState === 1) {socket.accept(); socket.close(1000, "load-cancelled");}
        else await response.body?.cancel();
        throw new Error("Node load runtime is closed");
      }
      if (socket !== null) {
        sockets.add(socket);
        socket.addEventListener("close", () => { sockets.delete(socket); });
      } else await response.body?.cancel();
      return { status: response.status, webSocket: socket };
    },
    async readDurable(matchId) {
      if (closePromise) throw new Error("Node load runtime is closed");
      const sql = await worker.getDurableObjectStorage("COMBAT_ROOMS", { name: matchId });
      const rows = await sql.exec<DurableRow>(DURABLE_STATE_SQL);
      const row = rows[0];
      if (rows.length !== 1 || row === undefined) throw new Error("Durable load room is unavailable");
      const checkpoint = parseCheckpoint(JSON.parse(row.checkpoint) as unknown);
      return {
        epoch: row.authority_epoch, sequence: row.event_sequence, snapshot: checkpoint.snapshot,
        ledger: decodeLedger(row.ledger_json), bullets: row.bullets, unresolved: row.unresolved,
        commands: row.commands, projectionRows: row.projection_rows,
        projectionProgress: { queued_sequence: row.queued_sequence, delivered_sequence: row.delivered_sequence },
        checkpointBytes: Buffer.byteLength(row.checkpoint, "utf8"), databaseBytes: null,
      };
    },
  };
  return { runtime, close };
}
