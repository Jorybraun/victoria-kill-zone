# Zero-step normal play: product model, terminology and spatial gating (BIO-36)

Status: Research complete — 2026-09-26. Read-only spike for [BIO-36](https://linear.app/biossphere/issue/BIO-36/spike-engineer-zero-step-ar-room-understanding-and-authoritative). Builds on — does not repeat — [ADR 0013](../decisions/0013-quick-play-sighting-hits.md) (sighting hits, no shared frame), [ADR 0011](../decisions/0011-quick-play-continuous-collaboration.md), [ADR 0010](../decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md), [shared-arena-frame-options.md](shared-arena-frame-options.md) and [live-combat-deployment.md](live-combat-deployment.md). Nothing in this document is physical-device evidence; no code, branch, deployment or ADR is changed by it.
Method: one source audit of the current iOS routes, realtime controller/policy, Convex preparation, combat protocol/simulation and deploy workflow on `main` (clean, 2026-09-26); one primary-documentation pass (Apple ARKit/Vision/HIG, Cloudflare Durable Objects/Workers); one synthesis pass producing the product model, terminology table and gating rules. Repository facts cite file paths; external claims carry numbered sources; provenance sidecar lists access dates and rejections. Paragraphs marked **Speculation** or **Proposal** are engineering judgement, not sourced fact.

## 1. The question

Can Victoria Kill Zone present ONE normal-play model in which two ready players are fighting within seconds — no scan, alignment, relocalization, map-link or shared-frame ritual — while each phone keeps mapping in the background, the match Durable Object stays authoritative, an evolving shared room model is fused opportunistically, and saved arenas remain an optional higher-fidelity mode? What must the UI say, which states are misleading today, and exactly when may gameplay start, continue, degrade, or refuse a spatially sensitive action?

## 2. Verified repository facts (the five stated premises)

| Premise | Verdict | Evidence (source inspection only) |
|---|---|---|
| iOS uses ARKit/Vision and already has local plane-detection paths | **Confirmed, with a qualification.** | `Targeting/TargetingSession.swift` runs Vision body-pose requests alongside `ARBodyTrackingConfiguration`/`ARWorldTrackingConfiguration` (gravity alignment). Plane detection `[.horizontal, .vertical]` is set only on the duel-frame configurations (collaborative/measured/saved-map) and in `Targeting/MapLab/MapLabARDriver.swift`. **Qualification:** under sighting geometry the controller never configures the duel frame (`configureMapIfNeeded` and `startRendezvousIfNeeded` both guard `!usesSighting` in `Features/Realtime/RealtimeArenaController.swift`), so the session runs the default configuration — `ARBodyTrackingConfiguration` (or world tracking where body tracking is unsupported) **with no `planeDetection` and no collaboration**. Today's normal two-player play therefore does *not* detect planes or map surfaces beyond ARKit's internal tracking map. |
| Sighting fire carries body evidence, not wall/surface evidence | **Confirmed.** | `packages/combat-protocol/src/index.ts` `BodyObservation` = target id, capture time, association confidence, uncertainty, colliders. The iOS sighting fire path attaches one observation built from the associated Vision/ARKit skeleton (`uncertaintyMeters: 0.08`); pose ticks under sighting carry `observations: []`. `packages/combat-simulation/src/flight.ts` `resolveSighting` intersects the shooter ray with those body colliders. No wall, plane, mesh or occluder field exists in the fire command or simulation. |
| Convex handles lobby/match preparation and projects match state | **Confirmed.** | `convex/functions/matches.ts` (create/join/setReady/start…), `convex/functions/combat.ts` `prepare` (host-only, ≥2 connected+ready, freezes rules, `selectCombatGeometry`, sets `combatPhase:"calibrating"`), and a signed trusted projection writer (`verifyCombatProjection`, ordered `fromEventSequence`/`throughEventSequence`). |
| A Cloudflare Durable Object runs the real-time combat simulation | **Confirmed in source; runtime not re-verified here.** | `services/combat-worker/src/routes.ts` (`/v1/matches/:matchId/connect`, `/report`, `/frames/:epoch/map`), `services/combat-worker/src/maps.ts` (SQLite `map_chunks`, `LIMITS.mapBytes` 8 MiB cap, 128 KiB chunks), simulation in `packages/combat-simulation`. ADR 0008 records the Durable-Object-per-match choice. Whether the production Worker is currently deployed was not checked (read-only). |
| Normal Deploy does not deploy the combat Worker; a guarded operator script does | **Confirmed.** | `.github/workflows/deploy.yml` contains no `wrangler`/`combat-worker` reference; `docs/research/live-combat-deployment.md` describes the guarded Worker-only bootstrap; `scripts/release/combat-deploy.mjs` implements it. |

## 3. Route and state audit (what a player experiences today)

### 3.1 Routes

`App/RootView.swift` routes `.home → .join | .waiting(WaitingRoom) → .active(ActiveDuel)`; Scan Lab and saved-arena selection are sheets from Home (`ArenaLibraryMode.scanLab | .createMatch | .manage`).

| Route | Current copy / behaviour | Assessment |
|---|---|---|
| Home (`Features/Home/HomeView.swift`) | "Bring two to four players together. Create an arena or join a friend's code." — `CREATE ARENA`, `JOIN ARENA`, `SCAN & SAVE`, optional `PLAY A SAVED ARENA`. | Normal play is called an "arena", the same noun used for the optional saved high-fidelity mode. "Two to four" invites 3–4 player rosters that silently leave the zero-step path (§3.3). |
| Lobby (`Features/Lobby/WaitingRoomView.swift`) | Ready toggle "I'm ready"; host button **"Align arena"**; guidance **"All players ready. Next, align your shared play area."** | Misleading: under sighting nothing is aligned. Button actually calls `combat:prepare` and routes to Active. |
| Active match (`Features/Realtime/RealtimeArenaView.swift`, `RealtimeArenaController.swift`, `RealtimeArenaPolicy.swift`) | Under sighting, `stage` skips all map/frame states and goes connecting → awaitingMembers ("Waiting for opponent") → host **PLAY** → running. Player cards still render "Aligning" whenever `frameReady` is false; accessibility says "aligning". | Second host action (PLAY) after the lobby action; `frameReady` is never set in sighting (no `frameReady` command is sent because the duel frame is never configured), so the card label "Aligning" is the expected display for a healthy sighting opponent before/while running — **inference from source; not observed on device**. |
| Saved arena (`Features/Arenas/SavedArenaLibrary.swift`, `ArenaSetupView.swift`) | "Set up an arena", "Saved on this phone", "SAVE ARENA", "Choose a fixed reference", "Measuring your reference"; match created with `trackedBody` and the measured-reference frame. | Correctly optional; its setup ritual is legitimate *for this mode only*. |
| Scan Lab (`Features/MapLab/MapLabLibraryView.swift`) | "Recognition on this phone only. Multiplayer alignment is tested separately." "These scans do not create or join a game." | Honest and already separated from multiplayer. Keep as a lab/diagnostic surface. |

### 3.2 Two-step start today

Normal two-player start today requires: every player taps "I'm ready" → host taps "Align arena" (`combat:prepare`) → all phones enter Active and connect → host taps "PLAY" (simulation `start` command; accepted when `coverage()` holds, which under sighting is "every player connected"). The simulation's initial phase is named `calibrating` (`packages/combat-protocol/src/index.ts` `CombatPhase`), and Convex writes `combatPhase:"calibrating"` at prepare — even though sighting performs no calibration.

### 3.3 Hidden geometry switch

The client requests `phoneProxy` for every unsaved Durable-Object match (`LobbyStore.performCreateDuel`, with a stale comment still describing "the relocalized shared frame"); Convex `selectCombatGeometry` rewrites it to `sighting` only when the frozen roster is ≤ 2, and keeps `phoneProxy` for 3–4. `phoneProxy` restores the full map/transfer/relocalize/`frameReady` ritual whose physical two-phone merge evidence is still outstanding (`docs/build-log.md`, 2026-09-22: phones stalled in "Linking play area"). So the *same* Home button produces a zero-step match or a blocking setup ritual depending on how many people joined, with no user-facing explanation.

## 4. What the platforms actually guarantee (primary sources)

- ARKit world tracking is visual-inertial odometry; after `run` the tracking state is `notAvailable`, then `limited(.initializing)`, then `normal` "after a short time" [1][2]. While `limited`, plane detection adds/updates no anchors and hit-testing returns no results [1]. Any session can drop to `limited` (e.g. `insufficientFeatures`) at any moment [1]. → The app must treat surface knowledge as *intermittently available*, never as a start precondition.
- Every world-tracking session builds an internal world map; `ARFrame.worldMappingStatus` reports whether enough has been mapped to generate a useful `ARWorldMap` [3]. Relocalizing to a saved map requires revisiting previously mapped areas and its reliability "strongly depends on the real-world environment" [1]. → Saved arenas are inherently a best-effort, place-dependent, optional mode.
- `ARBodyTrackingConfiguration` supports `planeDetection` and `initialWorldMap` [4]; Apple's topic list for it shows no scene-reconstruction property (absence in the documented topics, not a tested claim). Scene reconstruction (`sceneReconstruction`, polygon mesh) is a world-tracking feature that requires a LiDAR device [5][6]. → Plane anchors [7] are the only surface primitive available on every supported iPhone during body tracking; meshes are a LiDAR-only enhancement.
- Collaborative sessions require `ARWorldTrackingConfiguration`; enabling collaboration later "is not supported, because doing so restarts the session"; merging requires ARKit to "recognize overlap across their respective world maps", and Apple's sample asks users to hold phones side by side [8]. → Collaboration is incompatible with the body-tracking configuration sighting relies on, cannot be toggled mid-match, and depends on visual overlap. A background fusion design cannot assume ARKit collaboration.
- Apple HIG recommends coaching during initialization/relocalization, and — for placement — to "avoid waiting for more accurate data", respond instantly, then "subtly refine" when surface detection completes [9]. → HIG supports act-now-refine-later, which matches zero-step play; coaching should be a non-blocking hint, not a gate.
- Vision `VNDetectHumanBodyPoseRequest` returns `VNHumanBodyPoseObservation` joints [10] — the only target evidence sighting uses today.
- Cloudflare: each Durable Object is single-threaded with a soft limit of ~1,000 requests/s; received WebSocket messages up to 32 MiB; SQLite rows/BLOBs ≤ 2 MB; 10 GB per object; 30 s default CPU per invocation [11]. Workers isolates have 128 MB memory [12]. Hibernation resets in-memory state and re-runs the constructor; Cloudflare advises batching because many small messages "can overwhelm a single Durable Object" [13]. Alarms are at-least-once with bounded retries [14]. → Map patches must be bounded, batched, chunked into ≤ 2 MB rows, and fusion must never sit on the combat tick's critical path or rely on in-memory state surviving hibernation.

**Absences stated as absences.** No Apple source documents: cross-device plane-anchor alignment without collaboration/world-map sharing; accuracy of `ARPlaneAnchor` extents outdoors; ARKit collaboration data rates. No Cloudflare source documents CPU cost of geometric map fusion inside a Durable Object. No repository artefact records physical-device sighting gameplay, continuous-mapping bandwidth, or fused-room accuracy.

## 5. Product model (Proposal)

Three layers, one of which is visible as a *mode*:

1. **Normal play (Quick Duel) — visible, zero-step.** Two players, sighting geometry, body-evidence hits. Start = both ready + both connected to the match authority + local camera session running. No spatial knowledge is required to start, fire, hit or win.
2. **Room understanding — invisible infrastructure.** While a match runs, each phone may enable plane detection on its *existing* configuration (body tracking supports it [4]; no restart of a collaboration mode is needed) and stream a bounded trajectory plus plane-patch summaries to the Durable Object on a low-priority channel. The authority (or a sibling object — open decision) fuses opportunistically into a versioned room model with an explicit confidence. The room model may *enrich* presentation and, once confident, may *add* spatial rules (cover/occlusion); it may never *gate* start or basic fire. **Speculation:** whether two phones' independent plane sets can be registered reliably without ARKit collaboration is unproven (§4 absences); this layer ships dark (telemetry only) until measured.
3. **Saved arena (Arena Mode) — visible, optional, higher fidelity.** Chosen explicitly from Home. Keeps its measured-reference/relocalization setup, `trackedBody`/shared-frame geometry and "arena" vocabulary. Its setup ritual is acceptable *because the player opted in*; failure offers "Play Quick Duel instead", never a dead end.

Scan Lab stays a single-phone diagnostic ("Recognition test"), outside both play modes.

### 5.1 Confidence taxonomy (Proposal)

| Level | Name (internal) | Meaning | Player-visible |
|---|---|---|---|
| C0 | `bodyOnly` | No usable shared room model. Hits resolved from body evidence only. | Nothing by default (this *is* normal play). |
| C1 | `localSurfaces` | This phone has plane anchors; no cross-phone registration. | Nothing, or local-only cosmetic effects. |
| C2 | `sharedProvisional` | Authority has a registered cross-phone model below the acceptance threshold. | Nothing; may drive telemetry and cosmetic hints only. |
| C3 | `sharedConfirmed` | Registered model above threshold, fresh, for this match epoch. | Optional spatial features may unlock with a small, non-blocking indicator. |

Confidence can move down at any time (tracking `limited`, patch staleness, registration residual growth); a downgrade removes only C3-dependent features, never the match.

## 6. Gating rules (Proposal; numbers from ADR 0013 / simulation where cited)

**Start.** A two-player Quick Duel may start when: both players ready (Convex), both connected to the match Durable Object, the combat clock synchronised, the local camera session running. It must not wait for tracking `normal`, `worldMappingStatus`, plane anchors, collaboration merge, relocalization, `frameReady`, or any room-model confidence. Proposal: one host action (or auto-start after a short countdown once both are ready) instead of today's "Align arena" + "PLAY".

**Continue.** Play continues while both players remain connected (the simulation's sighting `coverage()`), regardless of room-model level or tracking quality. Loss of the opponent's connection pauses (existing `paused`/`reconnecting`); leaving finishes per existing rules.

**Degrade.** When local tracking is `limited` or no fresh pose/ray exists: disable *local* fire with a specific reason ("Hold steady — tracking" / "Too dark"), keep the match running, keep shield/reload available when they need no spatial input. When the room model drops below C3: silently revert spatial rules to C0 behaviour and hide the C3 indicator. Degradation never pauses the match for the other player.

**Refuse.** The authority refuses (as today) a sighting fire when: more than one opponent (`ambiguousTarget`); no/invalid observation, observation older than the cover window, association confidence < 0.8, uncertainty > 0.1 m, or zero colliders (`noSighting`); target id mismatch (`invalidInput`); future capture (`futureInput`) — all in `packages/combat-simulation/src/index.ts`. Any future surface-dependent action (wall-occluded hit, cover, ricochet, surface-placed slow field) must be refused unless the room model is C3 **for that region and epoch**, with a refusal reason distinct from `noSighting` so the client can explain it. Refusing a surface-dependent action must fall back to the C0 rule where one exists (e.g. treat as unoccluded) rather than refuse the shot outright — **open decision** (§8).

**Roster > 2.** Until sighting has identity disambiguation (ADR 0013), a 3–4 player match must be presented as a *different, explicit mode* (or Arena Mode), not produced silently by the Quick Duel button.

## 7. Terminology and state-transition corrections

| Current term (location) | Problem | Replace with (normal play) | Keep for |
|---|---|---|---|
| "Align arena" (lobby host button) | Nothing is aligned in sighting | "Start duel" / "Start" | Arena Mode only |
| "All players ready. Next, align your shared play area." | Promises a ritual that doesn't exist | "Both players ready." | Arena Mode only |
| "CREATE ARENA" / "JOIN ARENA" / "arena" in Home copy | Conflates normal play with saved arenas | "Quick Duel" / "Join duel" | "Arena" reserved for saved arenas |
| "Bring two to four players together" | 3–4 silently switches to `phoneProxy` ritual | "Duel a friend" (2) | Separate squad/arena mode |
| "Aligning" / "aligned" (player card, a11y) | Healthy sighting opponent shows "Aligning" (inferred) | health / "Connected" | Shared-frame geometries |
| `calibrating` phase; `combatPhase:"calibrating"` | No calibration in sighting | internal rename, e.g. `lobby`/`ready`; UI never shows it | — |
| "Scan the play area", "Arena scan ready", "Waiting for the host's scan", "Sharing the arena", "SHARE ARENA", "Find the same area", "Align the arena", "Linking play area", "Alignment lost", "Nearby Interaction…", "Finding/Point at your squad", "Turn to face each other", "Squad locked", "Set up play area" | Frame-ritual copy still reachable via `phoneProxy` and generic paths | Not shown in Quick Duel | Arena Mode / trials only |
| `phoneProxy` requested by client for Quick Play; comment about "relocalized shared frame" | Request intent contradicts ADR 0013 default | Request `sighting` explicitly | — |
| Tracking loss copy | Must describe *this phone's* camera, not the room | "Hold steady — tracking", "Too dark" | — |

## 8. Acceptance criteria (user-facing; physical-device verification required)

1. From both players tapping ready, a two-player Quick Duel reaches `running` with at most one host action and no screen asking to scan, align, relocalize, share a map, face each other or point at a spot.
2. No Quick Duel screen, player card or accessibility label contains "align", "arena scan", "share arena", "linking", "relocaliz", or "calibrat".
3. A hit can be scored in the first round with the room model at C0 (no plane anchors registered anywhere).
4. Covering one phone's camera or entering darkness disables only that phone's fire with a specific reason; the other phone continues and the match does not pause.
5. Disconnecting one phone pauses with "Waiting for opponent"/reconnecting copy and resumes without any spatial re-setup.
6. Room-model level changes (C0↔C3) never pause, restart or visibly interrupt the match; C3-only features appear/disappear with at most a small indicator.
7. A 3rd joiner cannot silently turn a Quick Duel into a setup-ritual match; the UI either blocks the join with explanation or offers an explicitly named mode.
8. Saved arenas remain selectable from Home, keep their measured setup, and failed relocalization offers "Play Quick Duel instead".
9. Background mapping stays within an agreed per-phone upload budget and never delays combat commands (measured on device and in Worker metrics).
10. Every authority refusal of a spatially sensitive action has a distinct, user-explainable reason code.

## 9. Open decisions

- One host tap vs automatic countdown start.
- Fusion location: inside the match Durable Object vs a sibling per-match "room" object (keeps combat tick isolated from fusion CPU [11][13]).
- Registration method without ARKit collaboration (plane-set matching, trajectory co-observation, gravity + body sightings) — unproven; needs measurement before any C3 rule ships.
- Upload budget and patch format (plane anchors only vs LiDAR meshes where available [5][6]).
- Whether enabling `planeDetection` on the body-tracking session affects body-tracking or Vision frame rate on the oldest supported iPhone — not documented; measure.
- C3 threshold definition and which features (occlusion, cover, surface-placed slow field) may ever depend on it; fallback-vs-refuse policy.
- 3–4 player product: separate mode, Arena Mode only, or wait for sighting identity disambiguation.
- Internal rename of `calibrating` (protocol/Convex change; versioned-protocol impact).

## 10. Risks

- Fused room model may never reach useful confidence outdoors or in featureless rooms (Apple: tracking drops with insufficient features [1]); features built on it would rarely unlock. Mitigation: C0 is the complete game.
- Body-evidence sighting has no occlusion model: shots "through walls" are possible today and will remain so at C0 (**inference** from absence of any surface field in the fire path).
- Enabling plane detection during body tracking may cost CPU/thermal headroom (unmeasured).
- Map-patch streaming on the combat WebSocket can crowd out combat messages; Cloudflare warns about many small messages [13].
- Hibernation/eviction resets in-memory fusion state [13]; persistence must be designed in.
- Renaming protocol phases touches versioned packages and Convex projections.
- Terminology changes without the roster fix would make 3–4 player matches *more* confusing (ritual appears without prior explanation).

## Sources

1. Apple — Managing Session Life Cycle and Tracking Quality (VIO; notAvailable→limited(initializing)→normal; limited disables plane detection/hit-testing; relocalization and world-map reliability) — https://developer.apple.com/documentation/arkit/managing-session-life-cycle-and-tracking-quality
2. Apple — ARCamera.TrackingState — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
3. Apple — ARFrame.worldMappingStatus (every world-tracking session builds an internal world map) — https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
4. Apple — ARBodyTrackingConfiguration (tracks body poses, planar surfaces, images; `planeDetection`, `initialWorldMap`) — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
5. Apple — ARWorldTrackingConfiguration.sceneReconstruction (polygonal mesh; plane detection smooths mesh) — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
6. Apple — supportsSceneReconstruction(_:) (requires LiDAR Scanner) — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
7. Apple — ARPlaneAnchor (extent, alignment, coarse geometry, classification) — https://developer.apple.com/documentation/arkit/arplaneanchor
8. Apple — Creating a collaborative session (world tracking only; enabling later restarts the session; merge needs map overlap; phones side by side) — https://developer.apple.com/documentation/arkit/creating-a-collaborative-session
9. Apple — Human Interface Guidelines: Augmented reality (coaching; avoid waiting for more accurate data, refine later) — https://developer.apple.com/design/human-interface-guidelines/augmented-reality
10. Apple — VNDetectHumanBodyPoseRequest — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest
11. Cloudflare — Durable Objects limits (single-threaded, ~1,000 req/s soft, 32 MiB received WS message, 2 MB row/BLOB, 10 GB/object, 30 s CPU) — https://developers.cloudflare.com/durable-objects/platform/limits/
12. Cloudflare — Workers limits (128 MB memory per isolate) — https://developers.cloudflare.com/workers/platform/limits/
13. Cloudflare — Durable Objects: Use WebSockets (hibernation resets in-memory state; batch messages) — https://developers.cloudflare.com/durable-objects/best-practices/websockets/
14. Cloudflare — Durable Objects Alarms (at-least-once, bounded retries) — https://developers.cloudflare.com/durable-objects/api/alarms/
