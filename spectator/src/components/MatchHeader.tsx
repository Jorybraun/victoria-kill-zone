import { useEffect, useState } from "react";

import {
  displayPhase,
  type SpectatorDataSource,
  type SpectatorSnapshot,
} from "../domain/spectator";

import { formatCountdown, formatPhase } from "../lib/format";

export type FeedConnection = "connected" | "degraded" | "restored";

export interface MatchHeaderProps {
  snapshot: SpectatorSnapshot;
  source: SpectatorDataSource;
  connection: FeedConnection;
}

function titleFor(snapshot: SpectatorSnapshot): string {
  const isArena = snapshot.match.combatMode === "durableObject";
  switch (displayPhase(snapshot.match)) {
    case "lobby":
      return isArena ? "ARENA LOBBY" : "WAITING FOR DUEL";
    case "calibrating": return "ALIGNING ARENA";
    case "paused": return "ARENA PAUSED";
    case "unavailable": return "MATCH STATE UNAVAILABLE";
    case "countdown":
      return "DUEL STARTS IN";
    case "running":
      return isArena ? "LIVE ARENA" : "LIVE DUEL";
    case "finished":
      return isArena ? "ARENA COMPLETE" : "DUEL COMPLETE";
    case "cancelled":
      return isArena ? "ARENA CANCELLED" : "DUEL CANCELLED";
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

function Countdown({ snapshot, elapsed }: { snapshot: SpectatorSnapshot; elapsed: number }) {
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
  const isArena = snapshot.match.combatMode === "durableObject";
  const phase = displayPhase(snapshot.match);
  // The shell keys this component by match and snapshot timestamp, not socket
  // state. Keep elapsed time here while the countdown is hidden during loss.
  const [receivedAt] = useState(() => performance.now());
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (phase !== "countdown") return;
    const interval = window.setInterval(
      () => setElapsed(Math.max(0, performance.now() - receivedAt)),
      1_000,
    );
    return () => window.clearInterval(interval);
  }, [phase, receivedAt]);
  const phaseLabel = phase === "calibrating" ? "ALIGNING" : phase === "paused" ? "PAUSED" : phase === "unavailable" ? "UNAVAILABLE" : formatPhase(phase);
  const guidance = phase === "calibrating"
    ? "Players are aligning their shared play area."
    : phase === "paused" ? "Combat is paused while players restore tracking or connection."
    : phase === "unavailable" ? "Waiting for an arena state update." : null;
  return (
    <header className="match-header">
      <div className="brand-lockup">
        <p className="product-name">VICTORIA PEW PEW</p>
        <p className="product-descriptor">{isArena ? "MARKERLESS MULTIPLAYER" : "CLASSIC DUEL"}</p>
      </div>

      <div className="match-title">
        <h1>{connection === "degraded" ? "LAST RECEIVED STATE" : titleFor(snapshot)}</h1>
        {guidance === null ? null : <p className="phase-guidance">{guidance}</p>}
        {phase === "countdown" && connection !== "degraded" ? (
          <Countdown snapshot={snapshot} elapsed={elapsed} />
        ) : null}
      </div>

      <dl className="match-status" aria-label="Match status">
        <div>
          <dt>MATCH CODE</dt>
          <dd data-testid="match-code">{snapshot.match.code}</dd>
        </div>
        <div>
          <dt>PHASE</dt>
          <dd>{phaseLabel}</dd>
        </div>
        <div>
          <dt>CONNECTION</dt>
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
