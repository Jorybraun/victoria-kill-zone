import { LIMITS, type CombatTicketClaims } from "@vkz/combat-protocol";
import type { SerialQueue } from "./serial-queue.js";

const CHUNK_BYTES = 128 * 1024;
const TRANSFER_MS = 15_000;
type MapRow = { frame_epoch: number; frame_id: string; byte_length: number; chunks: number };
type Authorize = (claims: CombatTicketClaims, frameEpoch: number, upload: boolean) => Response | null;

/** Immutable bounded map storage, independent of the 20 Hz simulation queue. */
export class MapTransfer {
  private uploading = false;
  private downloads = 0;

  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly queue: SerialQueue,
    private readonly authorize: Authorize,
  ) {}

  async fetch(request: Request, claims: CombatTicketClaims, frameEpoch: number): Promise<Response> {
    if (request.method !== "GET" && request.method !== "PUT") return new Response(null, { status: 405, headers: { Allow: "GET, PUT" } });
    const refusal = await this.queue.run(() => this.authorize(claims, frameEpoch, request.method === "PUT"));
    if (refusal !== null) return refusal;
    return request.method === "PUT" ? this.upload(request, claims, frameEpoch) : this.download(frameEpoch);
  }

  private async upload(request: Request, claims: CombatTicketClaims, frameEpoch: number): Promise<Response> {
    if (request.headers.get("Content-Type") !== "application/octet-stream") return new Response(null, { status: 415 });
    const length = request.headers.get("Content-Length");
    if (length !== null && (!/^[0-9]+$/.test(length) || Number(length) > LIMITS.mapBytes)) return new Response(null, { status: 413 });
    if (request.body === null) return new Response(null, { status: 400 });
    if (this.uploading) return new Response(null, { status: 429, headers: { "Retry-After": "1" } });
    this.uploading = true;
    const reader: ReadableStreamDefaultReader<unknown> = request.body.getReader();
    const deadline = Date.now() + TRANSFER_MS;
    try {
      // One fixed 8 MiB buffer also bounds malicious one-byte/empty chunks.
      // Incomplete uploads never enter SQLite.
      const bytes = new Uint8Array(LIMITS.mapBytes);
      let byteLength = 0;
      for (;;) {
        const next = await readBefore(reader, deadline);
        if (next.done) break;
        if (byteLength + next.value.byteLength > LIMITS.mapBytes) return new Response(null, { status: 413 });
        bytes.set(next.value, byteLength);
        byteLength += next.value.byteLength;
      }
      if (byteLength === 0 || (length !== null && Number(length) !== byteLength)) return new Response(null, { status: 400 });
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.subarray(0, byteLength)));
      const frameId = [...digest].map((value) => value.toString(16).padStart(2, "0")).join("");
      return await this.queue.run(async () => {
        const refusal = this.authorize(claims, frameEpoch, true);
        if (refusal !== null) return refusal;
        const existing = this.find(frameEpoch);
        if (existing !== null) {
          if (existing.frame_id !== frameId || existing.byte_length !== byteLength) return new Response(null, { status: 409 });
          return new Response(null, { status: 200, headers: mapHeaders(existing) });
        }
        const map: MapRow = { frame_epoch: frameEpoch, frame_id: frameId, byte_length: byteLength, chunks: Math.ceil(byteLength / CHUNK_BYTES) };
        this.storage.transactionSync(() => {
          for (let index = 0; index < map.chunks; index += 1) {
            this.storage.sql.exec("INSERT INTO map_chunks(frame_epoch, chunk_index, payload) VALUES (?, ?, ?)", frameEpoch, index, bytes.slice(index * CHUNK_BYTES, Math.min(byteLength, (index + 1) * CHUNK_BYTES)));
          }
          this.storage.sql.exec("INSERT INTO shared_maps(frame_epoch, frame_id, byte_length, chunks) VALUES (?, ?, ?, ?)", frameEpoch, frameId, byteLength, map.chunks);
        });
        await this.storage.sync();
        return new Response(null, { status: 201, headers: mapHeaders(map) });
      });
    } catch (error) {
      if (error instanceof TransferTimeout) return new Response(null, { status: 408 });
      if (error instanceof InvalidUpload) return new Response(null, { status: 400 });
      throw error;
    } finally {
      this.uploading = false;
      await reader.cancel().catch(() => undefined);
      reader.releaseLock();
    }
  }

  private download(frameEpoch: number): Response {
    if (this.downloads >= LIMITS.players) return new Response(null, { status: 429, headers: { "Retry-After": "1" } });
    const map = this.find(frameEpoch);
    if (map === null) return new Response(null, { status: 404 });
    this.downloads += 1;
    let chunkIndex = 0;
    let finished = false;
    let timer: ReturnType<typeof setTimeout>;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      this.downloads -= 1;
    };
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        timer = setTimeout(() => { finish(); controller.error(new TransferTimeout()); }, TRANSFER_MS);
      },
      pull: (controller) => {
        if (finished) return;
        try {
          const row = this.storage.sql.exec<{ payload: ArrayBuffer }>("SELECT payload FROM map_chunks WHERE frame_epoch = ? AND chunk_index = ?", frameEpoch, chunkIndex).one();
          chunkIndex += 1;
          controller.enqueue(new Uint8Array(row.payload));
          if (chunkIndex === map.chunks) { finish(); controller.close(); }
        } catch (error) { finish(); controller.error(error); }
      },
      cancel: finish,
    }, { highWaterMark: 1 });
    return new Response(stream, { status: 200, headers: { ...mapHeaders(map), "Content-Type": "application/octet-stream", "Content-Length": String(map.byte_length) } });
  }

  private find(frameEpoch: number): MapRow | null {
    return this.storage.sql.exec<MapRow>("SELECT frame_epoch, frame_id, byte_length, chunks FROM shared_maps WHERE frame_epoch = ?", frameEpoch).toArray()[0] ?? null;
  }
}

function mapHeaders(map: MapRow): Record<string, string> {
  return { "x-vkz-frame-id": map.frame_id, ETag: `"${map.frame_id}"`, "Cache-Control": "private, no-store" };
}

class TransferTimeout extends Error {}
class InvalidUpload extends Error {}

async function readBefore(reader: ReadableStreamDefaultReader<unknown>, deadline: number): Promise<ReadableStreamReadResult<Uint8Array>> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const result = await Promise.race([
      reader.read().catch(() => { throw new InvalidUpload(); }),
      new Promise<never>((_resolve, reject) => { timer = setTimeout(() => reject(new TransferTimeout()), Math.max(1, deadline - Date.now())); }),
    ]);
    if (result.done) return { done: true, value: undefined };
    if (!(result.value instanceof Uint8Array)) throw new InvalidUpload();
    return { done: false, value: result.value };
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
