import {
  useEffect,
  useRef,
  useState,
  type FormEvent,
} from "react";

import {
  isValidMatchCode,
  normalizeMatchCode,
  viewKindForMatch,
  displayPhase,
  playerSlots,
  PLAYER_SLOTS,
  resultLabel,
  type SnapshotViewKind,
  type SpectatorErrorReason,
  type SpectatorViewState,
} from "../domain/spectator";
import { formatTimestamp } from "../lib/format";
import { EventFeed } from "./EventFeed";
import { MatchHeader, type FeedConnection } from "./MatchHeader";
import { PlayerCard } from "./PlayerCard";

export interface SpectatorShellProps {
  state: SpectatorViewState;
  onSelectMatch: (code: string | null) => void;
  onRetry: () => void;
}

function errorCopy(reason: SpectatorErrorReason): string {
  switch (reason) {
    case "not-found":
      return "MATCH CODE NOT FOUND";
    case "network":
      return "CAN’T REACH THE MATCH";
    case "unknown":
      return "SOMETHING WENT WRONG";
  }
}

interface CodeSelectionViewProps {
  initialCode: string;
  isDemo: boolean;
  errorReason?: SpectatorErrorReason;
  onSelectMatch: (code: string) => void;
  onRetry: () => void;
}

function CodeSelectionView({
  initialCode,
  isDemo,
  errorReason,
  onSelectMatch,
  onRetry,
}: CodeSelectionViewProps) {
  const normalizedInitialCode = normalizeMatchCode(initialCode);
  const [code, setCode] = useState(normalizedInitialCode);
  const [validationMessage, setValidationMessage] = useState("");
  const errorRef = useRef<HTMLParagraphElement>(null);
  const remoteError =
    errorReason !== undefined && code === normalizedInitialCode
      ? errorCopy(errorReason)
      : "";
  const visibleError = validationMessage || remoteError;

  useEffect(() => {
    if (visibleError) {
      errorRef.current?.focus();
    }
  }, [visibleError]);

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!isValidMatchCode(code)) {
      setValidationMessage("MATCH CODE NOT FOUND");
      return;
    }

    setValidationMessage("");
    if (errorReason !== undefined && code === normalizedInitialCode) {
      onRetry();
    } else {
      onSelectMatch(code);
    }
  }

  return (
    <main className="state-page" id="main-content">
      <section className="selection-card" aria-labelledby="selection-heading">
        <div className="brand-lockup brand-lockup--selection">
          <p className="product-name">VICTORIA PEW PEW</p>
          <p className="product-descriptor">MARKERLESS MULTIPLAYER</p>
        </div>

        <h1 id="selection-heading">
          {errorReason === undefined ? "NO MATCH SELECTED" : "WATCH MATCH"}
        </h1>
        <p className="selection-card__lead">
          ENTER A 6-CHARACTER CODE TO WATCH
        </p>

        <form className="code-form" onSubmit={handleSubmit} noValidate>
          <label htmlFor="duel-code">6-CHARACTER MATCH CODE</label>
          <div className="code-form__controls">
            <input
              id="duel-code"
              name="duelCode"
              value={code}
              onChange={(event) => {
                setCode(normalizeMatchCode(event.currentTarget.value));
                setValidationMessage("");
              }}
              aria-describedby="duel-code-hint duel-code-error"
              aria-invalid={visibleError.length > 0}
              autoComplete="off"
              autoCapitalize="characters"
              inputMode="text"
              maxLength={6}
              pattern="[A-Za-z0-9]{6}"
              placeholder="ABC123"
              spellCheck={false}
              data-testid="duel-code-input"
            />
            <button className="button button--primary" type="submit">
              {errorReason === undefined ? "WATCH MATCH" : "TRY AGAIN"}
            </button>
          </div>
          <p id="duel-code-hint" className="field-hint">
            READ-ONLY SPECTATOR
          </p>
          <p
            id="duel-code-error"
            className="field-error"
            role={visibleError ? "alert" : undefined}
            tabIndex={visibleError ? -1 : undefined}
            ref={errorRef}
          >
            {visibleError}
          </p>
        </form>

        {isDemo ? <p className="source-badge">DEMO FIXTURE</p> : null}
      </section>
    </main>
  );
}

function LoadingView({ code }: { code: string }) {
  return (
    <main className="state-page" id="main-content" aria-busy="true">
      <section className="loading-card" aria-labelledby="loading-heading">
        <div className="brand-lockup brand-lockup--selection">
          <p className="product-name">VICTORIA PEW PEW</p>
          <p className="product-descriptor">MARKERLESS MULTIPLAYER</p>
        </div>
        <h1 id="loading-heading" role="status">
          CONNECTING TO MATCH…
        </h1>
        <dl className="retained-code">
          <div>
            <dt>MATCH CODE</dt>
            <dd>{code}</dd>
          </div>
        </dl>
        <div className="loading-mark" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
      </section>
    </main>
  );
}

type DashboardState = Extract<SpectatorViewState, { snapshot: unknown }>;

function visibleKind(state: DashboardState): SnapshotViewKind {
  switch (state.kind) {
    case "waiting":
    case "active":
    case "ended":
      return state.kind;
    case "degraded":
      return viewKindForMatch(state.snapshot.match);
    case "recovery":
      return state.currentKind;
  }
}

function feedConnection(state: DashboardState): FeedConnection {
  switch (state.kind) {
    case "degraded":
      return "degraded";
    case "recovery":
      return "restored";
    case "waiting":
    case "active":
    case "ended":
      return "connected";
  }
}

function DashboardView({
  state,
  onSelectMatch,
  onRetry,
}: {
  state: DashboardState;
  onSelectMatch: (code: null) => void;
  onRetry: () => void;
}) {
  const { snapshot } = state;
  const slots = playerSlots(snapshot);
  const isArena = snapshot.match.combatMode === "durableObject";
  const modeName = isArena ? "arena" : "duel";
  const phase = displayPhase(snapshot.match);
  const result = resultLabel(snapshot);
  const currentKind = visibleKind(state);
  const connection = feedConnection(state);
  const isDegraded = state.kind === "degraded";

  return (
    <div
      className={`spectator-app spectator-app--${currentKind}${isDegraded ? " is-stale" : ""}`}
    >
      <MatchHeader
        key={`${snapshot.match.id}-${snapshot.serverNow}`}
        snapshot={snapshot}
        source={state.source}
        connection={connection}
      />

      {state.kind === "degraded" ? (
        <section className="connection-banner connection-banner--degraded" role="status">
          <div>
            <strong>CONNECTION INTERRUPTED</strong>
            <span>LAST UPDATE {formatTimestamp(state.lastSyncedAt)}</span>
          </div>
          <button className="button button--secondary" type="button" onClick={onRetry}>
            TRY AGAIN
          </button>
        </section>
      ) : null}

      {state.kind === "recovery" ? (
        <p
          className="connection-banner connection-banner--recovery"
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          <strong>CONNECTION RESTORED</strong>
        </p>
      ) : null}

      <main
        className="dashboard"
        id="main-content"
        aria-label={isDegraded ? `Last received ${modeName} snapshot` : undefined}
      >
        {result === null ? null : (
          <section className="result-panel" aria-label="Match result">
            <p className="eyebrow">FINAL RESULT</p>
            <h2>{result}</h2>
          </section>
        )}
        <div className="roster-heading">
          <h2>PLAYERS</h2>
          <span>{snapshot.players.length} / {slots.length}</span>
        </div>
        <section className="player-grid" aria-label={isArena ? "Arena players" : "Duel players"}>
          {slots.map((player, index) => (
            <PlayerCard key={player?.id ?? `open-${index}`} player={player}
              slot={PLAYER_SLOTS[index]!} serverNow={snapshot.serverNow}
              mode={isArena ? "arena" : "classic"}
              phase={phase} />
          ))}
        </section>
        <EventFeed events={snapshot.events} />

        {currentKind === "ended" ? (
          <button
            className="button button--primary watch-another"
            type="button"
            onClick={() => onSelectMatch(null)}
          >
            WATCH ANOTHER MATCH
          </button>
        ) : null}
      </main>

      <footer className="app-footer">
        <p>READ-ONLY SPECTATOR · LAST UPDATE {formatTimestamp(snapshot.serverNow)}</p>
        <p>Connection status describes this viewer’s link. Scores and events reflect the latest received match update.</p>
      </footer>
    </div>
  );
}

export function SpectatorShell({
  state,
  onSelectMatch,
  onRetry,
}: SpectatorShellProps) {
  return (
    <>
      <a className="skip-link" href="#main-content">
        SKIP TO MATCH
      </a>
      {state.kind === "no-selection" ? (
        <CodeSelectionView
          initialCode={state.initialCode}
          isDemo={state.isDemo}
          onSelectMatch={(code) => onSelectMatch(code)}
          onRetry={onRetry}
        />
      ) : null}
      {state.kind === "loading" ? <LoadingView code={state.code} /> : null}
      {state.kind === "error" ? (
        <CodeSelectionView
          initialCode={state.code}
          isDemo={state.source === "demo"}
          errorReason={state.reason}
          onSelectMatch={(code) => onSelectMatch(code)}
          onRetry={onRetry}
        />
      ) : null}
      {state.kind === "waiting" ||
      state.kind === "active" ||
      state.kind === "ended" ||
      state.kind === "degraded" ||
      state.kind === "recovery" ? (
        <DashboardView
          state={state}
          onSelectMatch={onSelectMatch}
          onRetry={onRetry}
        />
      ) : null}
    </>
  );
}
