import { useEffect, useState } from "react";

import {
  snapshotWithDedupedEvents,
  type SpectatorDataSource,
  type SpectatorSnapshot,
} from "../domain/spectator";

// Convex DefaultFunctionArgs requires a closed object type, not a mergeable interface.
// eslint-disable-next-line @typescript-eslint/consistent-type-definitions
export type SpectatorSnapshotRequest = {
  code: string;
};

export interface SpectatorSnapshotObserver {
  next: (snapshot: SpectatorSnapshot | null) => void;
  error: (error: Error) => void;
}

export interface SpectatorSnapshotAdapter {
  readonly source: SpectatorDataSource;
  subscribe(
    request: SpectatorSnapshotRequest,
    observer: SpectatorSnapshotObserver,
  ): () => void;
  dispose(): void;
}

export type SpectatorResourceState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "ready"; snapshot: SpectatorSnapshot | null }
  | {
      kind: "degraded";
      snapshot: SpectatorSnapshot;
      lastSyncedAt: number;
      error: Error;
    }
  | { kind: "recovery"; snapshot: SpectatorSnapshot }
  | { kind: "error"; error: Error };

interface SubscriptionResult {
  adapter: SpectatorSnapshotAdapter;
  code: string;
  retryToken: number;
  resource: Extract<
    SpectatorResourceState,
    { kind: "ready" | "degraded" | "recovery" | "error" }
  >;
}

const RECOVERY_ANNOUNCEMENT_MS = 1_800;

function retainedSnapshot(
  resource: SubscriptionResult["resource"],
): { snapshot: SpectatorSnapshot; lastSyncedAt: number } | null {
  switch (resource.kind) {
    case "ready":
      return resource.snapshot === null
        ? null
        : {
            snapshot: resource.snapshot,
            lastSyncedAt: resource.snapshot.serverNow,
          };
    case "degraded":
      return {
        snapshot: resource.snapshot,
        lastSyncedAt: resource.lastSyncedAt,
      };
    case "recovery":
      return {
        snapshot: resource.snapshot,
        lastSyncedAt: resource.snapshot.serverNow,
      };
    case "error":
      return null;
  }
}

function belongsToSubscription(
  result: SubscriptionResult | null,
  adapter: SpectatorSnapshotAdapter,
  code: string,
): result is SubscriptionResult {
  return result?.adapter === adapter && result.code === code;
}

export function useSpectatorSnapshot(
  adapter: SpectatorSnapshotAdapter,
  code: string | null,
  retryToken: number,
): SpectatorResourceState {
  const [result, setResult] = useState<SubscriptionResult | null>(null);

  useEffect(() => {
    if (code === null) {
      return;
    }

    let subscribed = true;
    const unsubscribe = adapter.subscribe(
      { code },
      {
        next(snapshot) {
          if (!subscribed) {
            return;
          }

          setResult((previous) => {
            const previousResource = belongsToSubscription(
              previous,
              adapter,
              code,
            )
              ? previous.resource
              : null;
            const wasInterrupted =
              previousResource?.kind === "degraded" ||
              previousResource?.kind === "error" ||
              previousResource?.kind === "recovery";
            const normalizedSnapshot =
              snapshot === null ? null : snapshotWithDedupedEvents(snapshot);

            return {
              adapter,
              code,
              retryToken,
              resource:
                normalizedSnapshot !== null && wasInterrupted
                  ? { kind: "recovery", snapshot: normalizedSnapshot }
                  : { kind: "ready", snapshot: normalizedSnapshot },
            };
          });
        },
        error(error) {
          if (!subscribed) {
            return;
          }

          setResult((previous) => {
            const retained = belongsToSubscription(previous, adapter, code)
              ? retainedSnapshot(previous.resource)
              : null;

            return {
              adapter,
              code,
              retryToken,
              resource:
                retained === null
                  ? { kind: "error", error }
                  : {
                      kind: "degraded",
                      snapshot: retained.snapshot,
                      lastSyncedAt: retained.lastSyncedAt,
                      error,
                    },
            };
          });
        },
      },
    );

    return () => {
      subscribed = false;
      unsubscribe();
    };
  }, [adapter, code, retryToken]);

  const isRecovering = code !== null && belongsToSubscription(result, adapter, code)
    && result.retryToken === retryToken && result.resource.kind === "recovery";
  useEffect(() => {
    if (!isRecovering || code === null) return;
    const timeout = window.setTimeout(() => {
      setResult(current =>
        belongsToSubscription(current, adapter, code) && current.retryToken === retryToken
          && current.resource.kind === "recovery"
          ? {...current, resource: {kind: "ready", snapshot: current.resource.snapshot}}
          : current,
      );
    }, RECOVERY_ANNOUNCEMENT_MS);
    return () => window.clearTimeout(timeout);
  }, [isRecovering, adapter, code, retryToken]);

  if (code === null) {
    return { kind: "idle" };
  }

  if (!belongsToSubscription(result, adapter, code)) {
    return { kind: "loading" };
  }

  if (result.retryToken !== retryToken) {
    const retained = retainedSnapshot(result.resource);
    return retained === null
      ? { kind: "loading" }
      : {
          kind: "degraded",
          snapshot: retained.snapshot,
          lastSyncedAt: retained.lastSyncedAt,
          error: new Error("The spectator feed is reconnecting."),
        };
  }

  return result.resource;
}
