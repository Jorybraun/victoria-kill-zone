import { ConvexClient } from "convex/browser";
import { makeFunctionReference } from "convex/server";

import type { SpectatorSnapshot } from "../domain/spectator";
import type { SpectatorSnapshotAdapter, SpectatorSnapshotRequest } from "./spectatorAdapter";

const spectatorSnapshotQuery = makeFunctionReference<
  "query", SpectatorSnapshotRequest, SpectatorSnapshot | null
>("queries:spectatorSnapshot");

/** Query-only boundary. Socket recovery never invents a newer match timestamp. */
export function createConvexSpectatorAdapter(deploymentUrl: string): SpectatorSnapshotAdapter {
  // Creating the adapter is pure: React can discard a memoized render. The
  // committed subscription effect acquires the socket and its cleanup releases it.
  let client: ConvexClient | null = null;
  let disposed = false;
  const subscriptions = new Set<() => void>();
  return {
    source: "convex",
    subscribe(request, observer) {
      if (disposed) {
        observer.error(new Error("The spectator connection has already closed."));
        return () => undefined;
      }
      const connection = client ??= new ConvexClient(deploymentUrl);
      let active = true;
      let connected = connection.connectionState().isWebSocketConnected;
      let received: SpectatorSnapshot | null | undefined;
      let queryFailed = false;
      const disconnected = () => observer.error(new Error("The spectator connection was interrupted."));
      const unsubscribeConnection = connection.subscribeToConnectionState(state => {
        if (!active || connected === state.isWebSocketConnected) return;
        connected = state.isWebSocketConnected;
        if (!connected) disconnected();
        // Queries need not change on reconnect. Retain their original timestamp,
        // and announce only that the connection returned, not fresher authority.
        else if (received !== undefined && !queryFailed) observer.next(received);
      });
      const unsubscribeQuery = connection.onUpdate(spectatorSnapshotQuery, request, snapshot => {
        if (!active) return;
        received = snapshot;
        queryFailed = false;
        observer.next(snapshot);
        // Convex may deliver its cached query while the socket is reconnecting.
        if (!connected) disconnected();
      }, () => {
        if (!active) return;
        queryFailed = true;
        observer.error(new Error("The spectator match update is unavailable."));
      });
      const unsubscribe = () => {
        if (!active) return;
        active = false;
        unsubscribeConnection();
        unsubscribeQuery();
        subscriptions.delete(unsubscribe);
        if (subscriptions.size === 0 && client === connection) {
          client = null;
          void connection.close();
        }
      };
      subscriptions.add(unsubscribe);
      return unsubscribe;
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const unsubscribe of subscriptions) unsubscribe();
    },
  };
}
