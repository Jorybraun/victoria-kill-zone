# Combat authority

This Worker routes one authenticated match to one SQLite Durable Object. Convex issues short-lived roster-scoped tickets and receives ordered spectator projections. The Durable Object is the sole combat writer. No production deployment is configured by this package.

## Transport and authority

- Native clients upgrade `GET /v1/matches/{encodeURIComponent(matchId)}/connect` with `Authorization: Bearer <ticket>`. URL credentials are rejected. Tickets use compact HS256 JWTs, a 120-second maximum lifetime, and the shared protocol validator. Roster and rules freeze on the first connection; room membership is capped at four.
- Every command has a contiguous player sequence and immutable command ID. Acknowledgment means its accepted/refused result, checkpoint and outbound events committed to SQLite. An exact retry replays the durable result; conflicting input cannot reuse an identity. The 512-command/player and 1024-event reconnect windows are bounded, with a durable sequence high-water mark outside the retry ring.
- Tick cadence is 50 ms using a monotonic timer with bounded catch-up. Alarms perform maintenance and projection retries. They never advance physics. A stall over 250 ms or object recovery increments authority epoch, pauses gameplay, cancels projectiles and clears spatial readiness. Downtime is not simulated. Replacing a socket also invalidates that phone's alignment and pending input.
- Each tick forks in-memory state, advances the candidate, commits its checkpoint/events/results/ledger/outbox in one SQL transaction, waits for `storage.sync()`, then swaps and broadcasts. Compact checkpoints omit private pose/body histories that recovery must invalidate. The active timer stops when no sockets or commands remain.
- Frames, commands, pending tasks, event pages and output receipt windows are bounded. Clients must send cumulative `received` receipts for every snapshot/event delivery, including an unchanged cursor. A slow consumer is closed and must reconnect for a snapshot.

## AR map transfer

After the room exists, members use `GET /v1/matches/{id}/frames/{frameEpoch}/map`. Only the signed host may `PUT` an `application/octet-stream` body to that path. Both requests use the same bearer ticket, frozen roster/rules and exact frame epoch; a ticket from an older authority epoch remains valid after recovery.

Uploads are limited to 8 MiB, one in flight per room and 15 seconds. Streaming reads occur outside the combat queue into one bounded buffer. Completed maps commit atomically in 128 KiB SQLite chunks and remain immutable for the frame epoch. An identical retry returns 200; first publication returns 201; different content returns 409. Successful upload/download responses include `x-vkz-frame-id` and quoted `ETag`, both derived from the lowercase SHA-256 digest. Downloads stream bounded chunks, with at most four transfers and a 15-second deadline. Partial uploads never become visible.

## Bullet history and spectator delivery

`bullets` and `bullet_events` retain every finite projectile spawn, segment change and terminal, plus terminal-only hitscan outcomes, independently of reconnect ring trimming. Exactly one terminal is permitted. Shot count is bounded from roster size, match duration and the faster of weapon cooldown/respawn; segment count is bounded from projectile lifetime and field transitions.

The SQLite projection outbox commits with combat results. Its final unsent row coalesces the latest public player/phase state; all terminal records survive. Rows split at 64 terminals and at authority/frame transitions. A selected row seals before delivery, so retries use identical JSON. The Worker signs `vkz-projection-v1.` plus that JSON with a separate HMAC key and posts to Convex's `combat:publishProjection`. Only a successful matching sequence receipt permits deletion. Requests have a 5-second deadline, no redirects, bounded responses and exponential retry up to 30 seconds. HTTP work never holds the combat queue.

Room/map/bullet storage is deleted after 24 hours idle once all spectator projections are acknowledged. Pending delivery delays cleanup rather than discarding outcomes. Configure an alert for `combat_projection_delayed`; logs contain only stage and retryability, never tickets, payloads or keys. `GET /health` reports whether projection configuration is usable, without exposing its destination.

## Configuration and checks

Configure `CONVEX_URL` as the HTTPS origin of the authorized Convex deployment. Supply `COMBAT_TICKET_SECRET` and `COMBAT_PROJECTION_SECRET` using the deployment secret mechanism; each must contain at least 32 UTF-8 bytes. They are distinct purposes and should use independent random material. The checked-in URL is empty: projection delivery stays durably queued until configured. Native admission still requires its ticket key.

Run from the repository root:

```sh
pnpm --filter @vkz/combat-worker types
pnpm --filter @vkz/combat-worker typecheck
pnpm --filter @vkz/combat-worker lint
pnpm --filter @vkz/combat-worker test
pnpm --filter @vkz/combat-worker build
pnpm verify
```

Tests run in actual workerd using `@cloudflare/vitest-plugin`, ephemeral in-memory signing keys, native WebSocket pairs and SQLite fault injection. The projection HTTP seam verifies exact signed requests using a local transport stub; it does not contact a live Convex deployment. Tests do not prove physical-device AR alignment or regional network latency. Sustained four-player worst-case tracking geometry/projectile CPU and jitter, device ducking/shield behavior, deployment configuration, signing and promotion gates remain required before production rollout.

Runtime references: [SQLite Durable Objects](https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/), [WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/), [Workers testing](https://developers.cloudflare.com/workers/testing/vitest-integration/).
