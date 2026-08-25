# Slice 003: Four-player spatial combat states

| Field | Value |
|---|---|
| Status | Proposed baseline for KIL-40 review |
| Parent | KIL-40 |
| Supersedes | The 1v1-only assumptions of [Slice 002](002-shared-phone-proxy-hit-registration.md); its calibration/verdict state machine and its frozen token system carry over unchanged |
| Design owner | `design/**` |
| Scope | 2–4 player lobby/roster, per-opponent spatial identification, multi-opponent HUD, death/respawn, and the 2–4 player podium |
| Contract authority | `# match.v2` in [docs/interface-contracts.md](../../docs/interface-contracts.md); spatial vocabulary from spatial-hit.v1 and [CONTEXT.md](../../CONTEXT.md) |

## Outcome

Up to four people can form one match, calibrate one Shared Arena Frame, know exactly which of up to three opponents they are locked on at 3–15 m, fire, understand who they hit and who hit them, die and return while the others keep fighting, and read one unambiguous 2–4 player podium at the end.

This packet freezes user states, tokens, copy, interaction behavior, and acceptance evidence per AGENTS.md design/build parallelism. Per AGENTS.md, this written slice is the freeze; no Figma work is required or in scope. Every decision consumes the frozen match.v2 contract as-is; this slice invents no wire field. Anything a state would need beyond match.v2 is listed under "Contract needs (handoff to Integration)".

## Slice boundary

### In this slice

- Match vocabulary for v2 surfaces: player set of 2–4, capability-driven start, `left` event, capacity-full state.
- Lobby/roster states for join, leave, ready toggles, the `canStartMatch` holder's start affordance, and cancellation when every `canStartMatch` holder leaves.
- The slice-002 state machine (calibration → ready → predicted → hit/miss/rejected, any spatial state → degraded → recovery) extended per opponent: lock identification, name tag over the proxy ring, distance readout, per-player color and glyph.
- Multi-opponent HUD: outgoing verdict attribution (`who you hit`), incoming damage attribution (`who hit you`, directional indicator decision), and a 4-player kill feed with frozen ordering, row cap, and coalescing rules.
- Death/respawn states for N players, including what a dead player sees while the others fight and how a dead proxy renders to living shooters.
- Match-end podium for 2–4 players with the exact generalized winner rule and exact-tie rendering.
- Four accessible per-player accent colors added beside the frozen slice-001 token system.

### Explicitly outside this slice

- More than 4 players (Phase 1 cap per ADR 0003; beyond requires a new decision record).
- Any change to slice-002's frozen candidate rules: 0.35 m proxy radius, 3–15 m lane, 250 ms rewind cap, 100 ms maximum pose age, both-phones-tracked fire gate, host-provisional/Convex-authoritative verdicts.
- Teams, assists, spectate-a-player camera, persistent projectiles, personal time, body-zone collision.
- v1 surfaces: g2.v1 and phase0.v1 copy from Slice 001 remains frozen and untouched; this slice's copy applies to match.v2 surfaces only.
- Shared contract, `docs/**`, or production code changes.
- Figma or any high-fidelity visual deliverable; this document is the freeze.

## Frozen candidate rules (carried and generalized)

- Every member has a Phone Target Proxy (0.35 m sphere on the phone; deliberate objective, not anatomy).
- The 3 m minimum separation applies pairwise between shooter and the named target, never to a single fixed opponent.
- A Frame-Aligned Shot Claim names exactly one `targetId` chosen from the targetable set: a member, not the shooter, `lifeState` alive.
- Fire requires the shooter's phone and the locked target's proxy both aligned with normal tracking; loss of tracking locks fire immediately.
- Host Spatial Verdict is provisional; Convex match state is authoritative.
- Rejection vocabulary is unchanged from spatial-hit.v1: `TRACKING LOST`, `TARGET TOO CLOSE`, `TARGET OUT OF RANGE`, `POSE TOO OLD`, `SHOT TOO LATE`.

## State machine

Slice 002's machine is carried unchanged and wrapped by the match.v2 lifecycle:

```text
Lobby (2–4 join/leave/ready) → Countdown → Calibration → Ready
Ready → Predicted → Hit Confirmed → Ready
                 ↘ Miss Confirmed → Ready
                 ↘ Rejected → Ready
Any spatial state → Degraded → Recovery → Ready
Hit taken to 0 health → Eliminated → Respawn wait → Ready (via Recovery if lock was lost)
Running → Finished (Podium)
Lobby → Cancelled (every canStartMatch holder left)
```

Per-opponent identification is a property of `Ready`/`Predicted`, not a new state: at any moment the shooter has zero or one locked opponent chosen from up to three targetable proxies.

## Required phone frames

1. `01 / Lobby · Forming` (2–3 of capacity)
2. `02 / Lobby · Full` (capacity reached)
3. `03 / Lobby · Player Left`
4. `04 / Lobby · Cancelled`
5. `05 / Countdown`
6. `06 / Calibration` (N players aligning)
7. `07 / Ready · Multi-proxy` (3 opponents visible, one locked)
8. `08 / Firing · Predicted`
9. `09 / Result · Hit Confirmed`
10. `10 / Result · Miss Confirmed`
11. `11 / Result · Rejected`
12. `12 / Incoming · Hit By`
13. `13 / Eliminated · Respawn Wait`
14. `14 / Respawned`
15. `15 / Tracking · Degraded`
16. `16 / Tracking · Recovery`
17. `17 / Podium · Winner`
18. `18 / Podium · Exact Tie`

Baseline viewport is 390 × 844 pt. Existing VKZ theme variables, text styles, Button, Status Chip, and Telemetry components remain the source design system.

## 1. Lobby and roster (match.v2 player sets)

### State model

| State | Trigger | Behavior and copy | Exit |
|---|---|---|---|
| **Forming** | Phase `lobby`, players below `playerCapacity` | Header `MATCH {CODE}`; capacity readout `PLAYERS {N} / {CAP}`; one card per member in snapshot order; remaining slots read `OPEN SLOT`; helper `SHARE CODE {CODE}` | Capacity reached, start, cancel, or leave |
| **Full** | Players equal `playerCapacity` | Capacity readout shows `{CAP} / {CAP}`; helper becomes `MATCH FULL`; no open-slot cards remain; an outside join attempt sees `MATCH IS FULL` inline at its join field | Start, leave, or cancel |
| **Player left** | Snapshot removes a member; feed gains one `left` event | Removed card disappears, slot reopens, feed row `{PLAYER} LEFT`; no other player's ready state changes | Continues forming |
| **Cancelled** | Every `canStartMatch` holder has left during lobby | Full-screen terminal state `MATCH CANCELLED`, helper `THIS MATCH CAN NO LONGER START`, action `RETURN HOME` | User leaves |
| **Countdown** | A `canStartMatch` holder started; phase `countdown` | `MATCH STARTS IN` with server-derived `3`, `2`, `1` from `startsAt`; roster stays visible; all controls lock | Phase `running` → Calibration |

### Roster card anatomy (each of up to 4)

- Player accent chip: glyph + color (section 5) at the card's leading edge.
- `{CALLSIGN}` in `type.ui`; connection text (`CONNECTED` / `OFFLINE`) and ready text (`READY` / `NOT READY`) always as words, never color alone.
- The local player's own card carries the ready toggle: `I'M READY` ↔ `NOT READY` (copy carried from Slice 001).

### Start affordance (capability-driven, never "host")

- The `START MATCH` control renders only on phones whose own `PlayerV2Snapshot.capabilities` contains `canStartMatch`. Capability presence is the sole test; UI copy never contains the words "host", "owner", or "leader".
- Enabled only when the snapshot shows at least 2 members and every current member ready, connected, and presence-fresh (mirrors the matchesV2:start rule; the backend remains authoritative and a rejection returns to the lobby with mapped copy).
- Disabled helpers, exactly one at a time, in this precedence: `AT LEAST 2 PLAYERS REQUIRED`, then `ALL PLAYERS MUST BE READY`, then `ALL PLAYERS MUST BE CONNECTED`.
- Phones without `canStartMatch` show the status line `WAITING FOR MATCH START` where the control would be. They never render a disabled start button.
- `LEAVE MATCH` is available to every member during lobby only. After a successful leave the leaver returns home; remaining phones render the `left` feed row.

### Lobby copy

| Element | Copy |
|---|---|
| Lobby title | `MATCH {CODE}` |
| Capacity readout | `PLAYERS {N} / {CAP}` |
| Share helper (below capacity) | `SHARE CODE {CODE}` |
| Capacity-full helper | `MATCH FULL` |
| Empty slot | `OPEN SLOT` |
| Ready action / undo | `I'M READY` / `NOT READY` |
| Ready / unready label | `READY` / `NOT READY` |
| Start action | `START MATCH` |
| Start helper — too few | `AT LEAST 2 PLAYERS REQUIRED` |
| Start helper — unready | `ALL PLAYERS MUST BE READY` |
| Start helper — disconnected | `ALL PLAYERS MUST BE CONNECTED` |
| Non-holder status | `WAITING FOR MATCH START` |
| Leave action | `LEAVE MATCH` |
| Left feed row | `{PLAYER} LEFT` |
| Countdown label | `MATCH STARTS IN` |
| Cancelled title | `MATCH CANCELLED` |
| Cancelled helper | `THIS MATCH CAN NO LONGER START` |

### Error mapping (v2 additions)

| Condition | User-facing copy |
|---|---|
| `MATCH_FULL` on join | `MATCH IS FULL` |
| `MATCH_ALREADY_STARTED` on join or leave | `MATCH ALREADY STARTED` |
| `CAPABILITY_REQUIRED` (defensive; the control is hidden) | `YOU CAN'T START THIS MATCH` |
| `INVALID_TARGET` / `TARGET_NOT_ALIVE` on a stale claim | `TARGET NO LONGER VALID` |

All other error copy carries over from Slice 001 with `DUEL` read as `MATCH` on v2 surfaces (`CAN'T REACH THE MATCH`, `MATCH CODE NOT FOUND`).

## 2. Calibration → verdict machine with per-opponent identification

Calibration, Ready, Predicted, Hit/Miss/Rejected, Degraded, and Recovery keep Slice 002's hierarchy, behavior, accessibility, and copy (`ALIGNING SHARED ARENA…`, `SPATIAL LOCK READY`, `SHOT PREDICTED`, `HIT CONFIRMED`, `MISS CONFIRMED`, `TRACKING LOST — FIRE LOCKED`, `SPATIAL LOCK RESTORED`, safety footer `CONTROLLED AREA • 3–15 M`). This section freezes only what N players add.

### Calibration

- The calibration frame lists every member with per-player alignment text: `{CALLSIGN} — ALIGNING…` / `{CALLSIGN} — ALIGNED`.
- Combat cannot begin for a shooter until the shooter's own phone is aligned; an unaligned opponent simply has no trusted proxy and is not lockable. Alignment is per-pair, not all-or-nothing.

### Ready with up to three opponent proxies

Every targetable opponent (member, not self, `lifeState` alive, trusted tracking, inside 3–15 m pairwise) renders a Phone Target Proxy ring. Exactly zero or one is locked at a time.

| Proxy state | Ring | Tag |
|---|---|---|
| Locked | Solid ring in the opponent's accent color, full opacity, crosshair engaged | Name tag over the ring: `{GLYPH} {CALLSIGN}` plus distance readout `{DISTANCE} M` (whole metres, `type.telemetry`) |
| Targetable, unlocked | 60 %-opacity outline ring in the opponent's accent | Glyph-only chip `{GLYPH}`; no distance, to limit clutter |
| Too close (< 3 m) | Muted (`color.textMuted`) outline | `TOO CLOSE` |
| Out of range (> 15 m) | Muted outline | `OUT OF RANGE` |
| Dead / respawning | 30 %-opacity dashed outline in the accent | `DOWN` |
| Disconnected | 30 %-opacity dashed muted outline | `OFFLINE` |

Lock selection and behavior:

- The lock is the targetable proxy whose ring centre is nearest the crosshair within the aim cone. No manual target cycling exists in this slice.
- Lock switching applies 150 ms of hysteresis so two overlapping proxies do not flicker.
- The top HUD shows the persistent lock line: `LOCKED {CALLSIGN} • {DISTANCE} M` while locked, or `NO LOCK` when no proxy qualifies. `SPATIAL LOCK READY` remains the tracking-state chip and is independent of whether a target is currently locked.
- Distance readouts are computed locally from trusted Phone Pose Samples; they are diagnostics, never authority.

VoiceOver: `Locked on {callsign}, {n} metres.` on lock change; `No lock.` when lost. Announcements are polite and rate-limited to lock changes, not per-frame distance updates.

### Predicted and verdicts, attributed

- Trigger with a lock submits one Frame-Aligned Shot Claim naming the locked player's id; trigger without a lock submits a miss claim (no `targetId`). One press, one `clientShotId`; a retry reuses it.
- Predicted panel adds attribution: `SHOT PREDICTED` headline, sub-line `TARGET {CALLSIGN}`, then `AWAITING VERDICT`. Repeat fire stays disabled while the logical shot is pending.
- `HIT CONFIRMED • {CALLSIGN} −{DAMAGE}` replaces the predicted panel as one state change. A lethal verdict shows `ELIMINATED {CALLSIGN}` instead.
- `MISS CONFIRMED` and the five rejection reasons render exactly as Slice 002; a rejection additionally keeps the attempted target name in the panel sub-line so the shooter knows which pairing failed (`TARGET {CALLSIGN}`).
- If the locked target dies or disconnects between lock and press, the claim is submitted as aimed and the authoritative rejection maps to `TARGET NO LONGER VALID`.

### Degraded and Recovery with N players

- Degraded is per-phone: a phone that loses tracking locks its own fire and shows Slice 002's degraded frame; the other phones keep fighting. That player's proxy renders `OFFLINE`-style dashed on opponents' screens only if presence also expires; a tracking-degraded but connected player simply stops being lockable (no trusted proxy) and shows no ring.
- Recovery requires the recovering phone to re-establish the shared lock; `SPATIAL LOCK RESTORED` then returns to Ready. Old shot animations are never replayed.

## 3. Multi-opponent HUD

### Outgoing: who you hit

Attribution lives in the result panel (section 2). The kill feed carries the same authoritative event once; the panel and the feed never disagree because both render only authoritative match events.

### Incoming: who hit you (directional damage indicator — frozen decision)

- **Decision:** a screen-edge arc segment, not a full-screen flash. One confirmed incoming hit renders a 120°-wide arc at the screen edge oriented toward the bearing of the shooter's last trusted proxy position, in the shooter's accent color, fading in over 100 ms and holding 1.5 s.
- The arc is always paired with a text chip: `HIT BY {CALLSIGN} −{DAMAGE}` (danger-styled, includes the shooter's glyph). Color and direction never carry the meaning alone.
- If the shooter's bearing is unknown (victim degraded, shooter proxy stale), render the non-directional bottom-centre chip only — same copy, no arc. Never fake a direction.
- One confirmed hit produces exactly one haptic and one polite VoiceOver announcement: `Hit by {callsign}, minus {damage}. Health {health}.` Predicted remote shots change nothing (carried rule).
- A lethal incoming hit routes directly to the Eliminated state (section 4); the chip is not shown twice.
- Reduce Motion: the arc appears at full opacity without animation and dissolves without pulse. Full-screen flashes remain forbidden (Slice 001 accessibility contract).

### Kill feed (phone and spectator)

- Content: authoritative match events of type `hit`, `eliminated`, `respawned`, `left`, `shot` (miss rows appear on spectator only; phones suppress miss rows to reduce noise).
- Ordering: server order — `createdAt` descending, then id ascending — newest row at top. The feed never synthesizes a row from a local animation and de-duplicates by event id after reconnect.
- Row cap: maximum 3 visible rows on phone; a new row pushes the oldest out. Rows auto-expire from the phone HUD 6 s after appearing. Spectator keeps its persistent scrollable feed from Slice 001 with no cap.
- Coalescing (display-only; underlying events stay distinct): consecutive visible rows with the same shooter, same target, and both nonlethal hits within 4 s collapse into one row showing summed damage and a count: `{SHOOTER} ▸ {TARGET} −{TOTAL} ×{N}`. `eliminated`, `respawned`, and `left` rows never coalesce and break any run.

| Feed row | Copy |
|---|---|
| Hit | `{SHOOTER} ▸ {TARGET} −{DAMAGE}` |
| Coalesced hits | `{SHOOTER} ▸ {TARGET} −{TOTAL} ×{N}` |
| Elimination | `{SHOOTER} ELIMINATED {TARGET}` |
| Respawn | `{PLAYER} RESPAWNED` |
| Left (lobby) | `{PLAYER} LEFT` |

Both names in a row render with their accent glyph. Rows involving the local player use `color.text` emphasis; all other rows use `color.textMuted`.

### Roster strip

During `running`, a compact roster strip (top edge, under the HUD) shows every player as `{GLYPH} {HEALTH}` in accent color plus text. Dead players show `{GLYPH} —`. This is the only always-on N-player status surface; full statistics wait for the podium.

## 4. Death, respawn, and the podium

### Eliminated (what a dead player sees)

| Element | Frozen behavior |
|---|---|
| Title | `ELIMINATED BY {CALLSIGN}` with the killer's glyph and accent |
| Countdown | `RESPAWN IN {SECONDS}` derived from authoritative `respawnAt`, never a chained local timer |
| Camera | Live camera stays up, dimmed to 40 %; crosshair and proxy rings hidden; fire and reload locked |
| Continuity | Roster strip and kill feed remain visible so the dead player can follow the fight |
| Accessibility | One announcement: `Eliminated by {callsign}. Respawning in {seconds} seconds.`; countdown updates do not steal focus |

The dead player's proxy renders to others as the dashed `DOWN` ring (section 2) and is never lockable; the targetable-set rule makes a claim against it authoritatively rejected.

### Respawned

- One state change on the authoritative respawn: health `100`, ammo `8`, `lifeState` alive.
- Flash label `BACK IN` with sub-line `HEALTH 100 • AMMO 8`, then return to Ready. If spatial lock was lost while dead, route through Recovery first.
- Others see the feed row `{PLAYER} RESPAWNED` and the ring return to targetable.

### Podium (phase `finished`, 2–4 players)

- Title `MATCH COMPLETE`.
- Winner banner: `WINNER — {CALLSIGN}` in the winner's accent with glyph, shown only when `winnerPlayerId` is present. The banner trusts the server field; the client never computes the winner.
- Ranked table, one row per member: rank, `{GLYPH} {CALLSIGN}`, `KILLS`, `DEATHS`, `DMG` columns (`type.telemetry` values). Ranks below the winner are ordered client-side by the same rule; players tied on all three values share a rank shown as `T{RANK}`.
- Winner-rule footer, exact frozen copy: `RANKED BY MOST KILLS, THEN FEWEST DEATHS, THEN MOST DAMAGE`.
- Exact tie: when `winnerPlayerId` is absent, the banner reads `NO WINNER — EXACT TIE`, and every fully tied player shares `T1`. No confetti, no accent glow; neutral telemetry styling.
- Exit action `LEAVE MATCH`; spectator shows the same table with `WATCH ANOTHER MATCH`.

### Death and podium copy

| Element | Copy |
|---|---|
| Eliminated title | `ELIMINATED BY {CALLSIGN}` |
| Respawn countdown | `RESPAWN IN {SECONDS}` |
| Respawn flash | `BACK IN` |
| Respawn sub-line | `HEALTH 100 • AMMO 8` |
| Podium title | `MATCH COMPLETE` |
| Winner banner | `WINNER — {CALLSIGN}` |
| Tie banner | `NO WINNER — EXACT TIE` |
| Rank columns | `KILLS` / `DEATHS` / `DMG` |
| Winner-rule footer | `RANKED BY MOST KILLS, THEN FEWEST DEATHS, THEN MOST DAMAGE` |

## 5. Per-player accent colors

All Slice 001 tokens are frozen and unchanged, including `color.bg` `#070B10` and `color.telemetry` `#35D9E6`. The four player accents below are additive tokens; no existing token is renamed, repurposed, or revalued. No change request is needed.

| Token | Value | Glyph | Notes |
|---|---|---|---|
| `color.player1` | `#4DA3FF` | `●` | Blue; distinct from `color.telemetry` cyan by hue and by never appearing without its glyph |
| `color.player2` | `#EDE04B` | `▲` | Yellow; greener and lighter than `color.pending` amber `#FFB340` |
| `color.player3` | `#B78CFF` | `■` | Violet |
| `color.player4` | `#FF7AD9` | `◆` | Magenta; pinker and lighter than `color.danger` `#FF5364` |

Rules:

- Every accent exceeds 3:1 contrast against `color.bg` and `color.surface` for ring, glyph, and tag use. Accent-colored body text is not permitted; names render in `color.text` with the accent confined to glyph, ring, chip, and bar fills.
- Color never carries identity alone: every accent use pairs the glyph and, wherever space allows, the callsign. The four glyphs are shape-distinct for color-vision deficiency and monochrome displays.
- Assignment: accent index = the player's position in the snapshot `players` array (joinedAt ascending, then id ascending), identically derived on every phone and the spectator, so all surfaces agree without any wire field.
- During lobby, a leave shifts later joiners down one index and recolors them; the roster card animates nothing and simply re-renders (Reduce Motion safe). At `start` the member set freezes, so accents are stable for countdown, combat, death, and podium.
- Semantic colors keep their frozen jobs: verdict states stay cyan/amber/green/grey/red exactly as Slice 002's role feedback; accents identify players, never outcomes.

## 6. Acceptance evidence

Evidence is tied to one Git SHA and one Convex deployment, captured on four physical phones (name each model and iOS version) plus one spectator browser. No secrets, device identifiers, or raw endpoints. Simulator-only evidence cannot pass this slice.

| # | Reviewer must observe |
|---|---|
| 1 | `pnpm verify` passes on the exact SHA |
| 2 | Phone 1 creates a match (capacity 4); Phones 2–4 join with the code; every phone shows `PLAYERS 4 / 4`, `MATCH FULL`, and four roster cards with correct callsigns, glyphs, and accents in identical order on all surfaces |
| 3 | A fifth join attempt on a spare device shows `MATCH IS FULL` inline and changes no roster |
| 4 | Phone 3 leaves; every remaining phone shows the `{PLAYER} LEFT` feed row, an `OPEN SLOT`, and `PLAYERS 3 / 4`; Phone 3 rejoins successfully |
| 5 | Only the creating phone renders `START MATCH`; the other phones show `WAITING FOR MATCH START`; no visible copy anywhere contains the word "host" |
| 6 | Start stays disabled with `ALL PLAYERS MUST BE READY` until the last ready toggle, then enables; start produces one server-derived `MATCH STARTS IN` countdown on all four phones |
| 7 | After calibration, one shooter phone simultaneously shows three opponent proxies: the locked one with solid accent ring, name tag, and live `{DISTANCE} M`; the others as glyph-tagged outlines; sweeping aim between two opponents switches the `LOCKED {CALLSIGN}` line without flicker |
| 8 | A pairwise walk inside 3 m shows `TOO CLOSE` and blocks the lock for that opponent only; the other opponents remain lockable |
| 9 | Shooter fires at a named opponent: `SHOT PREDICTED` with `TARGET {CALLSIGN}`, then one `HIT CONFIRMED • {CALLSIGN} −{DAMAGE}`; the victim phone shows the directional arc plus `HIT BY {CALLSIGN} −{DAMAGE}` in the shooter's accent with one haptic; the two uninvolved phones change no health and show only the single kill-feed row |
| 10 | Kill feed on every surface shows newest-first server order, at most 3 rows on phones, and two rapid nonlethal hits by the same pairing coalesce to `−{TOTAL} ×2` while the spectator feed keeps both underlying events |
| 11 | A player is eliminated: the dead phone shows `ELIMINATED BY {CALLSIGN}` and an authoritative `RESPAWN IN {SECONDS}` while its feed and roster strip keep updating; the other phones show the `DOWN` dashed ring and cannot lock it; combat between the remaining players continues uninterrupted |
| 12 | On respawn, the dead phone shows `BACK IN` with health `100`, ammo `8`; others see `{PLAYER} RESPAWNED` and can lock the ring again |
| 13 | Covering one phone's camera locks fire on that phone only (`TRACKING LOST — FIRE LOCKED`); the other three keep fighting; recovery shows `SPATIAL LOCK RESTORED` without replaying old shots |
| 14 | Match end with a clear leader: all four phones and the spectator render the same podium order, `WINNER — {CALLSIGN}`, and the footer `RANKED BY MOST KILLS, THEN FEWEST DEATHS, THEN MOST DAMAGE` |
| 15 | A staged exact tie (end a match in which no shots landed) renders `NO WINNER — EXACT TIE` with all players at `T1` and no winner banner on any surface |
| 16 | Accessibility spot-check: VoiceOver reads lock changes (`Locked on {callsign}, {n} metres`), the incoming-hit announcement once per confirmed hit, and the eliminated announcement once; Reduce Motion shows static arcs and no full-screen flash |

## Contract needs (handoff to Integration)

This slice requires **no new wire field**. Two derivations and one optional future field are recorded for transparency:

1. **Player accent identity** is derived from snapshot player order (joinedAt ascending, then id ascending), which match.v2 already freezes. Consequence accepted by design: a lobby leave recolors later joiners until start. If Integration ever wants leave-stable lobby colors, that would need a stable per-player join-sequence field in a future contract revision — not requested for this slice.
2. **Distance readouts and the directional damage bearing** are computed locally from spatial-hit.v1 Phone Pose Samples; when no trusted bearing exists the UI falls back to the non-directional chip. No shot-origin or bearing field is requested on any snapshot or event.
3. **Kill-feed attribution** uses existing `MatchV2EventSnapshot` fields (`type`, `actorPlayerId`, `targetPlayerId`, `damage`, `id`, `createdAt`) only; coalescing is display-only and never mutates or suppresses authoritative events.

## Implementation handoff

| Owner | This packet asks for | This packet does not authorize |
|---|---|---|
| Integration | Cross-surface accent/order derivation review, evidence capture wiring for 4 phones, any future contract-revision decision from the list above | Adding wire fields without a contract revision |
| Backend | Nothing new; matchesV2/shotsV2 as frozen in `# match.v2` | Client damage, capability grants from clients, spectator mutations |
| Spectator | 2–4 player cards, persistent feed, podium table per this packet | Radar, per-player camera, mutation controls |
| iOS targeting | Lock selection, proxy rendering, directional indicator, HUD states per this packet | Weakening the tracking fire gate or the debug path rules |
| Design | State/copy/token review inside `design/**` | Product/API behavior changes |

Any post-freeze change to behavior, acceptance, dynamic data, or copy requires integration approval and a written handoff to every affected owner. Pure alignment or spacing refinement may proceed without reopening the slice.
