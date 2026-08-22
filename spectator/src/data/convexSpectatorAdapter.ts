import { ConvexClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

import type { SpectatorSnapshot } from "../domain/spectator";
import type {
  SpectatorSnapshotAdapter,
  SpectatorSnapshotObserver,
  SpectatorSnapshotRequest,
} from "./spectatorAdapter";

const spectatorSnapshotQuery = makeFunctionReference<
  "query",
  SpectatorSnapshotRequest,
  SpectatorSnapshot | null
>("queries:spectatorSnapshot");

/**
 * Query-only boundary. The returned object intentionally exposes no mutation,
 * action, authentication, or raw Convex client methods.
 */
export function createConvexSpectatorAdapter(
  deploymentUrl: string,
): SpectatorSnapshotAdapter {
  const client = new ConvexClient(deploymentUrl);
  let disposed = false;

  return {
    source: "convex",
    subscribe(
      request: SpectatorSnapshotRequest,
      observer: SpectatorSnapshotObserver,
    ) {
      if (disposed) {
        observer.error(new Error("The spectator connection has already closed."));
        return () => undefined;
      }

      const unsubscribe = client.onUpdate(
        spectatorSnapshotQuery,
        request,
        (snapshot) => observer.next(snapshot),
        () =>
          observer.error(
            new Error(
              "The live spectator feed is unavailable. Check the match code and connection.",
            ),
          ),
      );

      return () => unsubscribe();
    },
    dispose() {
      if (!disposed) {
        disposed = true;
        void client.close();
      }
    },
  };
}
