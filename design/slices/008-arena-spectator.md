# Slice 008 — Arena spectator scoreboard

Status: accepted implementation packet, 2026-09-05. Integration approved this bounded slice from canonical 2c10a9a. Owner writes only `spectator/**` and this document in `codex/arena-spectator`.

## User job and scope

A viewer enters a match code, sees every participant and the latest received scores, understands whether players are preparing, fighting, paused or finished, and can recover their read-only connection. Existing `queries:spectatorSnapshot` supplies the data. No spectator action changes a match.

Consume its existing optional `combatMode`, `maxPlayers`, `combatPhase`, `durationMs`, `endsAt` and `winnerPlayerId`; no new backend or shared wire fields. Classic G2/Phase 0 snapshots remain supported. Preserve server roster order, identity and event order. Arena slots are bounded at four; missing capacity falls back to the observed roster with a two-player minimum. Display all supplied members within the Phase 1 cap.

## Frozen states and copy

| State | Presentation and interaction |
|---|---|
| No selection/loading/error | Match-neutral entry: MATCH CODE / WATCH MATCH; validation and retry retain the entered code. No fabricated live state. |
| Classic | Existing duel lifecycle and optional score data remain supported; two slots for legacy snapshots. |
| Arena lobby | ARENA LOBBY; filled/capacity count and open slots; player readiness visible. |
| Calibrating | ALIGNING ARENA; players are aligning their shared play area. Never LIVE. |
| Running | LIVE ARENA; every player's health, life state and supplied K/D. |
| Paused | ARENA PAUSED; combat is paused while players restore tracking or connection. Scores remain visible. Never infer a required host restart. |
| Finished | ARENA COMPLETE; supplied winner's name, or MATCH DRAW only for authoritative arena combatPhase=finished with no winner. Do not infer a winner from displayed scores or fabricate a draw for legacy G2. Watch another match. |
| Socket disconnected/query failure | Retain all last received data; CONNECTION INTERRUPTED and LAST UPDATE timestamp; retry remains usable. Header says LAST RECEIVED STATE rather than LIVE. |
| Socket restored | CONNECTION RESTORED for 1.8 seconds; retained timestamp remains unchanged until new data arrives. This confirms socket connectivity only. |
| Authority projection delayed | No available receipt-time contract. Label data as latest received match update, and never claim socket connectivity proves authority freshness. |

`combatPhase` takes precedence for durableObject matches when present; absent combatPhase in an arena lobby remains lobby, and a missing active arena phase is MATCH STATE UNAVAILABLE rather than LIVE. Round timers and projectile paths are deferred because this slice cannot establish an authority-relative freshness/clock contract.

## Components, tokens and accessibility

Keep the current CSS palette, spacing scale, card/control radii and semantic status colors. Reuse PlayerCard, EventFeed and MatchHeader; isolate arena state/slot/winner selection in domain helpers. Two-column roster on wide screens, one column below the existing 52rem breakpoint; no clipped names or horizontal overflow at 375px and 200% text size. Mode and player status have text, not color alone. All actions remain native buttons/links with visible focus and at least 48px targets. Preserve skip-link, labeled input, focused errors and reduced-motion support. Recovery uses a bounded polite announcement; no per-tick score announcements.

## Acceptance and handoff

- Tests: four distinct players and scores retained; capacity/open slots; calibrating and paused never LIVE; authoritative winner/draw only; classic G2/Phase 0 behavior; socket loss keeps data and retry; socket reconnection with unchanged query data recovers without inventing a newer timestamp; disposal and obsolete callbacks cannot update the view.
- Run spectator test, lint, typecheck/build. Integration runs canonical `pnpm verify` before review/merge.
- Render actual React components with deterministic, visibly labeled arena fixtures in a browser at desktop and 375px. Check long names, four-member reading order and recovery states; fixture screenshots are not a production network or physical-device result.
- Backend handoff remains: DO phase must not be inferred from legacy expiry; optional authority projection receipt timestamp/sequence requires an integration-owned contract before freshness claims. Terminal-ledger publication and spatial worldlines remain subsequent slices of the full goal.

## Implementation evidence

Implementation preserves existing optional query fields and adds no backend contract. 49 spectator tests cover roster/phase/result boundaries, classic compatibility, actual adapter connection-state callbacks, cached recovery, query-error recovery and listener disposal. The 1.8-second recovery announcement remains bounded even while new snapshots arrive; it retains the newest data. Independent review added actual App-under-StrictMode coverage, a monotonic countdown that survives connection transitions, and accessible terminal life-state labels matching the displayed copy. Retained match content keeps its normal text contrast during interruption; the status banner communicates the connection loss.

Eight actual browser captures and reproducible script are in `spectator/evidence/008-arena-spectator` and `spectator/scripts/render-review.mjs`. Review corrected enlarged-text page/card overflow, event heading wrapping and desktop connection label space. Finished players no longer promise a future respawn. Screenshot fixtures are explicitly marked; no device or production-network acceptance is implied.
