import { describe, expect, it } from "vitest";
import { HEARTBEAT_INTERVAL_MS, PRESENCE_TIMEOUT_MS } from "../domain/contract.js";
import {
  isFresh,
  isPresent,
  presenceExpiresAt,
  shouldExpirePresence,
} from "../domain/presence.js";

const T0 = 1_760_000_000_000;

describe("presence freshness", () => {
  it("leaves room for two missed heartbeats before going stale", () => {
    expect(PRESENCE_TIMEOUT_MS).toBeGreaterThanOrEqual(HEARTBEAT_INTERVAL_MS * 2);
  });

  it("is fresh up to, but not at, the timeout", () => {
    expect(isFresh(T0, T0)).toBe(true);
    expect(isFresh(T0, T0 + PRESENCE_TIMEOUT_MS - 1)).toBe(true);
    expect(isFresh(T0, T0 + PRESENCE_TIMEOUT_MS)).toBe(false);
  });

  it("requires both the stored flag and a fresh heartbeat", () => {
    expect(isPresent({ connected: true, lastSeenAt: T0 }, T0)).toBe(true);
    expect(isPresent({ connected: false, lastSeenAt: T0 }, T0)).toBe(false);
    // A missed expiry job must not be able to grant liveness.
    expect(isPresent({ connected: true, lastSeenAt: T0 }, T0 + PRESENCE_TIMEOUT_MS)).toBe(false);
  });

  it("expires a heartbeat exactly one timeout later", () => {
    expect(presenceExpiresAt(T0)).toBe(T0 + PRESENCE_TIMEOUT_MS);
  });
});

describe("shouldExpirePresence", () => {
  const player = { connected: true, lastSeenAt: T0 };
  const dueAt = T0 + PRESENCE_TIMEOUT_MS;

  it("clears presence at its own boundary", () => {
    expect(shouldExpirePresence(player, T0, dueAt)).toBe(true);
  });

  it("writes nothing before its boundary", () => {
    expect(shouldExpirePresence(player, T0, dueAt - 1)).toBe(false);
  });

  it("is superseded by a newer heartbeat", () => {
    const renewed = { connected: true, lastSeenAt: T0 + HEARTBEAT_INTERVAL_MS };

    expect(shouldExpirePresence(renewed, T0, dueAt)).toBe(false);
    expect(shouldExpirePresence(renewed, renewed.lastSeenAt, dueAt)).toBe(false);
  });

  it("is idempotent for an already disconnected player", () => {
    expect(shouldExpirePresence({ ...player, connected: false }, T0, dueAt)).toBe(false);
  });
});
