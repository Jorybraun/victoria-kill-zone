import {
  dedupeEventsInServerOrder,
  type SpectatorEventSnapshot,
} from "../domain/spectator";
import { formatTimestamp } from "../lib/format";

export interface EventFeedProps {
  events: readonly SpectatorEventSnapshot[];
}

export function EventFeed({ events }: EventFeedProps) {
  const recentEvents = dedupeEventsInServerOrder(events).slice(0, 12);

  return (
    <section className="event-panel" aria-labelledby="event-feed-heading">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">AUTHORITATIVE FEED</p>
          <h2 id="event-feed-heading">EVENT FEED</h2>
        </div>
        <span className="event-count">{recentEvents.length} EVENTS</span>
      </div>

      {recentEvents.length === 0 ? (
        <p className="empty-copy" data-testid="empty-events">
          NO EVENTS YET
        </p>
      ) : (
        <ol
          className="event-list"
          aria-live="polite"
          aria-relevant="additions text"
        >
          {recentEvents.map((event, index) => (
            <li key={event.id} className="event" data-event-id={event.id}>
              <span className="event__index" aria-hidden="true">
                {String(index + 1).padStart(2, "0")}
              </span>
              <p>{event.message}</p>
              <time dateTime={new Date(event.createdAt).toISOString()}>
                {formatTimestamp(event.createdAt)}
              </time>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
