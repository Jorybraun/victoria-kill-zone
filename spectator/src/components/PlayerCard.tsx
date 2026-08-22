import {
  MAX_HEALTH,
  type SpectatorPlayerSnapshot,
} from "../domain/spectator";
import { clamp } from "../lib/format";

export interface PlayerCardProps {
  player: SpectatorPlayerSnapshot | undefined;
  slot: "A" | "B";
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

export function PlayerCard({ player, slot }: PlayerCardProps) {
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

  return (
    <article
      className="player-card"
      aria-labelledby={`player-${slot}-name`}
      data-testid={`player-card-${player.id}`}
    >
      <div className="player-card__heading">
        <div>
          <p className="eyebrow">
            PLAYER {slot} · {player.role.toUpperCase()}
          </p>
          <h2 id={`player-${slot}-name`}>{player.displayName}</h2>
        </div>
        <div className="player-statuses" aria-label={`${player.displayName} status`}>
          <StatusItem
            label={player.ready ? "READY" : "NOT READY"}
            positive={player.ready}
          />
          <StatusItem
            label={player.connected ? "CONNECTED" : "DISCONNECTED"}
            positive={player.connected}
          />
        </div>
      </div>

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
    </article>
  );
}
