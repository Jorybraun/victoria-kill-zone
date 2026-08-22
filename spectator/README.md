# VKZ G2 spectator

Read-only browser view for the frozen create/join/start/debug-fire network slice.

## User job

A spectator enters one six-character duel code, then sees the authoritative phase, two equal player health cards, each player's ready/connection text, and the server-ordered event feed. The G2 route intentionally makes no radar, location, ammunition, K/D, winner, or rematch claim.

## Presentation contract

`SpectatorShell` receives a discriminated `SpectatorViewState` and emits only two read intents:

- `onSelectMatch(code)` changes the watched query; `null` returns to code selection.
- `onRetry()` resubscribes to the same read-only query after an interruption.

The component does not fetch, route, authenticate, or call Convex. `SpectatorSnapshotAdapter` is the narrow boundary to the sanitized `queries:spectatorSnapshot({ code })` subscription. Until generated Convex bindings exist, `convexSpectatorAdapter.ts` keeps a typed manual query reference. It exposes no mutation, action, session, or raw client surface.

## State matrix

| State | Visible behavior |
|---|---|
| `no-selection` | Frozen no-duel copy, persistent code label, and `WATCH DUEL` |
| `loading` | `CONNECTING TO DUEL…` with the selected code retained |
| `waiting` | Lobby/countdown phase, both slots, ready/connected text, and `OPEN SLOT` when needed |
| `active` | `LIVE DUEL`, two equal health cards, and authoritative events |
| `ended` | `DUEL COMPLETE` or `DUEL CANCELLED`, last authoritative values, and `WATCH ANOTHER DUEL` |
| `degraded` | Dimmed last snapshot, `LIVE FEED INTERRUPTED`, last-sync time, and query retry |
| `error` | Editable retained code, mapped safe copy, and `TRY AGAIN` |
| `recovery` | Atomic fresh snapshot replacement and one polite `LIVE FEED RESTORED` announcement |

Events are de-duplicated by record identity without sorting, so the backend's newest-first order remains authoritative.

## Deterministic evidence routes

Without `VITE_CONVEX_URL`, any valid `?match=` code uses demo data. The optional `demo` value can be `loading`, `waiting`, `countdown`, `active`, `ended`, `cancelled`, `degraded`, `recovery`, or `error`. No `match` parameter renders the no-selection state.

## Accessibility and responsive behavior

- Native input and button semantics keep selection and retry keyboard reachable with a white focus ring.
- Ready, connection, health, interruption, and recovery all use visible text in addition to shape/color.
- Status and events use polite live regions; interruption is a status rather than a blocking alert.
- The two-card desktop row stacks before truncation, keeping code, phase, both health values, and recovery controls usable at 200% zoom.
- Decorative loading motion is disabled under `prefers-reduced-motion`.

## Commands

```sh
pnpm --filter @vkz/spectator lint
pnpm --filter @vkz/spectator typecheck
pnpm --filter @vkz/spectator test
pnpm --filter @vkz/spectator build
```
