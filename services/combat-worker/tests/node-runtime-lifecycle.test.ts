import {beforeEach, describe, expect, it, vi} from "vitest";
import {createNodeRuntime} from "../benchmarks/node-runtime.js";

const harness = vi.hoisted(() => ({
  listen: vi.fn<() => Promise<void>>(),
  getWorker: vi.fn(() => ({})),
  close: vi.fn<() => Promise<void>>(),
}));
const factory = vi.hoisted(() => vi.fn(() => harness));
vi.mock("wrangler", () => ({createTestHarness: factory}));

beforeEach(() => {
  vi.clearAllMocks();
  harness.listen.mockReset().mockResolvedValue(undefined);
  harness.getWorker.mockReset().mockReturnValue({});
  harness.close.mockReset().mockResolvedValue(undefined);
});

function deferred() {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}

describe("Node load runtime startup ownership", () => {
  it("does not create a harness when already cancelled", async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(createNodeRuntime(controller.signal)).rejects.toThrow("Load cancelled");
    expect(factory).not.toHaveBeenCalled();
  });

  for (const stage of ["listen", "getWorker"] as const) {
    it(`closes the harness before propagating ${stage} failure`, async () => {
      const failure = new Error(`${stage} failed`);
      if (stage === "listen") harness.listen.mockRejectedValue(failure);
      else harness.getWorker.mockImplementation(() => {throw failure;});
      const controller = new AbortController();
      const remove = vi.spyOn(controller.signal, "removeEventListener");
      await expect(createNodeRuntime(controller.signal)).rejects.toBe(failure);
      expect(harness.close).toHaveBeenCalledTimes(1);
      expect(remove).toHaveBeenCalledWith("abort", expect.any(Function));
      if (stage === "listen") expect(harness.getWorker).not.toHaveBeenCalled();
    });
  }

  for (const late of ["resolve", "reject"] as const) {
    it(`cancels unresolved startup and owns its late ${late}`, async () => {
      const listen = deferred();
      harness.listen.mockReturnValue(listen.promise);
      let active = false;
      harness.close.mockImplementation(() => {active = false; return Promise.resolve();});
      const controller = new AbortController();
      const remove = vi.spyOn(controller.signal, "removeEventListener");
      const result = createNodeRuntime(controller.signal).catch((error: unknown) => error);
      expect(harness.listen).toHaveBeenCalledTimes(1);
      controller.abort();
      expect(await result).toEqual(new Error("Load cancelled"));
      expect(harness.close).toHaveBeenCalledTimes(1);
      expect(active).toBe(false);
      expect(remove).toHaveBeenCalledWith("abort", expect.any(Function));
      active = true;
      if (late === "resolve") listen.resolve();
      else listen.reject(new Error("Late startup failure"));
      // Drain promise continuations; the late path has no timers or retry loop.
      await listen.promise.catch(() => {});
      await Promise.resolve();
      await Promise.resolve();
      expect(active).toBe(false);
      expect(harness.close).toHaveBeenCalledTimes(2);
      expect(harness.getWorker).not.toHaveBeenCalled();
      expect(await result).toEqual(new Error("Load cancelled"));
    });
  }

  it("returns a closeable runtime and removes startup cancellation ownership", async () => {
    const controller = new AbortController();
    const remove = vi.spyOn(controller.signal, "removeEventListener");
    const session = await createNodeRuntime(controller.signal);
    expect(harness.getWorker).toHaveBeenCalledWith("vkz-combat");
    expect(remove).toHaveBeenCalledWith("abort", expect.any(Function));
    controller.abort();
    expect(harness.close).not.toHaveBeenCalled();
    await Promise.all([session.close(), session.close()]);
    expect(harness.close).toHaveBeenCalledTimes(1);
  });
});
