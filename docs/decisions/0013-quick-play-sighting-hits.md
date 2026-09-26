# ADR 0013 — Quick Play: sighting-based hits, no shared frame, no alignment gate

Status: **proposed**, 2026-09-26. Integration owns this record and the protocol change; backend owns the simulation/worker/Convex changes; iOS owns the client flow; targeting owns the body-observation seam; design owns the slice update. Nothing in this record is physical-device evidence. This record applies the accepted conclusion of the alignment-without-scanning research (ADR 0012's evidence base, `outputs/alignment-without-scanning.md`); it does not reopen that research.

## Context

Three consecutive records replaced *how* Quick Play acquires a shared coordinate frame — one-shot map share (ADR 0010), continuous collaborative mapping (ADR 0011), UWB Nearby Interaction rendezvous (ADR 0012) — and none has aligned two phones in a physical trial. The 2026-09-22 live run (arena 5Q85SK) stalled indefinitely on "Linking play area"; the build-log records no physical-device alignment success for any of the three.

The owner's direction has been consistent: there must be no sync step. Create arena → invite → ready → PLAY. Alignment, if it exists at all, is invisible.

Why every "removal" failed: the gate is not UI. The `phoneProxy` verdict (ADR 0010) resolves a shot as a ray against other phones' positions **in a shared frame**, so the authority refuses `start` unless every player is `frameReady` (`CombatSimulation.control` → `coverage()`), refuses `fire` for the same reason (`actionRefusal`), and the client hides PLAY behind the same predicate (`RealtimeActionEligibility.evaluate`). "Linking play area" is the client waiting for the frame that `phoneProxy` needs. Removing the copy leaves the refusal; swapping the acquisition mechanism (0010 → 0011 → 0012) leaves the gate.

The research sprint already established the way out. Its first finding: **"A shared world map is not required for a body-shooter. The only spatial datum combat needs is *where is the peer relative to my camera*."** It documents camera-space hit detection — shoot the person visible in your camera — as a shipped, working model (RealTag, LegitLaser, Light Wars AR, Vision Tag), with exactly one limitation: at more than two players the camera cannot tell *which* person was hit. Vision Tag "avoids the problem entirely by being 1v1 — center-of-frame person detection is unambiguous with one opponent." The sprint rejected the model *alone* for the 4-player cap and assigned Nearby Interaction the job of supplying identity.

ADR 0012 then implemented NI as a **prerequisite solve in front of PLAY** feeding the same shared-frame verdict, rather than as the identity layer the sprint described. This record corrects the order.

Two further facts make the frame redundant today:

- ADR 0011 §8 already requires a fresh Vision body observation of the victim *by the shooter* for any `phoneProxy` hit. The sighting is already the hit evidence; the shared-frame ray check is a second, frame-dependent confirmation of the same fact.
- `TargetingSession` already runs `VNDetectHumanBodyPoseRequest` on every phone and publishes skeletons, hit zones and confidence per frame. This runs on one device with no networking, merge or UWB dependency.

## Decision

Quick Play gains a **`sighting` combat geometry** in which a hit is the shooter's own camera observation of the victim, and Quick Play selects it by default.

1. **Geometry.** `CombatRules.geometry` gains `"sighting"` alongside `"trackedBody"` and `"phoneProxy"`. Convex selects `sighting` for unsaved Quick Play matches; saved arenas keep `trackedBody`; `phoneProxy` remains selectable for trials.
2. **No shared frame.** In `sighting`, no participant needs a common coordinate system. `frameReady` is not a precondition for `start`, for `coverage`, or for `fire`. There is no mapping, relocalizing, linking, rendezvous or aligned stage. A participant is ready when its camera is running with normal tracking and it is connected to the match room.
3. **Hit = sighting.** The `fire` command in `sighting` carries the shooter's current body observation (`targetPlayerId`, hit zone, association confidence, capture time). The authority accepts a hit when the observation is fresh (bounded window, ~1 s as in ADR 0011 §8), confidence meets the existing gate (≥ 0.8), the shooter's reticle collider intersects the observed body collider in the **shooter's camera space**, and the target is alive and unprotected. Damage, cooldown, ammo, reload, shield, respawn and round timing rules are unchanged. There is no ray-vs-sphere verdict and no rewind against peer phone positions.
4. **Cover is preserved by construction.** If the shooter's camera does not see the victim's body, there is no observation and no hit. This is the same rule ADR 0011 §8 chose ("if you cannot be seen, you cannot be hit"), now the only rule instead of an overlay on a wall-less frame.
5. **Player cap for `sighting`: 2 (Phase 1).** With one opponent, target identity is unambiguous — the observed body *is* the other player. A Quick Play arena with three or four players does not select `sighting` until a disambiguation rule ships (point 8).
6. **Player-facing flow.** Create arena → invite → both ready → PLAY. The realtime screen opens into the live HUD when the camera is up and the room is connected; there is no setup panel, no progress ring and no alignment copy. Camera permission and connection failures keep their existing panels.
7. **Kept, not deleted.** Collaborative mapping (ADR 0011), the NI rendezvous (ADR 0012), `DuelFrameProvider`, the map coordinator and the `VKZ_QUICKPLAY_MAP_FALLBACK` path remain behind the `phoneProxy` and `trackedBody` geometries. Nothing in this record removes code; it removes the *default* and the *gate*. Deletion is a later record with device evidence.
8. **Identity for 3–4 players (follow-up, not this record).** Per the sprint, identity comes from ranging or pose exchange, not from the camera. The named candidate is Nearby Interaction supplying **per-peer bearing** so an observed body can be attributed to the peer in that direction — NI as an identity layer at fire time, never as a PLAY gate. A cheaper interim candidate is "only one visible body → unambiguous; two or more → refuse the shot as `ambiguousTarget`." Either ships under its own record with the 3–4 player evidence list.
9. **Debug fire** stays until `sighting` has the physical-device evidence below, per AGENTS.md.

## What changes for the player

- No "Scan the area", "Linking play area", "Finding your squad" or "Point at your squad" step. PLAY is available as soon as both phones are in the room with the camera running.
- Aim at the other player; if their body is in your camera with the reticle on it, the shot lands. If they are behind a wall, it does not.
- Nothing about the HUD, health, ammo, reload, shield, slow field, respawn or match timer changes.
- Opponent shots are rendered as camera-relative tracers from the shooter's reported aim, not as projectiles positioned in a shared world.

## Consequences

Positive:
- The gate that has stalled every physical trial is removed rather than re-implemented. Setup has zero steps.
- The hit path depends on one device's camera and one WebSocket — both already exercised — instead of a cross-device map merge or UWB solve with no production precedent.
- Failures become visible and local: "no skeleton on screen" is diagnosable in seconds; a silent merge stall is not.
- The cover rule is simpler and stronger than ADR 0011 §8: it is the whole verdict, not an overlay.

Negative / risks:
- **Client-asserted hits.** The authority validates freshness, confidence, zone and reticle intersection, but the observation originates on the shooter's phone. Acceptable for Phase 1 co-located play; the ledger records the observation for audit. Server-side anti-cheat is out of scope until the game has an audience for it.
- **Vision body detection has no recorded device evidence either.** It is a first-party single-device API and its failure mode is visible, but the evidence list below is mandatory before any production claim.
- **No world-positioned opponents.** Without a shared frame the HUD cannot draw peers' positions or their bullets in world space; visual feedback for incoming fire is the existing damage/hit feedback plus camera-relative tracers. Bullet-time and dodgeable projectiles (Phase 2) still need a shared frame or peer ranging and are unaffected by this record's scope.
- **Cap of 2 for the new geometry.** This is a Phase 1 default, not a change to ADR 0003's 4-player cap; 3–4 players keep `phoneProxy` until point 8 ships.
- **Bystanders.** With one opponent, any observed body is attributed to them — the RealTag bystander bug. Mitigation in this phase is the existing association confidence gate and the co-located, consenting play context; a real fix is the identity layer in point 8.

## Alternatives considered

- **Keep tuning the collaborative merge (ADR 0011).** The merge requirement is documented Apple behavior (co-view of a mapped region); two rounds of transport fixes (#104, #111) did not change the physical outcome. Rejected as the default; retained behind `phoneProxy`.
- **Finish NI rendezvous as the gate (ADR 0012 as implemented).** Adds a permission prompt, a "point at your squad" ritual and an unproven U2 direction path in front of PLAY — a new sync step by another name, contrary to the owner's direction. Rejected as a gate; retained as the identity layer for 3–4 players (point 8), which is the role the research gave it.
- **Ungate PLAY but keep frame-gated fire.** The match starts and nobody can hit anyone until alignment completes — the same stall in a worse place. Rejected.
- **Visible marker bootstrap.** Deterministic, but forbidden by AGENTS.md and still a per-join ritual. Not considered.

## Evidence to collect (before production confidence)

Two phones, named models, iOS versions and build recorded; setup-log export on both for each run:

1. Create arena → invite → both ready → PLAY: no setup stage is shown; time from PLAY to live HUD on both phones recorded across ≥5 attempts, indoors and outdoors.
2. Shooter aims at the opponent at ~3 m and ~8 m with the reticle on the body: hit registers on both phones; health/ammo/K-D converge. Record confidence and zone per shot.
3. Shooter aims at the opponent with the reticle **off** the body, and at empty space: no hit.
4. Opponent steps fully behind a wall or doorway within the freshness window: shot refused. Same shot with line of sight: hit.
5. A third, non-playing person walks through the shooter's view: record whether a shot on them is attributed to the opponent (expected with the Phase 1 cap; quantifies the identity follow-up's urgency).
6. Five consecutive clean kill/respawn cycles without a stall, disconnect or re-alignment prompt.

## Implementation slices (for the follow-up issue; independent PRs by write boundary)

| Slice | Owner | Change |
|---|---|---|
| Protocol | Integration | `geometry: "sighting"`; `fire` carries `observation`; `ambiguousTarget`/`noSighting` refusal reasons; validator + fixtures |
| Simulation + worker | Backend | `coverage`/`start`/`actionRefusal` ignore `frameReady` under `sighting`; sighting verdict from the carried observation; tests for hit/miss/cover/freshness |
| Convex | Backend | Quick Play selects `sighting` when roster ≤ 2, else `phoneProxy`; contract tests |
| iOS client | iOS | Under `sighting`: skip `DuelFrameProvider`/map coordinator/rendezvous; ready = camera normal + connected; PLAY when all connected; `fire` attaches `associatedBody`; HUD opens directly |
| Targeting | Targeting | Association for a single opponent without phone poses (identity = the other roster member); reticle-vs-collider test in camera space |
| Design | Design | Slice 012: zero-step setup, camera/connection failure states only, tracer copy |

## References

- `outputs/alignment-without-scanning.md` (PR #105) — research synthesis; "a shared world map is not required for a body-shooter"; camera-space precedents; 1v1 identity note; NI as identity layer
- [ADR 0010](0010-quick-play-relocalized-frame-and-phone-proxy.md), [ADR 0011](0011-quick-play-continuous-collaboration.md), ADR 0012 (PR #105) — the three shared-frame acquisition records this record stops relying on for Quick Play
- `docs/build-log.md` 2026-09-22 entries — live two-phone stall on "Linking play area"
- `packages/combat-simulation/src/index.ts` — `coverage()`, `control()` `start` refusal, `actionRefusal()`; `ios/.../Features/Realtime/RealtimeArenaPolicy.swift` — client PLAY predicate
