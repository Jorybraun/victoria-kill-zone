# ADR 0010 — Quick Play: relocalized shared frame and phone-proxy verdicts

Status: **proposed**, 2026-09-13. Owner acceptance is required before the targeting, backend or client lanes in [design/slices/010-quick-play-setup.md](../../design/slices/010-quick-play-setup.md) may be implemented. Integration owns this record, the per-match geometry contract and the client flow; targeting owns the frame policy and provider; backend owns the Convex change; design owns the slice freeze. Nothing in this record is physical-device evidence.

## Context

ADR 0006 and ADR 0009 set out to **prove** that two phones agree about the arena to within 10 cm and 0.5° before a hit is trusted. The instrument for that proof — a stationary textured rectangle whose ARKit image anchor yields a residual against the shared map — was then wired in as the **gate for play**, and the match-pause rule in the simulation was tuned for the same proof posture. As built on `main` (`9d20015`) the CREATE ARENA path cannot be played through:

- `DuelFrameSnapshot.permitsSpatialFire` requires a residual no older than 100 ms at every shot (`Targeting/SharedArena/DuelFrame/DuelFrameModels.swift`). ARKit only reports the image anchor while the reference is in frame, so aiming at an opponent who is not standing beside the reference locks fire. ADR 0009 records this limitation itself.
- `MatchSimulation.coverage()` under the `trackedBody` geometry pauses the match and cancels projectiles whenever any living player lacks a fresh (≤100 ms) body-collider observation from another phone (`packages/combat-simulation/src/index.ts`). With 3–4 players glancing around, coverage gaps are the normal case, not the exception.
- Before either gate applies, the host must pass a three-sample Vision rectangle capture (≥10 % of the frame, centred, corners on one detected plane, bounded motion, ≤2 cm deviation). The only phone attempt on record (2026-09-08, build 53/54) never passed it: "No clear rectangle found" with tracking fluctuating. No phone has ever completed capture → share → relocalize → play.

These are laboratory measurement conditions promoted to a gameplay requirement. The roadmap already instructs owners not to preserve a failing flow because it exists and to adopt a shared-positioning approach that supports moving around (docs/roadmap.md, "Evaluate each existing flow…"). The ingredients for that approach already exist and are tested:

- `DuelFrameCalibrationBundle.decode` accepts a raw `ARWorldMap` archive with no reference, and `installFrameMap` installs it without `detectionImages`.
- `DuelFramePolicy` already models `relocalizingWorld → aligned` on `.relocalizing → .normal` with a 15 s timeout, and a 30 s mapping deadline.
- The combat worker, `packages/combat-protocol`, `packages/combat-simulation` and the native replica all validate and run the `phoneProxy` geometry: a 0.35 m torso-zone sphere at each player's phone pose (`packages/combat-simulation/src/history.ts`). Its coverage rule needs only fresh phone poses, which every client already submits every 50 ms. The simulation fixture proves 2–4 players run under it without coverage pauses.
- The worker accepts `frameReady` with a zero residual.

## Decision

Introduce a **relocalized alignment mode** and make it, with the **`phoneProxy`** verdict geometry, the definition of **Quick Play** (Home → CREATE ARENA). The existing measured mode (reference capture, fresh residuals, `trackedBody`) is kept unchanged as the **measurement mode** used by saved-arena matches and by the calibration study.

1. **Shared frame.** The host scans until ARKit reports `.mapped`, captures the raw world map and shares it through the existing authenticated 8 MiB map endpoint. Every phone, including the host, installs it under world tracking. Reaching `.normal` tracking from `.relocalizing` within the existing 15 s window is **aligned**. No reference capture, no residual, no body-tracking seeded relocalization in v1.
2. **Fire permission.** In relocalized mode `permitsSpatialFire` requires `aligned` plus a fresh local pose; the residual check applies only in measured mode. Clients report `frameReady` with residual 0, which the server already accepts.
3. **Verdict geometry.** Quick Play matches are created with `combatGeometry: "phoneProxy"`; saved-arena matches keep `"trackedBody"`. `combat:prepare` writes the match's geometry into `combatRulesJson` instead of always emitting `DEFAULT_RULES`. The field is additive and optional; absent means `trackedBody`, so existing clients and tickets are unaffected.
4. **Tracking dips during play.** In relocalized mode, non-normal tracking while `aligned` yields a new recoverable `degraded(trackingLimited)` state that locks fire and returns to `aligned` on the next fresh normal pose; `.relocalizing` for longer than the 15 s window yields `lost` with an explicit **Re-align** action. Measured mode keeps its current `lost` behaviour byte-for-byte.
5. **Body and Vision pose** remain in the pipeline as aim assist and as the hit-only skeleton source (existing Vision 2D pose path that already serves non-body-tracking devices). They are not a verdict input and not a pause condition in Quick Play.
6. **Debug fire** stays until Quick Play has the physical evidence below, per AGENTS.md.

## Honesty clause

- Hit fairness at range is **unmeasured** until the two-phone trial. The 0.35 m sphere at the phone is a park-game approximation of a torso, not anatomy; a phone held away from the body moves the target with it.
- World relocalization outdoors and on non-LiDAR phones may exceed 15 s; the window is a constant, the trial measures it.
- ARKit tracking `.normal` after relocalization is ARKit's own alignment claim; no independent residual verifies it. This mode trades the 10 cm / 0.5° proof for playability and says so in the UI copy frozen in the slice.
- Nothing here validates the measurement mode's target-space accuracy claims either; ADR 0009's open acceptance remains open.

## Consequences

- Four bounded PRs, one per owner, each independently revertible: targeting (`DuelFrameAlignmentMode`, policy/provider/session changes and tests), backend (`matches.combatGeometry`, `combat:prepare`, tests), client/integration (mode selection from `rules.geometry`, `RealtimeMapCoordinator.configure(mode:)`, setup states from the slice), and this record with roadmap/contract pointers. The DEBUG setup-log export (`DuelFrameDiagnostics`) lands first so the next phone run yields data rather than a screen recording.
- `docs/interface-contracts.md` gains the optional `combatGeometry` field on match creation and the rule that `combatRulesJson.geometry` follows the match; the combat protocol and worker are unchanged.
- The measurement mode is preserved for the saved-arena flow and ADR 0009's study; it is no longer on Quick Play's critical path.

## Acceptance evidence (physical only)

Two phones on the same build, mixed models, host/joiner swapped, indoors and outdoors, five runs each:

1. Host CREATE ARENA → scan → SHARE ARENA; joiner aligns. Record time-to-mapped, map bytes, transfer time and relocalization time from the exported setup log. Pass: ≥4/5 relocalize within 15 s.
2. Twenty shots in each direction (ten aimed, ten deliberate misses) at ~3 m and ~8 m: verdict versus intent, incoming tracer visible on the target phone, ammo/health/K-D agree on both HUDs and the spectator projection.
3. Kill → respawn three times; one phone backgrounds and returns; one leaves and rejoins.
4. Battery and thermal state at start and end.

Then 3–4 players. Evidence names phone model, iOS version and build number and is recorded in docs/build-log.md and the Linear ticket; simulator, Mac or fixture runs do not satisfy any row.

## Reconsider when

Reconsider if the trial shows relocalization regularly exceeding 15 s, or phone-proxy verdicts feel unfair at 8 m. Candidate follow-ups, in order: body-seeded relocalization as a second alignment source (ADR 0006's original v2), a periodic opportunistic residual from any detected image anchor used as a drift monitor rather than a gate, and a `trackedBody`-with-fallback geometry in the simulation. None of these are part of this decision.
