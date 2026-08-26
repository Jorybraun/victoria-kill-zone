# Slice 002: Shared phone-proxy hit registration

| Field | Value |
|---|---|
| Status | Corrected and frozen for KIL-18 acceptance |
| Parent | KIL-17 (KIL-18 freezes this slice) |
| Design owner | `design/**` |
| Scope | Calibration through one Spatial Verdict, for a match.v2 player set of 2–4 |
| Semantics authority | [docs/features/shared-spatial-hit-registration/requirements.md](../../docs/features/shared-spatial-hit-registration/requirements.md) |
| Vocabulary authority | [CONTEXT.md](../../CONTEXT.md) |
| Contract authority | `# match.v2` in [docs/interface-contracts.md](../../docs/interface-contracts.md); `spatial-hit.v1` frozen by Integration before implementation |
| Successor | [Slice 003](003-four-player-spatial-combat.md) — see "Relationship to Slice 003" |

## Outcome

Any member of a 2–4 player match can understand whether shared spatial play is ready, know which member they are locked on, fire one valid shot, distinguish prediction from authority, and recover safely from tracking failure.

This written slice is the freeze: user states, copy, interaction behavior, accessibility, and acceptance evidence. No Figma deliverable is required. This slice invents no wire field and no product semantics; every rule below is presentation of the frozen requirements.

## Frozen rules (from the requirements, restated for designers)

- Target: 0.35 m radius sphere centred on the target phone, identical for every player and distance.
- Meaning: deliberate game objective, never player anatomy, never drawn as a body outline.
- Lane: 3–15 m straight-line separation in the Shared Arena Frame, applied pairwise between the shooter and a candidate. It filters who is hittable; it never disables the trigger.
- Rewind cap 250 ms; maximum pose age 100 ms; both bounds inclusive and never clamped.
- **A lock is not permission to fire.** While the fire gates are open — match live, shooter alive, shooter's tracking normal, geofence permitting, ammunition, cooldown — the trigger always fires one shot from the current camera ray. Target detection is advisory feedback; a shot at nothing is a confirmed miss, never a suppressed input and never `ACQUIRE TARGET`.
- Tracking loss locks fire on the affected phone only, and the locked state names the closed gate.
- Shot presentation is shared: the shooter sees a predicted tracer, and every other member sees exactly one transient `INCOMING SHOT` tracer per shot identity — including for misses. Confirmation reconciles the outcome without replaying the tracer.
- Hitscan with a visual tracer. The tracer is presentation of an instantaneous ray; there is no projectile speed, travel time, or dodge window in this slice.
- The Authority Host produces a Provisional Spatial Verdict; only the Authoritative Spatial Verdict changes health, ammunition, or score.
- Capability decides affordances. The words "host", "guest", and "opponent" never appear in player-visible copy; a target is named by callsign.

## Player set in this slice

- 2–4 members. Nothing in this slice assumes exactly two; a state that renders correctly for one target must render correctly for three.
- At any moment a shooter has zero or one **candidate** highlighted from up to three detected proxies. Candidacy is advisory decoration on `ready` and `predicted`, never a state and never a gate.
- Undetected and unhighlighted proxies read as identified but not called out; the highlighted candidate carries the ring, callsign, and live distance.
- With zero candidates the frame still reads as ready to fire: `FIRE`, live crosshair, enabled trigger.
- A member who is down is not hittable; a shot toward them resolves as a confirmed miss, and a legacy claim naming them reports `TARGET IS DOWN`.

## Relationship to Slice 003

- **This slice is the authority for the eight spatial states below.** Slice 003 (KIL-40) is its N-player successor for match.v2 lobby and roster, multi-opponent HUD attribution, kill feed, death/respawn, podium, and per-player accent tokens. Slice 003 carries this state machine unchanged.
- Slice 003 remains **proposed and unaccepted**, and it does not gate KIL-18 or KIL-19. If Slice 003 and this slice ever disagree on a spatial state, its copy, or its accessibility behavior, this slice wins until Slice 003 is accepted.
- Neither slice may change a frozen limit or the authority chain; that requires an accepted requirements revision.

## Required phone frames

1. `01 / Calibration` (all members aligning)
2. `02 / Ready` (two variants required: no candidate detected, and one candidate highlighted — both show `FIRE` with an enabled trigger)
3. `03 / Firing · Predicted`
4. `04 / Result · Hit Confirmed`
5. `05 / Result · Miss Confirmed`
6. `06 / Result · Rejected`
7. `07 / Tracking · Degraded`
8. `08 / Tracking · Recovery`

Baseline viewport is 390 × 844 pt. Existing VKZ theme variables, text styles, Button, Status Chip, and Telemetry components remain the source design system. Slice 003's per-player accent tokens are additive and are used here only where a callsign or ring needs identity.

## State-by-state behavior

| Frame | Entry | Must show | Must never do |
|---|---|---|---|
| Calibration | Spatial setup begins | `ALIGNING SHARED ARENA…`, per-member alignment progress, an explicit stop state when tracking is inadequate | Complete while any member is unaligned |
| Ready | Fire gates open on this phone | `FIRE`, live crosshair, ammunition, tracking chip, `3 M MINIMUM` safety guidance, and a candidate callsign with live `{DISTANCE} M` when one is detected | Disable the trigger for any target reason, or show lock-required copy |
| Predicted | Trigger press | `SHOT PREDICTED`, naming the candidate only when there is one, one short amber tracer, `AWAITING AUTHORITATIVE VERDICT` | Change health, ammunition, score, or announce a hit |
| Incoming (overlay on any state) | A remote shot arrives | One transient `INCOMING SHOT` tracer along the shared-arena origin and direction, for hits and misses alike | Draw a second tracer for a shot identity already seen, or on reconciliation or reconnect |
| Hit Confirmed | Authoritative hit | Green terminal point and `HIT CONFIRMED` with target and damage, reconciled health and ammunition as one change | Stack a second result beside the predicted panel |
| Miss Confirmed | Authoritative miss | `MISS CONFIRMED`, ray fades to muted grey | Apply damage anywhere |
| Rejected | Authoritative rejection | Red result panel with the one canonical reason label and its corrective action | Show more than one reason, or imply damage |
| Degraded | Tracking loss on this phone | `TRACKING LOST — FIRE LOCKED`, last trusted positions dimmed and labelled stale, trigger locked | Reuse a stale transform, or lock other members' phones |
| Recovery | Fresh shared lock | `SPATIAL LOCK RESTORED`, then return to Ready | Replay an earlier shot animation, or resolve a pre-loss pending claim |

Colour never carries a state alone: every state above pairs its colour with text.

## First small win: Firing · Predicted

### Hierarchy

- Top HUD: health, `SPATIAL LOCK`, ammunition.
- Arena view: live camera surface, crosshair, one short amber predicted tracer, and — when a candidate is detected — its neutral proxy ring with callsign and distance plus up to two further proxy outlines. The frame must also read correctly with no proxy visible at all.
- Result panel: `SHOT PREDICTED`, `AWAITING AUTHORITATIVE VERDICT`. The trigger re-arms on cooldown; a pending verdict does not hold it.
- Safety footer: `CONTROLLED AREA • 3–15 M`.

### Behavior

- Trigger press creates one local prediction for one shot, with or without a candidate.
- No health, score, ammunition, or hit announcement changes before authoritative match state arrives.
- The authoritative result replaces the predicted panel in place; a contradicting result visibly corrects it.
- Loss of tracking routes immediately to Degraded and locks fire.

### Accessibility

- VoiceOver: `Shot predicted. Awaiting authoritative verdict.`
- The ready state announces `Ready to fire.` with no candidate, and `Ready to fire. {callsign}, {distance} metres.` with one.
- An incoming remote shot announces `Incoming shot.` once per shot identity.
- The proxy ring has a text-equivalent candidate callsign and distance label.
- Amber indicates pending only when paired with a result label.
- Reduce Motion uses a static tracer and an opacity change instead of an animated sweep.

## Copy

All player-visible copy for these states is the canonical label catalog in the requirements (§9). This slice adds no synonym and no variant; the only slice-local strings are the layout labels `SPATIAL LOCK` (the tracking chip), `AWAITING AUTHORITATIVE VERDICT`, `3 M MINIMUM`, `CONTROLLED AREA • 3–15 M`, and the `{DISTANCE} M` readout. `SPATIAL LOCK READY` is retired, and no frame may introduce `ACQUIRE TARGET` or any other lock-required wording.

## State transitions

```text
Calibration → Ready → Predicted → Hit Confirmed
                              ↘ Miss Confirmed
                              ↘ Rejected
Any spatial state → Degraded → Recovery → Ready
```

All three result branches return to Ready. Match lifecycle states around this machine — lobby, countdown, elimination, respawn, podium — belong to Slice 003.

## Acceptance evidence for this slice

- Documentation and deterministic gates: Gates A and B in [acceptance.md](../../docs/features/shared-spatial-hit-registration/acceptance.md).
- Presentation, copy, and accessibility: Gate C (simulator, requires Xcode).
- Live shared-3D behavior: Gate D (2–4 physical iPhones). A compile or simulator run is never physical-device evidence.

## Out of scope

- Persistent Projectile Worldline travel, speed, lifetime, and dodge mechanics. The tracer here is hitscan presentation only.
- Any design that gates trigger input on target detection.
- Personal time.
- Body-zone collision.
- Lobby, roster, kill feed, death, respawn, podium, and accent-token definition (Slice 003).
- Shared contract, `docs/interface-contracts.md`, or production code changes.
