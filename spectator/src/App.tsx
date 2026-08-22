import { useCallback, useEffect, useMemo, useState } from "react";

import { SpectatorShell } from "./components/SpectatorShell";
import { createConvexSpectatorAdapter } from "./data/convexSpectatorAdapter";
import { createDemoSpectatorAdapter } from "./data/demoFixtures";
import { resolveRuntime, type SpectatorRuntime } from "./data/runtime";
import {
  useSpectatorSnapshot,
  type SpectatorResourceState,
  type SpectatorSnapshotAdapter,
} from "./data/spectatorAdapter";
import {
  isValidMatchCode,
  normalizeMatchCode,
  viewKindForPhase,
  type SpectatorDataSource,
  type SpectatorSnapshot,
  type SpectatorViewState,
} from "./domain/spectator";

interface SpectatorRoute {
  code: string | null;
  initialCode: string;
  search: string;
}

function readRoute(): SpectatorRoute {
  const search = window.location.search;
  const rawCode = new URLSearchParams(search).get("match") ?? "";
  const initialCode = normalizeMatchCode(rawCode);
  return {
    code: isValidMatchCode(initialCode) ? initialCode : null,
    initialCode,
    search,
  };
}

function useSpectatorRoute(): [SpectatorRoute, (code: string | null) => void] {
  const [route, setRoute] = useState(readRoute);

  useEffect(() => {
    const handlePopState = () => setRoute(readRoute());
    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  const selectMatch = useCallback((code: string | null) => {
    const url = new URL(window.location.href);
    if (code === null) {
      url.searchParams.delete("match");
    } else {
      url.searchParams.set("match", normalizeMatchCode(code));
    }
    window.history.pushState({}, "", url);
    setRoute(readRoute());
  }, []);

  return [route, selectMatch];
}

function createConfigurationErrorAdapter(message: string): SpectatorSnapshotAdapter {
  return {
    source: "convex",
    subscribe(_request, observer) {
      observer.error(new Error(message));
      return () => undefined;
    },
    dispose() {
      // No client was created for an invalid configuration.
    },
  };
}

function hasExpectedCode(snapshot: SpectatorSnapshot, code: string): boolean {
  return normalizeMatchCode(snapshot.match.code) === code;
}

function toSnapshotViewState(
  snapshot: SpectatorSnapshot,
  code: string,
  source: SpectatorDataSource,
): SpectatorViewState {
  const kind = viewKindForPhase(snapshot.match.phase);
  return { kind, code, source, snapshot };
}

function initialErrorReason(runtime: SpectatorRuntime): "network" | "unknown" {
  return runtime.kind === "configuration-error" ? "unknown" : "network";
}

function toViewState(
  resource: SpectatorResourceState,
  code: string,
  source: SpectatorDataSource,
  runtime: SpectatorRuntime,
): SpectatorViewState {
  switch (resource.kind) {
    case "idle":
    case "loading":
      return { kind: "loading", code, source };
    case "error":
      return {
        kind: "error",
        code,
        source,
        reason: initialErrorReason(runtime),
      };
    case "ready": {
      if (resource.snapshot === null) {
        return { kind: "error", code, source, reason: "not-found" };
      }
      if (!hasExpectedCode(resource.snapshot, code)) {
        return { kind: "error", code, source, reason: "unknown" };
      }
      return toSnapshotViewState(resource.snapshot, code, source);
    }
    case "degraded":
      return hasExpectedCode(resource.snapshot, code)
        ? {
            kind: "degraded",
            code,
            source,
            snapshot: resource.snapshot,
            lastSyncedAt: resource.lastSyncedAt,
          }
        : { kind: "error", code, source, reason: "unknown" };
    case "recovery":
      return hasExpectedCode(resource.snapshot, code)
        ? {
            kind: "recovery",
            currentKind: viewKindForPhase(resource.snapshot.match.phase),
            code,
            source,
            snapshot: resource.snapshot,
          }
        : { kind: "error", code, source, reason: "unknown" };
  }
}

export function App() {
  const [route, selectMatch] = useSpectatorRoute();
  const [retryToken, setRetryToken] = useState(0);
  const runtime = useMemo(
    () =>
      resolveRuntime(
        import.meta.env.VITE_CONVEX_URL,
        new URLSearchParams(route.search),
      ),
    [route.search],
  );

  const adapter = useMemo(() => {
    switch (runtime.kind) {
      case "demo":
        return createDemoSpectatorAdapter(runtime.fixture);
      case "convex":
        return createConvexSpectatorAdapter(runtime.deploymentUrl);
      case "configuration-error":
        return createConfigurationErrorAdapter(runtime.message);
    }
  }, [runtime]);

  useEffect(
    () => () => {
      adapter.dispose();
    },
    [adapter],
  );

  const resource = useSpectatorSnapshot(adapter, route.code, retryToken);
  const state: SpectatorViewState =
    route.code === null
      ? {
          kind: "no-selection",
          initialCode: route.initialCode,
          isDemo: runtime.kind === "demo",
        }
      : toViewState(resource, route.code, adapter.source, runtime);

  return (
    <SpectatorShell
      state={state}
      onSelectMatch={(code) => {
        setRetryToken(0);
        selectMatch(code);
      }}
      onRetry={() => setRetryToken((value) => value + 1)}
    />
  );
}
