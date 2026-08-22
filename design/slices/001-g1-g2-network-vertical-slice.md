# Slice 001: Create, join, start, debug fire, synchronized health

| Field | Value |
|---|---|
| Status | **Accepted and frozen** |
| Product gates | G1 Contracts and shells → G2 Network vertical slice |
| Design owner | `design/**` |
| Accepted | 2026-08-22 |
| Authority | [Technical specification](../../victoria-kill-zone-technical-spec.md) and [build orchestration prompt](../../victoria-kill-zone-build-prompt.md) |

## Outcome

Two people can create and join a duel, become ready, start together, and watch one explicit debug shot change the same authoritative health value on Phone A, Phone B, and the read-only spectator.

This packet freezes the user states, copy, tokens, behavior, and evidence for this slice. It consumes the canonical enums, DTOs, and server-owned constants; it does not redefine an API contract.

## Slice boundary

### In this slice

- Callsign entry, create-duel path, six-character join path, two-slot lobby, and ready state.
- Host-only start after exactly two connected players are ready.
- Server-timed three-second countdown and transition into the network-test HUD.
- Initial health `100`, initial ammunition `8`, and one host-only `DEBUG FIRE` torso claim for server-owned `34` damage.
- Authoritative result: Phone A ammunition `7`, Phone B health `66`, and the same `66` health plus one event on spectator.
- Idempotent retry, connection degradation, recovery, rejection, and finished/cancelled rendering.
- Read-only spectator selection by duel code.

### Explicitly outside this slice

- Vision targeting, body lock, head/limb regions, or any claim that debug fire is markerless targeting.
- Geofence enforcement, radar, heading, K/D, kill/respawn, reload, winner calculation, rematch, sound, haptics, or presentation composition.
- Client-defined damage, spectator mutations, permanent identity, 3+ players, visible markers, or realistic firearm styling.

The debug path remains visible and labelled until physical-device evidence proves its Vision replacement.

## Flow and surface responsibilities

| Step | Phone A — host | Phone B — guest | Spectator |
|---|---|---|---|
| Entry | Enter callsign; choose `CREATE DUEL` | Enter callsign; choose `JOIN DUEL` | Enter a duel code to watch |
| Create | Confirm arena shell; create duel | Join-code entry remains available | No match selected |
| Lobby | See code, own slot, and `OPEN SLOT` | Join with code; see both slots | See lobby phase and both player slots after selection |
| Ready | Mark ready; start remains locked until both ready | Mark ready | Show each ready state; no controls |
| Countdown | Start; show server-timed `3`, `2`, `1` | Show the same countdown | Show countdown and phase |
| Active | Show network-test HUD and host-only debug action | Show network-test HUD with no fire action | Show two health cards and live event feed |
| Shot | Submit one torso debug shot; show pending then accepted state | Update only from authoritative subscription | Update only from sanitized subscription |
| Recovery | Lock input while stale; replace local view with fresh snapshot on reconnect | Same | Retain last snapshot as stale, then replace it on reconnect |
| End | Render final phase and last authoritative values | Same | Render final phase and last authoritative values |

## State model

Every state below is required. Dynamic values appear in braces and are never literal UI copy.

| State | Trigger | Phone behavior and copy | Spectator behavior and copy | Exit |
|---|---|---|---|---|
| **Entry** | No active match session | Brand, callsign field, `CREATE DUEL`, `JOIN DUEL`; connection status remains visible | Code field and `WATCH DUEL` | User selects a valid action |
| **Loading** | First request/subscription has no usable snapshot | Preserve context, disable repeated submission, show one of `CREATING DUEL…`, `JOINING DUEL…`, or `STARTING DUEL…` | `CONNECTING TO DUEL…`; retain entered code | Success, recoverable error, or cancellation |
| **Empty** | Host lobby has one slot, or spectator has no selected code | Empty player card reads `OPEN SLOT`; supporting copy `SHARE CODE {CODE}` | `NO DUEL SELECTED` and `ENTER A 6-CHARACTER CODE TO WATCH` | Guest joins or spectator submits a code |
| **Waiting** | Lobby snapshot exists but start conditions are incomplete | Header `DUEL {CODE}`; unready slot `NOT READY`; ready slot `READY`; host helper `BOTH PLAYERS MUST BE READY` | `WAITING FOR DUEL`; mirror both slots and ready labels | Both ready and connected, host starts, or match is cancelled |
| **Active** | Authoritative phase is `running` | Header `NETWORK TEST`; show health/ammo; Phone A alone shows `DEBUG FIRE` and `TORSO TEST • 34 DAMAGE`; Phone B shows `AWAITING TEST SHOT` | Header `LIVE DUEL`; equal player cards, phase, and event list; no mutation control | Match finishes/cancels or connection becomes stale |
| **Ended** | Authoritative phase is `finished` or `cancelled` | `DUEL COMPLETE` or `DUEL CANCELLED`; show last authoritative health; `LEAVE DUEL` | Same phase title and last snapshot; `WATCH ANOTHER DUEL` | User leaves/selects another code |
| **Degraded** | A previously live subscription is disconnected or too stale to trust | Keep last snapshot visibly dimmed; lock start/debug fire; `RECONNECTING — INPUT LOCKED`; `LAST SYNC {TIME}` | Keep last snapshot visibly dimmed; `LIVE FEED INTERRUPTED`; `LAST SYNC {TIME}` | Fresh authoritative snapshot or terminal error |
| **Error** | Initial load/mutation fails with no safe forward transition | Inline error next to the initiating control; keep user input; offer `TRY AGAIN` or `RETURN HOME` | Inline error beside code field; offer `TRY AGAIN` | Retry, corrected input, or return |
| **Recovery** | A fresh snapshot arrives after degraded/error state | Replace stale values atomically; announce `SYNC RESTORED`; show a short `STATE VERIFIED` status; do not replay old animations | Replace the entire snapshot; announce `LIVE FEED RESTORED`; do not duplicate events | Automatically return to current empty/waiting/active/ended state |

Loading is for the absence of a first usable snapshot. Degraded is for loss of a previously usable snapshot. Error never silently discards the callsign or duel code.

## Final copy

Capitalization and punctuation are frozen. Implementations may localize later but must not substitute technical backend messages.

### Entry and setup

| Element | Copy |
|---|---|
| Product name | `VICTORIA PEW PEW` |
| Product descriptor | `MARKERLESS 1V1 DUEL` |
| Callsign label | `CALLSIGN` |
| Callsign placeholder | `ENTER A NAME` |
| Host entry action | `CREATE DUEL` |
| Guest entry action | `JOIN DUEL` |
| Host setup title | `CREATE ARENA` |
| Radius label | `ARENA RADIUS` |
| Radius value | `{RADIUS} M` |
| Location pending | `LOCATING ARENA…` |
| Location available | `ARENA CENTER READY` |
| Location unavailable | `LOCATION REQUIRED TO CREATE AN ARENA` |
| Create action | `CREATE ARENA` |
| Join title | `JOIN DUEL` |
| Join-code label | `6-CHARACTER DUEL CODE` |
| Join-code placeholder | `ABC123` |
| Join action | `JOIN ARENA` |
| Spectator action | `WATCH DUEL` |

The G1/G2 arena shell may collect the configured centre and radius, but it must not display `INSIDE`, `SAFE`, or any other enforcement claim before G5 evidence exists.

### Lobby and active test

| Element | Copy |
|---|---|
| Lobby title | `DUEL {CODE}` |
| Host share helper | `SHARE CODE {CODE}` |
| Empty player slot | `OPEN SLOT` |
| Ready action | `I’M READY` |
| Undo ready action | `NOT READY` |
| Ready label | `READY` |
| Unready label | `NOT READY` |
| Start action | `START DUEL` |
| Disabled-start helper | `BOTH PLAYERS MUST BE READY` |
| Countdown label | `DUEL STARTS IN` |
| Active phone title | `NETWORK TEST` |
| Active spectator title | `LIVE DUEL` |
| Health label | `HEALTH` |
| Ammo label | `AMMO` |
| Debug action | `DEBUG FIRE` |
| Debug helper | `TORSO TEST • 34 DAMAGE` |
| Guest active helper | `AWAITING TEST SHOT` |
| Shot pending | `SHOT PENDING…` |
| Accepted shot | `HIT CONFIRMED • 34` |
| Event | `{SHOOTER} HIT {TARGET} • TORSO −34` |

### Error and connection mapping

| Condition | User-facing copy |
|---|---|
| Missing callsign | `ENTER A CALLSIGN` |
| Invalid or unknown code | `DUEL CODE NOT FOUND` |
| Match already has two players | `DUEL IS FULL` |
| Match is no longer joinable | `DUEL ALREADY STARTED` |
| Start rejected because a player is not ready | `BOTH PLAYERS MUST BE READY` |
| Start rejected because a player disconnected | `BOTH PLAYERS MUST BE CONNECTED` |
| Debug shot rejected before running | `SHOT LOCKED UNTIL DUEL STARTS` |
| Debug shot rejected during stale connection | `SHOT LOCKED WHILE RECONNECTING` |
| Initial network failure | `CAN’T REACH THE DUEL` |
| Unknown safe error | `SOMETHING WENT WRONG` |
| Retry action | `TRY AGAIN` |
| Exit action | `RETURN HOME` |

Validation appears inline and remains associated with its field/action. Never render raw exception text, IDs, session material, endpoints, or stack traces.

## Interaction behavior

### Phone

- Callsign is trimmed, required, and preserved across a failed request. Join code accepts paste, displays uppercase, and ignores spaces while typing; backend validation remains authoritative.
- A create/join action can have only one in-flight request. Disable the initiating action and show its loading label without clearing input.
- Lobby state comes only from the subscribed match snapshot. Both player slots have name, connection, and ready text; color is supplementary.
- `START DUEL` is host-only and enabled only when the snapshot shows exactly two ready, connected players. A backend rejection returns to waiting with mapped copy.
- Countdown is derived from authoritative `startsAt`, not three chained local timers. When the phase becomes `running`, replace the lobby with the network-test HUD.
- The G2 HUD may use the working rear-camera view or a neutral dark surface, but it shows no crosshair lock or target-acquisition claim.
- `DEBUG FIRE` appears only for Phone A/host in this acceptance run. One press creates one stable `clientShotId`, submits a torso claim against the only opponent, and enters `SHOT PENDING…`. A retry reuses that ID.
- Disable debug fire while the request is pending, the phase is not running, the player is disconnected, or the snapshot is stale. Do not change target health until authoritative state arrives. Any local ammo animation must reconcile to the returned/subscribed value.
- Apply the accepted result and fresh snapshot as one visible state change. Do not append a second hit animation/event when an idempotent response is replayed.
- `LEAVE DUEL` clears match-scoped local state only after navigation succeeds; it never deletes the anonymous device identity.

### Spectator

- The spectator starts with no selected duel. Its only entry control is a code plus `WATCH DUEL`.
- It uses the sanitized spectator subscription and has no ready, start, fire, end, or retry-mutation control.
- For G2, show a top phase/code row, two equal-width player cards, and a newest-first event list. Do not show a fake radar or unavailable statistics.
- Health uses both a number (`66 / 100`) and a labelled bar. Ready/connection states use text plus an icon or shape, never color alone.
- A shot event is appended once only after it exists in the authoritative feed. Preserve server order; never synthesize an event from a phone animation.
- During degradation, freeze and mark the last snapshot rather than zeroing health or emptying the lobby. Recovery replaces the snapshot and de-duplicates events by record identity.

## Layout

### Phone portrait

- Entry/setup: single vertical column, 16 pt horizontal inset, primary action anchored after the fields rather than at the screen edge.
- Lobby: duel code first, two stacked player cards, readiness action, then host start action. The code remains selectable and readable without relying on character-by-character spacing.
- Network-test HUD: health top-left, phase/countdown top-centre, ammo top-right, connection/status above a bottom safe-area panel. Phone A’s debug action is a full-width rectangular control labelled as a test, not a firearm trigger.
- Errors occupy reserved supporting-text space to avoid moving the primary action on every validation change.

### Spectator 16:9

- Phase, duel code, and connection status form the header.
- Player A and Player B cards share the main row at equal visual weight.
- The event feed spans the lower row and remains readable at projector distance.
- At narrow widths, cards stack before content truncates. The code field and retry control remain keyboard reachable.

## Visual tokens

These tokens are frozen for the slice; names may map to platform-specific implementations.

| Token | Value | Use |
|---|---|---|
| `color.bg` | `#070B10` | Full-screen background |
| `color.surface` | `#111923` | Cards and panels |
| `color.surfaceRaised` | `#192533` | Selected/raised controls |
| `color.text` | `#F5F8FC` | Primary copy and numeric values |
| `color.textMuted` | `#A8B4C2` | Supporting copy |
| `color.telemetry` | `#35D9E6` | Neutral live telemetry |
| `color.ready` | `#43D17D` | Ready/connected, always paired with text/icon |
| `color.pending` | `#FFB340` | Pending/countdown/debug test |
| `color.danger` | `#FF5364` | Damage/error, always paired with text/icon |
| `color.focus` | `#FFFFFF` | Keyboard/assistive focus ring |
| `space.1/2/3/4/6/8` | `4/8/12/16/24/32` | Spacing scale in pt/px |
| `radius.control/card` | `10/14` | Controls/cards; no pill buttons except status chips |
| `border.default/strong` | `1/2` | Dividers/focus and state emphasis |
| `touch.minimum` | `48 × 48 pt` | Phone interactive target |
| `type.ui` | System sans (`SF Pro` on iOS) | Labels and actions |
| `type.telemetry` | System monospaced (`SF Mono` on iOS) | Codes, health, ammo, countdown |

Primary phone actions use at least 17 pt semibold type. Phone telemetry uses at least 20 pt. Spectator body copy uses at least 18 px and primary health/countdown values at least 32 px. Respect user font scaling rather than fixing these as maximums.

## Accessibility contract

- Maintain logical reading order: title → status → fields/content → primary action → secondary action.
- Every field has a persistent label. Placeholder text is never the only label.
- Every state has visible text; cyan/green/amber/red never carries meaning alone.
- Phone controls expose concise VoiceOver labels and state/value. Examples: `Duel code, A B C 1 2 3`; `Player Two, ready, connected`; `Debug fire, torso test, 34 damage`; `Player Two health, 66 of 100`.
- Announce countdown changes without stealing focus. Announce authoritative damage once and recovery once using a polite live update.
- Support Dynamic Type through accessibility sizes. At large sizes, player cards grow vertically and controls remain reachable by scrolling; health and actions must not truncate.
- Respect Reduce Motion. Replace pulsing/slide transitions with opacity or immediate state changes; never flash the full screen.
- Spectator fields/actions are operable by keyboard with a visible focus ring. Status and event updates use `aria-live="polite"`; connection interruption uses `role="status"`, not a blocking alert.
- At 200% browser zoom, duel code, both health values, phase, and recovery action remain visible without two-dimensional scrolling.
- Errors are programmatically associated with their field/action and focus moves to the error summary only after submission fails.

## Acceptance evidence

Evidence is tied to one Git SHA and one Convex deployment. It contains no session secret, deploy key, device identifier, or raw endpoint credential.

### G1 contracts and shells

- [ ] `pnpm verify` passes on the exact SHA.
- [ ] iOS shell build evidence records Xcode version and target; spectator shell build evidence records browser target.
- [ ] Deterministic phone previews/fixtures capture entry, loading, empty, waiting, active, ended, degraded, error, and recovery using the frozen copy.
- [ ] Deterministic spectator fixtures capture the same applicable states at desktop and narrow width.
- [ ] A review maps every visible datum to the existing match/player/shot contract or marks it unavailable; no new API field is invented in implementation.
- [ ] Accessibility evidence records VoiceOver order at an accessibility text size and keyboard/200% zoom behavior in spectator.

### G2 live network vertical slice

Capture a continuous, timestamped recording plus sanitized logs that identify Git SHA, deployment, Phone A model/iOS, Phone B model/iOS, and browser/version. The recording must show:

1. Phone A enters a callsign, creates the duel, and receives one six-character code.
2. Spectator selects that code and shows waiting/empty state.
3. Phone B joins with the same code; both phones and spectator show the same two names.
4. Host start is disabled until both players are ready and connected, then becomes enabled.
5. Host starts; both phones and spectator display the authoritative countdown and transition to `running` without manual refresh.
6. Before firing, Phone A, Phone B, and spectator each show Phone B health `100`; Phone A shows ammo `8`.
7. Phone A presses `DEBUG FIRE` once. The control shows pending, the accepted torso shot changes Phone A ammo to `7` and Phone B health to `66`, and all three surfaces converge to `66` without manual refresh.
8. Spectator appends exactly one `{SHOOTER} HIT {TARGET} • TORSO −34` event and exposes no mutation control or secret field.
9. The same `clientShotId` is submitted again through the test harness. Phone A remains at ammo `7`, Phone B remains at health `66`, and no second damage/event record appears.
10. The active phone temporarily loses network. Its input locks and stale state is labelled; after reconnect, it announces recovery and returns to the same authoritative `66` health. Spectator retains the last value during interruption and de-duplicates the recovered feed.

The G2 exit gate passes only when one physical phone damages the other through Convex, duplicate shot ID is idempotent, and health agrees on both physical phones and spectator. Simulator-only evidence cannot close G2.

## Implementation handoff

| Owner | This packet asks for | This packet does not authorize |
|---|---|---|
| Integration | Navigation, shared state mapping, Xcode/root changes, cross-surface evidence | Shared contract renames without review |
| Backend | Authoritative create/join/ready/start/fire and sanitized snapshots/events | Client damage or spectator mutation privileges |
| Spectator | The read-only state/layout/copy defined here | Radar, control mutations, or secret access |
| iOS targeting | No G1/G2 implementation work | Removing or disguising the debug path |
| Design | State/copy/token review inside `design/**` | Product/API behavior changes |

Any post-freeze change to behavior, acceptance, dynamic data, or copy requires integration approval and a written handoff to every affected owner. Pure alignment or spacing refinement may proceed without reopening the slice.
