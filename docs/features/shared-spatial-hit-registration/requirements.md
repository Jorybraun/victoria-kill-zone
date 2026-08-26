# Shared phone-proxy hit registration requirements

| Field | Value |
|---|---|
| Status | Corrected and frozen for KIL-18 acceptance. Becomes the accepted packet when Integration merges it; no implementation dispatch before then. |
| Scope | Calibration through one Spatial Verdict for one Frame-Aligned Shot Claim, for a match.v2 player set of 2–4 |
| Product authority | [ADR 0003](../../decisions/0003-multiplayer-first-refounding.md), [docs/roadmap.md](../../roadmap.md) Phase 1, [victoria-kill-zone-technical-spec.md](../../../victoria-kill-zone-technical-spec.md) §0 amendment A1 |
| Vocabulary authority | [CONTEXT.md](../../../CONTEXT.md) |
| Contract position | `phase0.v1` unchanged; `match.v2` frozen and unchanged; `spatial-hit.v1` to be frozen by Integration before cross-workstream implementation |
| Owner | Integration |

## Outcome

Two to four players calibrate one Shared Arena Frame, see every other member as a deliberate Phone Target Proxy, fire one Frame-Aligned Shot Claim at one named targetable player, and receive one understandable predicted, confirmed-hit, confirmed-miss, rejected, degraded, or recovered result. Persistent Projectile Worldlines and personal time are excluded.

## 1. Production placement (the accepted pivot)

Shared spatial hit registration is production Phase 1 scope, not a post-MVP idea.

- [ADR 0003](../../decisions/0003-multiplayer-first-refounding.md) is the accepted decision record that re-founds the product as multiplayer-first with a Phase 1 cap of 4 players. This packet cites it; it does **not** create a second ADR 0003, and no `0003-shared-spatial-hit-pivot.md` is written. The obsolete request for that filename is withdrawn.
- ADR 0004 remains reserved for the measured realtime authority and transport decision that follows KIL-21. This packet must not pre-empt it.
- The technical specification's placement of the shared ARKit coordinate system in §19 "P2: do not risk P0" and in §23.1 "Post-MVP architecture" is superseded for Phase 1 by ADR 0003 and by amendment A1 in that document. Every other section of the specification stands.
- **The fallback is preserved.** The committed stack (Swift/SwiftUI + ARKit + Vision + Core Location, Convex authority, React spectator) is unchanged, and the `shots:debugFire` network path stays in place and callable until markerless spatial targeting replaces it with physical-device evidence. Screen-space Vision claims remain the shipping hit source until that evidence exists; this packet does not retire them.

## 2. Contract position

- No current `phase0.v1` wire name, field, enum, constant, or fixture changes in this packet, and none may change as a consequence of accepting it. `g2.v1` and `geofence.v1` are likewise untouched.
- `match.v2` is already frozen in [docs/interface-contracts.md](../../interface-contracts.md) and is consumed as-is: player sets of 2–4, server-assigned `PlayerCapability` values, and fire validated against "a targetable player". This packet invents no wire field.
- `spatial-hit.v1` is the vocabulary and semantics surface described here. **Integration freezes `spatial-hit.v1` in `docs/interface-contracts.md` before any cross-workstream implementation of it.** Until that freeze exists, `ios/**`, `convex/**`, and `spectator/**` may not encode or decode a spatial payload.
- The merged deterministic simulation core (KIL-34, `shared/simulation/**`) already implements the semantics in §4 and §5 and cites this document as its authority. The two must stay bit-identical in meaning: a change to any predicate here requires a matching change there in the same accepted revision.

## 3. Must decide now versus measure later

Everything in §4–§9 is **must-decide-now semantics**: it fixes meaning, ordering, vocabulary, and fail-closed behavior, and it cannot be resolved by measurement. Nothing in it may be renegotiated inside an implementation ticket.

The following are **measure-later thresholds**. Each has an owner issue and a fail-closed default that holds until a measurement replaces it through an accepted revision.

| Deferred question | Owner | Fail-closed default until measured |
|---|---|---|
| Acceptable transform disagreement between phones at 3 m, 8 m, and 15 m | KIL-20 | Any disagreement that a player can perceive as a wrong verdict blocks the physical-device gate; no tolerance is claimed |
| Tracking-quality signal that maps to "normal" on real devices, and the relocalization recovery time | KIL-20 | Anything that is not a confidently relocalized, normally tracking frame is `lost`; fire stays locked |
| Pose exchange cadence (research band 20–30 Hz) and pose-history capacity | KIL-19 | 100 ms maximum pose age (§5.4) governs regardless of cadence; a cadence that cannot satisfy it fails the gate |
| Match-clock tick duration (core baseline 50 ms) and clock-offset estimation quality | KIL-19 | Verdict bounds are absolute integer milliseconds, never tick counts; an unestimable offset rejects the claim |
| Host verdict latency, Convex authoritative p50/p95/p99, and end-to-end reconciliation delay | KIL-21 | Provisional feedback may never change health, ammunition, or score; only authoritative state does |
| Whether authority stays on the host phone or moves to a server process, and the transport | KIL-21 → ADR 0004 | Host-provisional plus Convex-authoritative (§6) is the Phase 1 behavior |
| Proxy shape refinement (capsule or oriented box) and body-volume upgrade | Phase 2 | 0.35 m sphere (§5.1) |
| Making a shot claim's target optional in the wire contract and in `shared/simulation`, so a target-agnostic ray can resolve as an authoritative miss (§5.0) | KIL-19 (core and contract), KIL-22 (client and spectator surfaces) | KIL-18 freezes the meaning only. Until the contract carries it, a no-candidate shot must still be recorded as a fired shot that consumed ammunition and resolved as `miss`; no path may swallow the input |
| Remote tracer transport, dedup keying, and the transient tracer's on-screen duration (§6.4) | KIL-21 (transport and latency), KIL-22 (presentation) | One tracer per shot identity per member, dropped rather than duplicated when identity is unknown or already seen |

## 3A. Trigger authority (product-owner correction, accepted)

This section overrides any earlier reading of this packet in which acquiring a target was a precondition for firing.

### 3A.1 A lock is not permission to fire

- **Fire gates** are: the match is live and accepting input for this member, the shooter is alive, the shooter's phone has normal Tracking Quality and is aligned to the Shared Arena Frame, the venue geofence permits play, ammunition remains, and the cooldown has elapsed.
- While every fire gate is open, a trigger press **always** produces exactly one shot, sourced from the shooter's current normalized camera ray in the frame of the press. Nothing about a target may suppress that input.
- Detecting a Phone Target Proxy — or a Vision zone on the legacy path — is **advisory targeting feedback**. It may sharpen the crosshair, name a candidate, and improve confirmation copy. It is never a gate.
- A shot fired with no candidate, or at empty space, resolves as an authoritative `miss`. It consumes ammunition, appears in the shot ledger, and is reconciled like any other shot. It is not a rejection and not a no-op.
- No surface may show `ACQUIRE TARGET`, `NO TARGET — FIRE LOCKED`, or any wording implying a lock is required. Fire is locked only by the fire gates above, and the reason shown is the gate that is closed.
- This is the technical specification's existing rule — a trigger pulled without a valid zone is a miss — carried unchanged into the shared-3D path. This packet does not weaken it.

### 3A.2 What this changes about the lane

The 3–15 m lane (§5.2) is a property of a **candidate target**, not of the trigger. A member closer than 3 m or further than 15 m is simply not hittable, so a ray that only meets such a member resolves as `miss`. The 3 m minimum remains a safety message (§10) and an advisory HUD warning; it never disables the trigger. `MOVE APART — 3 M MINIMUM` is shown as safety guidance and as the reason on a legacy target-named claim, never as a trigger lock.

## 4. Deterministic spatial semantics (frozen)

### 4.1 Shared Arena Frame

- One arena frame per match. It is **right-handed, metre-scaled, and gravity-aligned**: `+Y` is up along gravity, and the horizontal axes are fixed at arena definition and never re-derived mid-match.
- The frame's origin and horizontal orientation are defined once by the member holding `authorityHost` (§6) and are constant for the life of the match. Re-establishing the frame is a new calibration, not a silent re-origin.
- Latitude, longitude, and heading are never used for metre-scale hit registration. Core Location remains venue geofencing and spectator context only.
- The frame is not a claim about the physical world beyond the calibrated area; it carries no absolute geographic pose.

### 4.2 `arenaFromPhone`

- Every Phone Pose Sample carries one 4×4 transform named `arenaFromPhone`: it maps a point expressed in that phone's camera coordinates into the Shared Arena Frame. The name is read right-to-left and is the only accepted direction; an implementation that stores the inverse must name it `phoneFromArena`.
- Column-major storage, as ARKit's `simd_float4x4` supplies it. The translation column is the phone origin in arena metres.
- The phone origin used by every rule in this packet is the translation component of `arenaFromPhone` — the camera transform origin, not a rendered offset and not an estimated body centre.
- Homogeneous semantics are explicit and never inferred: a **point** is `(x, y, z, 1)` and is transformed with translation; a **direction** is `(x, y, z, 0)` and is transformed without translation. A direction is normalized to unit length before use.
- Transforms are never composed with a scale factor. Arena distances are metres; no unit conversion exists in the spatial path.

### 4.3 Fail-closed transform and geometry validation

Validation happens at the spatial ingress boundary — the point where a device-supplied pose or claim enters the shared spatial path — **before** any verdict logic sees it. A sample or claim is rejected, never repaired, when:

- any component of a transform, position, origin, or direction is not finite (NaN or infinite);
- the rotation part of `arenaFromPhone` is not invertible, is not orthonormal within the implementation's stated tolerance, or has non-unit scale;
- a shot direction has zero length or cannot be normalized;
- the pose sequence or timestamp does not strictly increase for that player;
- the timestamp is not a finite integer millisecond on the synchronized match clock, or is dated further in the future than the clock-offset estimate can justify;
- the required pose history is missing, or the sample's Tracking Quality is anything other than normal.

A rejected sample is discarded and never interpolated across, never held, and never reused after tracking recovers. A rejected claim produces a Spatial Verdict of `rejected` and can never produce damage.

**Recommendation R1 (needs acceptance):** degenerate geometry is surfaced as `trackingLost` (`TRACKING LOST — FIRE LOCKED`), reusing an existing rejection reason. The alternative — a distinct `invalidGeometry` reason — would add a `spatial-hit.v1` enum case and force coordinated decoder merges for a condition players cannot act on differently. Recommend R1 as written for Phase 1. Note the consequence this requirement removes: if a non-finite or zero-length ray ever reached the verdict core unvalidated, the core would report an ordinary `MISS CONFIRMED`, which is a silent wrong answer. Ingress validation is what makes that unreachable.

## 5. Frozen limits, fully defined

### 5.0 What one shot is

- One trigger press creates one **Frame-Aligned Shot Claim**: a shot identity, the shooter, the origin and normalized direction taken from one captured view of the arena, and the fire instant. A target is **not** required for the claim to be valid.
- The authority resolves the claim by testing the ray (§5.1) against every **hittable candidate**: a member of the match other than the shooter, alive, with a resolvable pose (§5.4) inside the 3–15 m lane (§5.2) and normal Tracking Quality.
- If one or more candidates are intersected, the candidate with the smallest forward intersection distance along the ray is the hit, and only that candidate takes damage.
- If no candidate is intersected — including when there is no candidate at all — the Spatial Verdict is `miss`. A missing candidate set is never a rejection.
- **Recommendation R7 (needs acceptance):** the merged core's `ShotClaim.targetID` is currently required, and its no-candidate outcomes are rejections rather than misses. KIL-18 freezes the meaning above; making `targetID` optional and returning `miss` is KIL-19 contract and core work, with the client and spectator surfaces in KIL-22. Until then a claim that does name a target keeps every §5.6 rejection reason exactly as written, and no client may treat a rejection as permission to suppress the trigger.

Each limit below is a complete predicate. Bounds are inclusive as written, all arithmetic is on the synchronized match clock in integer milliseconds and in arena metres, and every comparison is evaluated in the fixed order given in §5.6.

### 5.1 Phone Target Proxy — 0.35 m radius

- Shape: sphere. Centre: the target's phone origin (§4.2) at the rewound instant. Radius: exactly **0.35 m**.
- The radius is identical for every player, every device model, and every distance in the lane. It does not scale with range, screen size, tracking confidence, or difficulty.
- Hit test: a **forward** ray only. With unit direction `d` from origin `o`, and `v = centre − o`, the shot hits when `v · d ≥ 0` **and** `|v|² − (v · d)² ≤ 0.35²`. A tangential shot (closest approach exactly 0.35 m) is a hit.
- A shot whose origin is inside the proxy is unreachable, because the 3 m separation rule (§5.2) rejects first.
- Meaning: the proxy is a deliberate game objective attached to a phone. It is not a claim about the player's body, anatomy, or body zones, and it is never drawn as a body outline.

### 5.2 Play lane — 3 m minimum, 15 m maximum

- Lane distance is the **Euclidean straight-line distance in the Shared Arena Frame**, in three dimensions including the vertical component, between the shot origin and the rewound centre of the target proxy. It is not a horizontal ground distance, not a geographic distance, and not a screen-space measure.
- Valid iff `3.0 m ≤ distance ≤ 15.0 m`. Below 3.0 m the verdict is `rejected(targetTooClose)`; above 15.0 m it is `rejected(targetOutOfRange)`.
- The rule is **pairwise** between the shooter and the one named target. Another member being closer than 3 m does not block a valid shot at a legal target, and does not make that closer member targetable.
- The HUD may show the shooter's live separation from a candidate and warn when it is outside the lane, but it never disables the trigger for it (§3A). The authoritative check uses the rewound distance above.

  **Recommendation R2 (needs acceptance):** no guard band is added around the lane bounds. A shot taken at a live 3.02 m that rewinds to 2.98 m is therefore authoritatively rejected with `MOVE APART — 3 M MINIMUM` after the shooter saw a valid trigger. This is accepted as visible fail-closed behavior rather than hidden clamping. Recommend keeping it; a guard band would be a product decision with its own copy.

### 5.3 Rewind window — 250 ms

- `rewind = evaluationInstant − claimedFireInstant`, where `evaluationInstant` is the match-clock instant at which the authority evaluates the claim and `claimedFireInstant` is the claim's fire time after clock-offset estimation.
- Valid iff `0 ms ≤ rewind ≤ 250 ms`. A negative rewind (a claim dated in the authority's future) and a rewind above 250 ms are both `rejected(shotTooLate)`.
- The window is never extended, never clamped, and never averaged. A late claim is rejected, not evaluated at the boundary.
- 250 ms is this repository's own frozen prototype cap, chosen so the shooter is judged against what the shooter saw while bounding how far a target can be hit after moving away. It is not a claim about any shipped commercial title.
- Consequence accepted by product: within 250 ms a target can be hit after visibly moving away, because the historical proxy still intersects the ray. This is attacker-favouring by design and is disclosed to players in the spectator label (§8).

### 5.4 Maximum pose age — 100 ms

Resolution of the target's rewound position at `claimedFireInstant` against that player's pose history:

- **No sample at or before the instant** → `rejected(poseTooOld)`. Missing history is never treated as a miss.
- **Exact sample at the instant** → that sample's position is used.
- **Two samples bracketing the instant** → linear interpolation between them, permitted only when `claimedFireInstant − earlier.timestamp ≤ 100 ms` **and** `later.timestamp − earlier.timestamp ≤ 100 ms`. A bracket wider than 100 ms is `rejected(poseTooOld)`; a wide gap is never interpolated across.
- **Only an earlier sample (trailing edge)** → that position is held, permitted only when `claimedFireInstant − sample.timestamp ≤ 100 ms`. Position is never extrapolated by velocity.
- Any sample used in the resolution whose Tracking Quality is not normal → `rejected(trackingLost)`.
- Additionally, both the shooter's and the target's most recent samples must have normal Tracking Quality at evaluation time, or the claim is `rejected(trackingLost)`.

### 5.5 Tracking gate and degraded behavior

- Firing requires the shooter's phone and the named target's phone both aligned to the Shared Arena Frame with normal Tracking Quality. There is no partial-confidence fire.
- On tracking loss, spatial input locks immediately on the affected phone only; the other members keep playing. Stale transforms are never reused, and last-trusted positions may only be shown dimmed and explicitly labelled as stale diagnostics.
- Recovery requires a fresh shared lock. Old predicted shots are not replayed, and no pending claim is resolved from pre-loss history.

### 5.6 Fixed evaluation order

Two groups of checks, in this order. **Shooter-side** checks concern the claim itself and reject it; **candidate-side** checks concern one possible target and, when they fail, remove that candidate from the set rather than rejecting the shot.

Shooter-side, first failure wins:

1. claim geometry and ingress validation (§4.3) (`trackingLost`)
2. shooter alive (`shooterNotAlive`)
3. rewind window (`shotTooLate`)
4. shooter's latest-sample Tracking Quality (`trackingLost`)

Candidate-side, applied per candidate to build the hittable set (§5.0): membership and not-self, candidate alive, candidate's Tracking Quality normal, pose resolvable within 100 ms, separation ≥ 3 m, separation ≤ 15 m. Surviving candidates are tested against the ray; the nearest forward intersection is the `hit`, otherwise the verdict is `miss`.

When a claim does name a single target — the legacy contract shape and every current `shared/simulation` fixture — the candidate-side failures are reported to the shooter as one reason, in this order: `invalidTarget`, `targetNotAlive`, `trackingLost`, `poseTooOld`, `targetTooClose`, `targetOutOfRange`. A claim that violates several rules always reports the first one in that order. Both readings must agree on every named-target fixture; that equivalence is a Gate B expectation.

Exactly one Spatial Verdict is produced per logical shot. A replayed claim with the same client shot id yields the same verdict and applies damage once.

## 6. Authority, trust, and the provisional-to-authoritative transition

### 6.1 One host role, three jobs

The single member holding the `match.v2` `authorityHost` capability is simultaneously:

1. the Convex match host — the creating player, who receives all capabilities;
2. the AR mapping host — the phone that defines the Shared Arena Frame and serves the world map that guests relocalize into;
3. the provisional spatial authority — the phone that computes the provisional Spatial Verdict.

These are deliberately the same member for Phase 1. There is no separate "spatial host" concept, no host election, and no capability transfer: per `match.v2`, Phase 1 does not transfer capabilities, and `authorityHost` reassignment is an L1 concern deferred to ADR 0004. The words "host" and "guest" do not appear in any player-visible copy; capability decides affordances.

### 6.2 The transition

| Stage | Producer | What it may change | What it may never change |
|---|---|---|---|
| Predicted | The shooter's own phone, same frame as the trigger | Local ray, crosshair, `SHOT PREDICTED` panel, muzzle feedback, trigger disabled while pending | Health, ammunition, score, kill feed, or any announcement of a hit |
| Provisional Spatial Verdict | `authorityHost` phone, using §5 semantics | Local presentation on the host and, once delivered, the shooter's pending panel | Authoritative match state; it is evidence submitted to Convex, never a damage instruction |
| Authoritative Spatial Verdict | Convex | Health, ammunition, kills, deaths, damage, event feed, spectator projection — as one reconciled state change | Nothing may bypass it; no client applies damage |

- Damage is committed exactly once, by Convex, keyed by the client shot id.
- A provisional verdict that the authoritative verdict contradicts must **visibly** correct the shooter's local prediction: the predicted panel is replaced by the authoritative result, never stacked beside it, and never silently dropped.
- A predicted shot is never presented to the target or the spectator as damage.
- If the authoritative verdict does not arrive, the shot stays visibly pending and then resolves as the authority's recorded outcome on reconnect. A pending shot never expires into a local hit.

### 6.4 Shot presentation for every member

- Shot presentation is not private to the shooter. Every other member of the match receives one transient tracer for each remote shot, drawn from that shot's shared-arena origin and normalized direction, so incoming fire is visible whether it hits, misses them, or misses everyone.
- Presentation is keyed by **shot identity**: exactly one tracer per shot identity per member. Reconciliation, resubscription, and reconnect replay must not draw a second tracer, and a shot identity already presented is ignored. A shot whose identity is unknown is dropped rather than drawn twice.
- The tracer is transient presentation of an instantaneous ray. It carries no velocity, no travel-time gameplay, and no collision; the verdict never depends on it.
- Confirmation reconciles the outcome — hit, miss, or rejection — **without** replaying the tracer. A late authoritative result updates labels, health, and the event feed only.
- The spectator follows the same rule: one tracer per shot identity, with `REWIND 0–250 MS` where a historical position is shown.

### 6.3 Accepted trust limitation

The `authorityHost` phone is trusted to compute the provisional verdict honestly for Phase 1. Convex validates identity, capability, membership, the targetable set, sequence, cooldown, ammunition, the §5 bounds, and idempotency — but it does not independently reproduce the host's geometry in Phase 1. A compromised host could therefore submit a favourable provisional verdict within otherwise valid bounds. This is accepted explicitly and disclosed: **no production anti-cheat claim is made**. The two candidate hardenings — Convex recomputing the intersection from uploaded history, and requiring compatible shooter and target attestations — are recorded in [the research](../../research/shared-ar-hit-registration.md) and belong to ADR 0004 or later, not this packet.

## 7. Player-observable flow (2–4 players)

1. **Entry:** 2–4 members reach the spatial setup step from a `match.v2` lobby. Nothing in the flow assumes exactly two.
2. **Calibration:** the `authorityHost` member defines the arena; every other member relocalizes into it. All phones show alignment progress and a clear stop state when tracking is inadequate. Calibration completes only when every member in the set is aligned.
3. **Ready:** each phone shows `FIRE` while its fire gates are open, its tracking state, ammunition, the advisory candidate readout (a callsign and distance when a proxy is detected, nothing when none is), and the 3 m separation safety guidance. The absence of a candidate never changes `FIRE` into a lock-required message.
4. **Firing:** a trigger press captures one Frame-Aligned Shot Claim — origin, direction, and time from one captured view of the arena — whether or not a candidate is detected. Firing is unavailable only when a fire gate is closed (§3A.1), and the closed gate is named.
5. **Predicted:** the shooter gets an immediate predicted tracer labelled `SHOT PREDICTED`, naming the candidate when there is one. Health, ammunition-as-authoritative, and score do not change. Every other member receives one transient incoming-shot tracer for the same shot identity (§6.4).
6. **Confirmed hit:** every member receives one `HIT CONFIRMED` state from authoritative match data, attributed to the shooter and the target. Damage, ammunition, health, and the event feed reconcile as one state change. Uninvolved members change no health.
7. **Confirmed miss:** the shooter receives `MISS CONFIRMED`. No damage is applied anywhere. A deliberate off-target shot reaches exactly this state — ammunition and the shot ledger record it — and so does a shot fired with no candidate in view.
8. **Rejected:** the shooter sees exactly one fixed reason from §9 and the corrective action. A rejected shot never produces damage.
9. **Degraded:** spatial input locks on the affected phone only. Last trusted positions remain visible only as dimmed, explicitly stale diagnostics. Other members continue.
10. **Recovery:** the affected phone re-establishes a fresh shared lock and shows `SPATIAL LOCK RESTORED`. Old shot animations are not replayed.

## 8. Role-specific feedback

### Shooter

- The crosshair is live whenever the fire gates are open, with or without a candidate. A detected candidate's proxy ring is neutral cyan and carries a callsign and distance; this is advisory only.
- Trigger press produces one short amber tracer and `SHOT PREDICTED`, naming the candidate when there is one. Cooldown, not target state, governs the next press.
- A confirmed hit turns the terminal point and result label green; a confirmed miss fades the ray to muted grey; a rejection turns the result panel red and names the corrective action.
- Colour never carries the outcome alone; every state carries text.

### Target

- The proxy is never drawn as a body outline on any surface.
- A confirmed hit produces one haptic and one accessible announcement, attributed to the shooter.
- Every member sees one transient incoming-shot tracer per remote shot, drawn from the shared-arena origin and direction, including for shots that miss them or miss everyone (§6.4).
- A predicted remote shot changes no health and announces no hit.
- Tracking loss locks that player's combat rather than leaving an invisible vulnerable target.

### Spectator

- Shows the current trusted proxies for every member, the shot ray, and the confirmed terminal result.
- Labels historical evaluation as `REWIND 0–250 MS` rather than presenting a rewound position as current.
- Never exposes precise historical coordinates, device identifiers, or reusable location history in a public payload.
- Never presents a predicted shot as authoritative damage.

## 9. Canonical labels

These are the only accepted labels for these conditions. The machine key is the stable identifier used by implementations and fixtures; the rejection keys are exactly the `spatial-hit.v1` rejection-reason values already implemented in `shared/simulation`. HUD copy is upper case as shown; VoiceOver copy is sentence case and is spoken once per state entry.

### 9.1 States

| Machine key | HUD copy | VoiceOver |
|---|---|---|
| `calibrating` | `ALIGNING SHARED ARENA…` | `Aligning shared arena.` |
| `ready` | `FIRE` | `Ready to fire.` or, with a candidate, `Ready to fire. {callsign}, {distance} metres.` |
| `predicted` | `SHOT PREDICTED` | `Shot predicted. Awaiting authoritative verdict.` |
| `hitConfirmed` | `HIT CONFIRMED` | `Hit confirmed on {callsign}. Damage {damage}.` |
| `missConfirmed` | `MISS CONFIRMED` | `Miss confirmed.` |
| `rejected` | the §9.2 label for the reason | the §9.2 VoiceOver line for the reason |
| `degraded` | `TRACKING LOST — FIRE LOCKED` | `Tracking lost. Fire locked.` |
| `recovered` | `SPATIAL LOCK RESTORED` | `Spatial lock restored.` |

### 9.2 Rejection reasons

| Machine key | HUD copy | VoiceOver | Corrective action shown |
|---|---|---|---|
| `trackingLost` | `TRACKING LOST — FIRE LOCKED` | `Tracking lost. Fire locked.` | Re-align to the shared arena |
| `targetTooClose` | `MOVE APART — 3 M MINIMUM` | `Target too close. Move apart, three metre minimum.` | Increase separation |
| `targetOutOfRange` | `TARGET OUT OF RANGE — 15 M MAXIMUM` | `Target out of range. Fifteen metre maximum.` | Close distance |
| `poseTooOld` | `TARGET POSITION TOO OLD` | `Target position too old.` | Wait for a fresh lock |
| `shotTooLate` | `SHOT ARRIVED TOO LATE` | `Shot arrived too late.` | Retry the shot |
| `invalidTarget` | `NO VALID TARGET` | `No valid target.` | Reserved for a claim naming a non-member or the shooter — never shown because no candidate was in view |
| `targetNotAlive` | `TARGET IS DOWN` | `Target is down.` | Choose another target |
| `shooterNotAlive` | `YOU ARE DOWN — FIRE LOCKED` | `You are down. Fire locked.` | Wait for respawn |

### 9.3 Spectator labels

| Machine key | Copy |
|---|---|
| `rewindDisclosure` | `REWIND 0–250 MS` |
| `provisionalPending` | `AWAITING AUTHORITATIVE VERDICT` |
| `incomingShot` | `INCOMING SHOT` |

`SPATIAL LOCK READY` is retired: it implied a lock was required to fire. `SPATIAL LOCK RESTORED` survives, because it describes tracking recovery rather than a target. No surface may add `ACQUIRE TARGET` or any equivalent.

No surface may invent a synonym, abbreviation, or sentence variant of any label above. The words "host", "guest", and "opponent" are forbidden in player-visible spatial copy; the target is named by callsign.

## 10. Safety and privacy

- Use only in a controlled, authorized area with a clear 3–15 m lane for every pairing in the set.
- Stop play near roads, stairs, obstacles, bystanders, or an untracked player. More players in one arena means more simultaneous pairings to keep clear.
- Do not use realistic gun-shaped props.
- Players look where they move; the app never encourages backward running.
- Precise transforms stay match-scoped and expire with prototype telemetry. No spatial payload carries a device identifier or a secret.
- Public spectator data contains only the minimum reconstruction data and no reusable location history.

## 11. Excluded from this slice

- Persistent Projectile Worldline identity, projectile velocity, travel-time gameplay, or swept collision. This slice is **hitscan with a visual tracer**: the tracer is presentation of an instantaneous ray and never a simulated body, and no verdict depends on how long it is drawn.
- Suppressing trigger input on any target condition, and any lock-required copy.
- Personal time, bullet time, dodge windows, and time fields.
- Body-zone collision, and any claim that the proxy represents anatomy.
- More than 4 players (ADR 0003 Phase 1 cap; beyond it requires a new accepted decision record).
- Production anti-cheat claims.
- Retirement of `shots:debugFire` or of the screen-space Vision claim path.
- Any `phase0.v1`, `g2.v1`, `match.v2`, or production-code change.

## 12. Recommendations requiring acceptance

| # | Recommendation | If rejected |
|---|---|---|
| R1 | Degenerate or non-finite geometry is rejected at ingress and reported as `trackingLost` (§4.3) | A new `invalidGeometry` rejection reason enters `spatial-hit.v1`, requiring coordinated decoder merges |
| R2 | No guard band around the 3 m and 15 m bounds; boundary rewind rejections are shown honestly (§5.2) | A guard-band width and its own copy become product decisions |
| R3 | Proxy radius is uniform for all players, devices, and distances (§5.1) | Per-distance or per-device sizing becomes a disclosed balance parameter |
| R4 | `authorityHost` is non-transferable in Phase 1, matching `match.v2` (§6.1) | Host handover semantics must be designed before implementation |
| R5 | Tangential shots (closest approach exactly 0.35 m) count as hits (§5.1) | The boundary predicate becomes strict, and the merged core changes with it |
| R7 | A shot claim's target becomes optional so a target-agnostic ray resolves as `miss` (§5.0); the wire and core change lands in KIL-19 with surfaces in KIL-22 | KIL-18's frozen meaning cannot be implemented, and a no-candidate shot keeps surfacing as a rejection |
| R8 | Ready copy is `FIRE`, and target lock is advisory feedback only (§3A.1, §9.1) | Ready copy must state a lock precondition that the accepted mechanics no longer have |
| R9 | Every member receives one deduplicated transient tracer per remote shot, including misses (§6.4) | Only the shooter sees shot presentation, and incoming fire stays invisible to targets |
| R6 | Slice 002 remains the authority for the eight spatial states; Slice 003 (KIL-40) is its unaccepted N-player successor for lobby, multi-opponent HUD, and podium, and does not gate KIL-18 or KIL-19 | Slice 003 must be accepted first, widening KIL-18's acceptance surface |
