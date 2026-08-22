import { useEffect, useState } from "react";

import type {
  SpectatorDataSource,
  SpectatorSnapshot,
} from "../domain/spectator";
import { formatCountdown, formatPhase } from "../lib/format";

export type FeedConnection = "connected" | "degraded" | "restored";

export interface MatchHeaderProps {
  snapshot: SpectatorSnapshot;
  source: SpectatorDataSource;
  connection: FeedConnection;
}

function titleFor(snapshot: SpectatorSnapshot): string {
  switch (snapshot.match.phase) {
    case "lobby":
      return "WAITING FOR DUEL";
    case "countdown":
      return "DUEL STARTS IN";
    case "running":
      return "LIVE DUEL";
    case "finished":
      return "DUEL COMPLETE";
    case "cancelled":
      return "DUEL CANCELLED";
  }
}

function connectionCopy(connection: FeedConnection): string {
  switch (connection) {
    case "connected":
      return "CONNECTED";
    case "degraded":
      return "RECONNECTING";
    case "restored":
      return "CONNECTED";
  }
}

function Countdown({ snapshot }: { snapshot: SpectatorSnapshot }) {
  const [elapsed, setElapsed] = useState(0);

  useEffect(() => {
    const interval = window.setInterval(
      () => setElapsed((value) => value + 1_000),
      1_000,
    );
    return () => window.clearInterval(interval);
  }, []);

  const now = snapshot.serverNow + elapsed;
  const remaining = Math.max(0, (snapshot.match.startsAt ?? now) - now);

  return (
    <p className="countdown" aria-live="polite" aria-atomic="true">
      <span className="visually-hidden">DUEL STARTS IN </span>
      <span data-testid="countdown">{formatCountdown(remaining)}</span>
    </p>
  );
}

export function MatchHeader({
  snapshot,
  source,
  connection,
}: MatchHeaderProps) {
  return (
    <header className="match-header">
      <div className="brand-lockup">
        <p className="product-name">VICTORIA PEW PEW</p>
        <p className="product-descriptor">MARKERLESS 1V1 DUEL</p>
      </div>

      <div className="match-title">
        <h1>{titleFor(snapshot)}</h1>
        {snapshot.match.phase === "countdown" ? (
          <Countdown snapshot={snapshot} />
        ) : null}
      </div>

      <dl className="match-status" aria-label="Duel status">
        <div>
          <dt>DUEL CODE</dt>
          <dd data-testid="match-code">{snapshot.match.code}</dd>
        </div>
        <div>
          <dt>PHASE</dt>
          <dd>{formatPhase(snapshot.match.phase)}</dd>
        </div>
        <div>
          <dt>FEED</dt>
          <dd className={`connection connection--${connection}`}>
            <span className="status-shape" aria-hidden="true" />
            {connectionCopy(connection)}
          </dd>
        </div>
      </dl>

      {source === "demo" ? <p className="source-badge">DEMO FIXTURE</p> : null}
    </header>
  );
}
