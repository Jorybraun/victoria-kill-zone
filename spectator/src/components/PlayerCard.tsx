import {
  MAX_HEALTH,
  type SpectatorPlayerSnapshot,
  type PlayerSlot,
  type displayPhase,
} from "../domain/spectator";
import { clamp, formatCountdown } from "../lib/format";

export interface PlayerCardProps {
  player: SpectatorPlayerSnapshot | undefined;
  slot: PlayerSlot;
  mode?: "classic" | "arena";
  phase?: ReturnType<typeof displayPhase>;
  serverNow: number;
}

function StatusItem({
  label,
  positive,
}: {
  label: string;
  positive: boolean;
}) {
  return (
    <span className={`player-status ${positive ? "is-positive" : "is-negative"}`}>
      <span className="player-status__shape" aria-hidden="true" />
      {label}
    </span>
  );
}

function hasCombatScore(
  player: SpectatorPlayerSnapshot,
): player is SpectatorPlayerSnapshot & { kills: number; deaths: number } {
  return player.kills !== undefined && player.deaths !== undefined;
}

function lifeStateCopy(
  player: SpectatorPlayerSnapshot,
  serverNow: number,
  phase: ReturnType<typeof displayPhase>,
): string | null {
  switch (player.lifeState) {
    case undefined:
      return null;
    case "alive":
      return "ALIVE";
    case "dead":
      return "ELIMINATED";
    case "disconnected":
      return "DISCONNECTED";
    case "respawning": {
      if (phase === "finished" || phase === "cancelled") return "ELIMINATED";
      if (player.respawnAt === undefined) {
        return "RESPAWNING";
      }

      const seconds = formatCountdown(player.respawnAt - serverNow);
      return seconds === "0" ? "RESPAWNING" : `RESPAWNING IN ${seconds}S`;
    }
  }

  return null;
}

export function PlayerCard({ player, slot, serverNow, mode = "classic", phase = "running" }: PlayerCardProps) {
  if (player === undefined) {
    return (
      <article
        className="player-card player-card--empty"
        aria-label={`Player ${slot} slot, open`}
        data-testid={`player-slot-${slot.toLowerCase()}`}
      >
        <p className="eyebrow">PLAYER {slot}</p>
        <h2>OPEN SLOT</h2>
        <div className="player-statuses" aria-label="Player slot status">
          <StatusItem label="NOT READY" positive={false} />
          <StatusItem label="DISCONNECTED" positive={false} />
        </div>
        <p className="empty-copy">WAITING FOR PLAYER</p>
      </article>
    );
  }

  const health = clamp(player.health, 0, MAX_HEALTH);
  const lifeCopy = lifeStateCopy(player, serverNow, phase);
  const showReadiness = mode === "classic" || phase === "lobby" || phase === "calibrating";
  const lifeStateClass =
    player.lifeState === undefined ? "" : ` player-card--${player.lifeState}`;

  return (
    <article
      className={`player-card${lifeStateClass}`}
      aria-labelledby={`player-${slot}-name`}
      data-testid={`player-card-${player.id}`}
    >
      <div className="player-card__heading">
        <div>
          <p className="eyebrow">
            PLAYER {slot} · {mode === "arena" && player.role === "guest" ? "PLAYER" : player.role.toUpperCase()}
          </p>
          <h2 id={`player-${slot}-name`}>{player.displayName}</h2>
        </div>
        <div className="player-statuses" aria-label={`${player.displayName} status`}>
          {showReadiness ? <StatusItem
            label={player.ready ? "READY" : "NOT READY"}
            positive={player.ready}
          /> : null}
          <StatusItem
            label={player.connected ? "CONNECTED" : "DISCONNECTED"}
            positive={player.connected}
          />
        </div>
      </div>

      {lifeCopy === null ? null : (
        <p
          className={`life-state life-state--${player.lifeState}`}
          aria-label={`${player.displayName} life state, ${lifeCopy}`}
          aria-live="polite"
          aria-atomic="true"
        >
          <span className="life-state__shape" aria-hidden="true" />
          <span className="life-state__label">{lifeCopy}</span>
        </p>
      )}

      <section className="health-block" aria-label={`${player.displayName} health`}>
        <div className="health-heading">
          <span>HEALTH</span>
          <strong>{health} / {MAX_HEALTH}</strong>
        </div>
        <progress
          className="health-meter"
          max={MAX_HEALTH}
          value={health}
          aria-label={`${player.displayName} health, ${health} of ${MAX_HEALTH}`}
        >
          {health} / {MAX_HEALTH}
        </progress>
      </section>

      {hasCombatScore(player) ? (
        <dl className="combat-score" aria-label={`${player.displayName} combat score`}>
          <div>
            <dt>KILLS</dt>
            <dd>{player.kills}</dd>
          </div>
          <div>
            <dt>DEATHS</dt>
            <dd>{player.deaths}</dd>
          </div>
        </dl>
      ) : null}
    </article>
  );
}
