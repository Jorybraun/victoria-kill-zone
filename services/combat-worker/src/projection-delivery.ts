import type { ProjectionStore } from "./projection-store.js";
import { QueueFullError, type SerialQueue } from "./serial-queue.js";

const encoder = new TextEncoder();
const TIMEOUT_MS = 5000;

export function projectionConfigured(env: Env): boolean {
  if (typeof env.COMBAT_PROJECTION_SECRET !== "string" || encoder.encode(env.COMBAT_PROJECTION_SECRET).byteLength < 32) return false;
  try {
    const url = new URL(env.CONVEX_URL);
    return url.protocol === "https:" && url.username === "" && url.password === "" && url.pathname === "/" && url.search === "" && url.hash === "";
  } catch { return false; }
}

/** Network retries never hold the room's serial combat queue. */
export class ProjectionDelivery {
  private running = false;
  private failures = 0;
  private nextAttemptAt = 0;

  constructor(
    private readonly env: Env,
    private readonly storage: DurableObjectStorage,
    private readonly queue: SerialQueue,
    private readonly outbox: ProjectionStore,
    private readonly storageFailure: () => never,
    private readonly transport: (request: Request) => Promise<Response> = (request) => fetch(request),
  ) {}

  async flush(now: number, urgent = false): Promise<void> {
    if (this.running || (now < this.nextAttemptAt && (!urgent || this.failures > 0)) || !projectionConfigured(this.env)) return;
    this.running = true;
    let stage: "seal" | "sign" | "send" | "receipt" | "acknowledge" = "seal";
    try {
      // Bound each invocation. Remaining rows resume on the next active tick
      // or maintenance alarm, including after a process restart.
      for (let count = 0; count < 4; count += 1) {
        stage = "seal";
        const row = await this.durable(async () => {
          const selected = this.outbox.take();
          if (selected !== null) await this.storage.sync();
          return selected;
        });
        if (row === null) return;
        stage = "sign";
        const key = await crypto.subtle.importKey("raw", encoder.encode(this.env.COMBAT_PROJECTION_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
        const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`vkz-projection-v1.${row.payload}`)));
        const signature = [...digest].map((value) => value.toString(16).padStart(2, "0")).join("");
        stage = "send";
        const response = await this.transport(new Request(new URL("/api/mutation", this.env.CONVEX_URL), {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ path: "combat:publishProjection", args: { payload: row.payload, signature }, format: "json" }),
          signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "manual",
        }));
        if (!response.ok) { await response.body?.cancel(); throw new Error("Projection endpoint refused delivery"); }
        stage = "receipt";
        // The trusted endpoint still has a bounded response contract.
        const result = await readResult(response);
        if (!isAcknowledgment(result, row.through_sequence)) throw new Error("Projection endpoint returned mismatched receipt");
        stage = "acknowledge";
        await this.durable(async () => { this.outbox.acknowledge(row); await this.storage.sync(); });
        this.failures = 0;
        this.nextAttemptAt = Date.now() + 250;
      }
    } catch {
      this.failures = Math.min(7, this.failures + 1);
      this.nextAttemptAt = Date.now() + Math.min(30_000, 250 * 2 ** this.failures);
      console.warn(JSON.stringify({ event: "combat_projection_delayed", stage, retryable: true }));
    } finally { this.running = false; }
  }

  private async durable<T>(work: () => Promise<T>): Promise<T> {
    try { return await this.queue.run(work); }
    catch (error) {
      if (error instanceof QueueFullError) throw error;
      return this.storageFailure();
    }
  }
}

async function readResult(response: Response): Promise<unknown> {
  if (response.body === null) return null;
  const reader: ReadableStreamDefaultReader<unknown> = response.body.getReader();
  const buffer = new Uint8Array(4096);
  let length = 0;
  try {
    for (;;) {
      const result = await reader.read();
      if (result.done) break;
      if (!(result.value instanceof Uint8Array) || length + result.value.byteLength > buffer.byteLength) return null;
      buffer.set(result.value, length); length += result.value.byteLength;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(buffer.subarray(0, length))) as unknown;
  } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
}

function isAcknowledgment(value: unknown, sequence: number): boolean {
  if (value === null || typeof value !== "object" || !("status" in value) || value.status !== "success" || !("value" in value)) return false;
  const result = value.value;
  return result !== null && typeof result === "object" && "eventSequence" in result && result.eventSequence === sequence && "replayed" in result && typeof result.replayed === "boolean";
}
