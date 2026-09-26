# Threat model for client-generated spatial evidence in zero-step AR combat (BIO-36)

Status: Research complete — 2026-09-26.
Method: One repository audit of the current evidence path (iOS capture → combat protocol → Durable Object → Convex projection), one threat enumeration per evidence class, one survey of primary Apple and Cloudflare documentation for the validation and attestation primitives actually available, and one academic/practitioner pass on shared-state AR attacks and lag compensation. No code was edited, no build or device run was performed, and nothing in this brief is physical-device evidence. Claims are tagged **[repo]** (read from source on 2026-09-26), **[primary]** (Apple/Cloudflare documentation), **[academic]**, **[practitioner]**, or **[speculation]**. Absences are stated as absences.

## 1. The question

The BIO-36 target architecture has two phones start combat immediately, map continuously, and stream trajectories plus bounded map patches to a match-scoped Cloudflare Durable Object (DO) that is authoritative for combat and fuses a shared room model opportunistically. Every spatial input to that authority — phone trajectory, body colliders, depth, planes, meshes, map patches — originates on a phone the authority does not control. The backend has no room sensor of its own and never will in this design.

So the question is not "how does the server know the truth about the room?" It cannot. The question is: **which lies are structurally detectable, which are detectable only by cross-phone corroboration, which are undetectable, and how should the game be designed so that undetectable lies have bounded payoff?**

## 2. What the repository does today (confirmed evidence)

### 2.1 Evidence the phone actually produces

- iOS runs `ARWorldTrackingConfiguration` with `worldAlignment = .gravity` and `planeDetection = [.horizontal, .vertical]`; `isCollaborationEnabled` is set only in the collaborative mode, and a saved `ARWorldMap` is installed via `initialWorldMap` in the relocalized modes. **[repo]** [R12]
- Body evidence comes from `ARBodyTrackingConfiguration` (`ARBodyAnchor`, automatic skeleton scale estimation) where supported, with a throttled `VNDetectHumanBodyPoseRequest` fallback when no tracked body anchor is available. **[repo]** [R12][R13]
- The repository does **not** consume `sceneReconstruction`, `frameSemantics`, `sceneDepth`, `smoothedSceneDepth`, `ARMeshAnchor`, or any LiDAR product anywhere in source. No depth map, mesh, or plane evidence is serialized or sent. This is an absence, not an oversight to be assumed away. **[repo]** [R12]

### 2.2 What crosses the wire

The combat protocol has exactly one pose message and one fire message [R1]:

```ts
// pose (≈ every 50 ms when a fresh camera sample exists [R13])
{ kind: "pose", pose: PhonePose, observations: BodyObservation[] }
// fire
{ kind: "fire", shotId, poseSequence, origin: Vec3, direction: Vec3, observation?: BodyObservation | null }
// envelope
{ v, commandId, clientSequence, authorityEpoch, frameEpoch, sentAtMs, command }
```

`BodyObservation` = `{targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders[]}`; colliders are spheres or capsules with a `zone ∈ {head, torso, limbs}`. **[repo]** [R1]

The fire message carries **body** evidence only. It carries no bearing residual, no depth sample, no plane or mesh evidence, no per-joint confidence, and no wall/surface evidence. **[repo]** [R1][R13] `sentAtMs` and `capturedAtMs` are client-claimed times in the authority clock domain. **[repo]** [R1]

### 2.3 What the authority checks now

Structural validation (`packages/combat-protocol/src/validation.ts`): exact keys, finite bounded vector components, near-unit direction, confidence in `[0,1]`, uncertainty in `[0,10]`, 1–32 colliders, bounded radii. **[repo]** [R2]

Admission (`services/combat-worker/src/room.ts`): HS256 combat ticket (issuer `vkz-lobby`, audience `vkz-combat`, roster, epochs, ≤120 s life) [R10][R11]; message-size cap; token buckets (60 commands/s at command level plus per-connection aggregate, ping, NI-token and collaboration-data budgets); `(playerId, commandId)` and `(playerId, clientSequence)` idempotency with a canonical-JSON fingerprint — identical replay returns the stored result, a conflicting reuse is rejected as `idempotencyConflict`; epoch mismatch → reject + fresh snapshot. **[repo]** [R6][R7]

Simulation (`packages/combat-simulation`): future timestamps and timestamps older than the rewind window rejected; phone movement ≤ 15 m/s (+0.1 m slack) and ≤ 8π rad/s; capsule length ≤ 3 m; per-collider speed ≤ 15 m/s and radius drift ≤ 0.05 m between samples; fire ray must reference a stored fresh `normal`-tracking pose, sit within 0.5 m of that pose and within ≈15° of phone forward. **[repo]** [R3][R4]

In the **shared-frame** geometry, body observations arrive on pose messages, build a body history, and each *new* collider must sit within `BODY_ANCHOR_METERS = 2` of the target's own authenticated phone pose (`anchoredToPhone`) or the sample is refused as `poseMismatch`. **[repo]** [R3][R4]

In the **sighting** geometry (ADR 0013, the mode BIO-36 starts from), pose-message observations are *ignored entirely* ("no body history, anchor or cover bookkeeping"), and the fire-time observation is gated only by: exactly one opponent, `targetPlayerId` equals that opponent, `capturedAtMs` ≤ 1 s old (`COVER_OBSERVATION_MS`), `associationConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`, ≥ 1 collider. `resolveSighting` then intersects the shooter's own ray against the shooter's own colliders in the shooter's own camera space and awards the hit. **[repo]** [R3][R5]

Consequence, stated plainly: **in sighting mode the shooter is the sole witness to the hit.** The target's pose stream, the room, and the second phone play no part in the verdict beyond "connected, alive, not protected, not shielded". The simulation's own comment says these limits "reject teleports; they do not authenticate camera truth" [R4], and ADR 0013 accepted client-asserted hits as adequate for Phase 1 co-located play with server anti-cheat out of scope. **[repo]** [R15]

### 2.4 Maps, reports, deployment

- Saved frame bundles are ≤ 8 MiB, identified by SHA-256 of the whole bundle, host-only upload, immutable once stored, conflicting re-upload rejected; legacy raw `ARWorldMap` archives without a reference cannot authorize measured spatial input. **[repo]** [R8]
- The DO persists command fingerprints, ordered events, shared maps and map chunks in its SQLite storage. **[repo]** [R7]
- The report path is authenticated, payload-capped, quota-limited, hash-deduplicated and files a GitHub issue. It does not capture spatial evidence. **[repo]** [R9]
- Convex prepares matches (host, DO mode, 2–4 ready players seen within 15 s), mints tickets at most once per second per player, and accepts only HMAC-authenticated ordered projections from the worker; the projection contains no camera, map, or body data. **[repo]** [R11]
- No App Attest, DeviceCheck, or other attestation code exists in the repository. **[repo]** (absence)
- `.github/workflows/deploy.yml` deploys Convex and the spectator but **not** `services/combat-worker`; the worker ships only through `scripts/release/combat-deploy.mjs`, which demands `--deploy`, a 40-char SHA equal to current `main`, green CI evidence, a clean checkout, an explicit `VKZ_CONVEX_CONFIGURATION_CONFIRMED=true`, a `workers:write` Cloudflare identity, and a post-deploy health check. **[repo]** [R14]

All five "facts to verify" in the BIO-36 assignment are confirmed by the source above.

## 3. Adversary and asset model

Adversary capabilities assumed (all achievable on a jailbroken phone or with a reimplemented client holding a valid ticket; none require breaking Apple's platform):

- **A1 Client rewrite.** Arbitrary well-formed protocol messages at line rate.
- **A2 Sensor-stream substitution.** Feed ARKit/Vision outputs from a recording or synthesizer so the *legitimate* app emits false evidence.
- **A3 Network replay/delay.** Capture, hold, and re-send own traffic.
- **A4 Colluding second phone.** In competitive play, a friend's phone or a second account.
- **A5 Physical cheating.** Moving the phone in ways the game did not intend (holding it around a corner, filming a printed photo, etc.). Out of scope for the server except where it leaves a geometric signature.

Assets, in priority order: (1) combat verdict integrity (hits, cover, kills); (2) integrity of the *shared* room model, because a poisoned wall or missing wall changes verdicts for both players; (3) opponent privacy (where they are, what their room looks like, their body); (4) service availability of a match DO; (5) audit/dispute evidence.

The USENIX Security 2024 study of multi-user AR shared state frames exactly assets (2)–(3): attackers perform **false writes** that poison shared state (spurious or displaced content, deleted geometry) and **false reads** that exfiltrate or reposition another user's content, and it shows that non-colocated attackers can do this because the shared-state service cannot check physical presence. **[academic]** [E17] That is this architecture with the words changed.

## 4. Threat matrix by evidence class

Each row: what can be forged, what the DO can prove without room sensors, what needs a second phone, and what is unprovable.

### 4.1 Trajectory (phone pose stream)

| Threat | Structural check (DO alone) | Cross-phone | Unprovable |
|---|---|---|---|
| Teleport / superhuman motion | Already: 15 m/s, 8π rad/s, monotone `sequence`/`capturedAtMs` [R4]. Human sprint record ≈ 12.4 m/s [E20, tertiary], so 15 m/s is generous but sane. Add: jerk/acceleration bound, gravity consistency (`worldAlignment = .gravity` means the phone's up-vector should stay near world up on average) [R12][E12]. | Relative distance between phones must be consistent with both trajectories once an alignment estimate exists (§5). | Slow, smooth, plausible lies (walking a path you did not walk). |
| Clock skew games | Already: future rejected, older-than-rewind rejected [R3]. Add: per-connection clock-offset estimator on `sentAtMs` vs DO receive time; reject drift jumps. | — | Sub-window backdating within the rewind window is the classic lag-compensation exploit; it is bounded, not eliminated [E19, practitioner]. |
| Tracking-state lies | Ray requires stored pose with `tracking === "normal"` [R3]. `ARCamera.TrackingState` values are `.notAvailable / .limited(reason) / .normal` [E12] — the client can just claim `normal`. | Peer sees the shooter's phone drift vs where the shooter says it is. | Whether ARKit really said `normal`. |

### 4.2 Body colliders (the hit evidence)

| Threat | Structural | Cross-phone | Unprovable |
|---|---|---|---|
| **Fake body evidence** (colliders placed on the ray) | In sighting mode: **nothing today** beyond count/radius/confidence gates [R3][R5]. Feasible additions: (a) require the colliders to be *consistent with a human*: bone-length ratios, head above torso in gravity frame, capsule lengths within anthropometric bands (speculation on exact bands; [E13] shows `estimatedScaleFactor` exists so body scale is a known quantity on-device); (b) require *continuity*: apply `bodyMovementValid` across consecutive fire observations even in sighting mode [R4]; (c) require that the collider centroid distance along the ray is consistent with `uncertaintyMeters` and the camera FOV. | **The single highest-value check available**: the target's own authenticated phone pose, transformed into the shooter frame via the running alignment (§5), must lie within `BODY_ANCHOR_METERS` of the claimed colliders — i.e. extend today's `anchoredToPhone` [R4] from shared-frame mode to sighting mode as soon as a coarse alignment exists. A shooter cannot fabricate a body where the victim's phone is not. | Whether the colliders came from a camera or a synthesizer. With no depth or image on the wire there is no signal to inspect. |
| **Confidence inflation** (`associationConfidence`, `uncertaintyMeters`) | These are client-declared scalars; the `≥0.8 / ≤0.1 m` gates [R3] therefore filter honest noise, not adversaries. Apple documents Vision point `confidence` as a per-point accuracy score [E9], but only the client sees it; the DO cannot verify an aggregate. Treat as *self-reported quality*, useful for honest-client fallback policy, worthless for trust. | Corroborated confidence: raise trust only when the victim's pose stream and the shooter's colliders agree; a high confidence that disagrees with the victim's pose should *lower* the shooter's reputation, not raise the hit. | Actual model output. |
| Attribution to the wrong player | Sighting mode requires exactly one opponent [R3], so attribution is trivially correct today. At 3–4 players (Phase 1 cap [AGENTS.md]) attribution becomes forgeable. | Attribute by nearest authenticated phone pose, never by client `targetPlayerId` alone. | — |

### 4.3 Depth, planes, meshes, map patches (the *future* room evidence)

None of this is on the wire today [R1][R12]. Threats are therefore prospective, and the design constraints below should be adopted before the first byte is sent.

Platform facts that bound what can even be claimed: `sceneDepth` is nil unless the `sceneDepth` frame semantic is requested and is LiDAR-derived with a confidence map [E5]; scene reconstruction requires a LiDAR device (`supportsSceneReconstruction`) [E6]; `ARMeshAnchor` geometry is refined over time and *not intended to reflect real-time changes* [E7]; plane anchors carry classifications `wall/floor/ceiling/table/seat/door/window/none(status)` [E8]; `ARSession.CollaborationData` is an opaque blob for peers running the same session configuration [E11]; `ARWorldMap` is `NSSecureCoding`-serializable and only usable as `initialWorldMap` [E10]. Depth and mesh will therefore be **device-class dependent** — a two-player match can have one LiDAR phone and one without, and the fusion layer must not privilege the LiDAR phone as "truth".

| Threat | Structural | Cross-phone | Unprovable |
|---|---|---|---|
| **Wall omission** (cheater deletes the wall in front of them so cover does not apply to their shots, or so the opponent's cover is ignored) | Cannot be detected from one stream: absence of evidence is indistinguishable from "camera never looked there". Design rule: **a patch may only add or refine geometry it observed; it may never carry deletions, and the fused model must never be *less* occluding than the union of both phones' observations.** Track per-cell "observed by whom" so unobserved cells default to *unknown*, never *free*. | If phone B has seen a wall at X, phone A's patch claiming free space at X is a **conflict**, and conflicts resolve toward *occluded* for the party that benefits from *free*. Symmetric, so honest players are never penalized relative to the pre-fusion baseline. | A wall neither phone has looked at. |
| **Wall insertion** (fake cover to hide behind) | Planes should be bounded (extent caps), classified, gravity-consistent (walls vertical, floors at the phone's floor height), and *inside the phone's frustum history* — a patch describing geometry the phone's trajectory never pointed at is rejected. | Phone B looking through where A claims a wall exists is a conflict; resolve toward the party who *loses* by the wall existing, i.e. toward *free* when the inserter benefits from occlusion. Together with the omission rule this gives: **conflicts always resolve against the claimant who benefits.** | Fake geometry in a region only the cheater has seen. Bound the payoff: cover only ever *reduces* damage or blocks a hit; it must never *generate* a hit or score. |
| **Impossible geometry** | Reject non-manifold or self-intersecting mesh chunks, planes with impossible normals for their class [E8], depth values outside device range, patches whose size exceeds a hard byte cap (the existing 8 MiB map cap [R8] and 1 MiB unconfirmed-collab budget [R6] are precedents) and whose vertex/plane counts exceed a per-second budget. | Scale consistency: a room that is 3 m wide for A and 6 m wide for B is a fusion failure, not a fact. | — |
| **Stale or replayed patches** | Every patch carries `poseSequence` of the pose it was captured under plus `capturedAtMs`; the DO already rejects out-of-window timestamps and idempotency conflicts [R3][R6]. Add: patch hash chain per phone (`prevPatchHash`) so an old patch cannot be re-inserted later, and expire patch influence with age so a room mapped once and then reused as a recording decays. | If B's live view contradicts A's stale patch, B wins by recency. | A replay of the *same room, same layout, an hour later* is indistinguishable from honest play — and harmless for the same reason. |
| **Tampering with `CollaborationData`** | It is opaque [E11]; the DO can only relay, size-cap, and rate-limit it (as today: 1 MiB unconfirmed budget [R6]). It must therefore **never be an input to verdicts**; it is a convenience for client-side convergence only. | — | Everything inside it. |
| Poisoning the fused model to *hurt* the opponent (false write, [E17]) | Per-phone provenance on every fused element; the opponent's client may always render its *own* observations and treat fused-only geometry as advisory. | Yes, by construction of the conflict rules above. | — |

### 4.4 Cross-cutting

- **Identity and ticket theft.** Tickets are 120 s HS256 JWTs bound to match/player/epochs [R10][R11]. Fine for authorization; they say nothing about the *app* that holds them (see §6).
- **Flooding.** Token buckets exist [R6]. Cloudflare's own Rate Limiting binding is *per-colo, permissive, eventually consistent* and "intentionally designed to not be used as an accurate accounting system" [E16]; the DO's single-threaded, per-object private storage [E14][E15] is the right place for exact accounting, which is where the repository already puts it. Keep it there.
- **Storage exhaustion of the match DO.** Storage-API limits and per-object caps apply [E14]. Map patches need a hard per-match byte budget and eviction, not just per-second rate limits.

## 5. Cross-phone corroboration without a shared-frame ritual

The BIO-36 premise removes the up-front alignment step, but it does **not** remove alignment; it makes alignment a *background estimate with a confidence*. Everything valuable in §4 — anchoring hits to the victim's phone, resolving wall conflicts — needs a relative transform \(T_{AB}\) between the two phones' world frames plus an uncertainty.

Sources of \(T_{AB}\), cheapest first (all **[speculation]** as to accuracy; none has repository or device evidence):

1. **Gravity.** Both frames are gravity-aligned [R12], so \(T_{AB}\) is 4-DoF (yaw + translation), not 6-DoF, from the first frame. This alone lets the DO check "is the victim's head above the victim's phone-height band?" in any frame.
2. **Mutual sightings.** Every accepted sighting is a ray from A that (per A) passes through B's body; B's authenticated phone pose at the same instant gives a point that should lie near that ray. Two or more non-parallel accepted sightings in each direction over-determine yaw + translation. This is the only corroboration source that costs zero extra sensing, and it improves as the match is played — precisely "playable before convergence".
3. **Map-patch overlap.** When both phones have mapped the same wall/floor, plane-to-plane registration refines \(T_{AB}\). This is the expensive path and the one most exposed to poisoning; feed it with patches only after they pass §4.3.
4. **Optional saved arena / `ARWorldMap` relocalization.** Gives a strong \(T_{AB}\) immediately for players who opt in [R8][E10] — keep as the "high-fidelity mode", never a prerequisite.

Confidence policy: publish \(\sigma(T_{AB})\) in the snapshot. While \(\sigma\) is large, the corroboration checks run in *advisory* mode (log disagreements, feed reputation, do not refuse hits); once \(\sigma\) is below the anchor radius (2 m today [R4]), anchoring becomes *enforcing*. This is the explicit fallback the assignment asks for: **combat is always resolvable from the shooter's evidence alone (today's behaviour); corroboration only ever adds refusals, and only after it has earned the right to.**

A colluding second phone (A4) defeats corroboration by construction — two liars agree. This is why competitive play needs attestation and reputation (§6, §8), and why friend play does not.

## 6. Attestation options

What Apple provides, and what it does and does not prove:

- **App Attest** [E1][E2][E3] — hardware-backed per-app-instance key; the server issues a one-time challenge, verifies the attestation certificate chain, `rpId`, `counter == 0`, environment `aaguid`, and stores the public key + receipt; later **assertions** sign each sensitive request's `clientDataHash` and the server must check the assertion counter is *greater than the previous* one, which gives replay resistance per key. Apple is explicit that "you can't rely on your app's logic to perform security checks on itself because a compromised app can falsify the results" and that the receipt-derived fraud-risk metric surfaces one device serving many app copies. **[primary]**
- **DeviceCheck** [E4] — a per-device authenticated token and two server-managed bits; semantics are the app's to define. **[primary]**

What this buys the threat model: **A1 (client rewrite) becomes expensive** — a rewritten client cannot produce valid assertions, so the DO can reject unattested fire/patch commands in competitive tier. It **does not** address A2 (sensor substitution inside a genuine app), A4 (collusion), or A5 (physical cheating), and it does not make any body, depth, or map claim *true*. Attestation authenticates the *speaker*, not the *statement*. Recommended placement: attest at ticket mint (Convex, which already throttles to 1/s/player [R11]) and bind the attested key ID into the ticket claims; require an assertion on a rolling challenge for fire commands and map-patch uploads in competitive tier only. Assertions on every 50 ms pose are unnecessary and costly; the pose stream is already plausibility-bounded and is the *corroborating* evidence, not the *claiming* evidence.

Cost note **[speculation]**: App Attest is unavailable on some devices/regions and in the simulator; the friend tier must work without it.

## 7. Rate limits, audit ledger, dispute evidence, privacy

**Rate limits.** Keep exact accounting in the DO (single-threaded, private storage [E14]); use Cloudflare's Rate Limiting binding only as a coarse pre-filter at the Worker edge because it is per-location and eventually consistent [E16]. Add per-match byte budgets for map patches and a per-phone patch cadence (e.g. one bounded patch per N seconds — value is speculation, to be set by experiment), separate from the 60 cmd/s command bucket [R6].

**Audit ledger.** The DO already stores every command's canonical fingerprint and every ordered event [R7]. Extend the stored record for fire and patch commands with: the resolved \(T_{AB}\) and \(\sigma\) at verdict time, the corroboration outcome (agree / disagree / advisory-only), attestation key ID (competitive), and the hash of the observation. Because storage is private per object and transactional [E15], the ledger is tamper-evident against clients by construction; it is *not* tamper-evident against the operator, which is acceptable for this product and should be stated as such. Retention should follow the existing `IDLE_RETENTION_MS` (24 h) [R6] unless a report pins the match.

**Dispute/report evidence.** Today's report path creates a GitHub issue with no spatial evidence [R9]. A report should pin the match ledger (not raw sensor data) and include the last N verdict records with corroboration outcomes. Raw camera frames must not be uploaded: none exist server-side today and adding them would convert the product into a video-collection service (see privacy). If a client-side "evidence clip" is ever added, it should be opt-in per report, encrypted for the operator, and time-boxed.

**Privacy.** Trajectories and room geometry are location-like data about a private space; body colliders are biometric-adjacent. Apple's App Privacy Details require disclosing any data transmitted off device and retained beyond servicing the request, including data used "solely for the purpose of app functionality" [E21]. Consequences: (a) the ledger described above *is* collection and must be disclosed; (b) prefer sending derived geometry (planes, bounded meshes, colliders) over depth images or frames; (c) never persist map patches past match retention unless the user saves an arena; (d) the spectator projection already excludes camera/map/body data [R11] — keep it that way; (e) the *opponent* is a data subject too: a shooter's body colliders describe the victim's body, and map patches describe whichever home the match is in.

## 8. Trust tiers

| | Friend play (default) | Competitive / ranked (future) |
|---|---|---|
| Who is trusted | Both players trust each other; the server exists for consistency, not adjudication. | Nobody; the DO must be able to refuse and to *record why*. |
| Hit verdict | Shooter evidence resolves the hit (today's ADR 0013). Corroboration is advisory and used only to improve \(T_{AB}\) and show a "disputed" marker. | Shooter evidence *plus* victim-pose anchoring once \(\sigma\) permits; unanchored hits refused (`poseMismatch`), and refusal rate feeds reputation. |
| Room model | Fused freely; conflicts resolved against the beneficiary (§4.3) but no penalty. | Same rules, plus per-phone provenance retained in the ledger; repeated conflicts flag the phone. |
| Attestation | None required (must work on all devices and simulator). | App Attest at ticket mint + assertions on fire/patch. |
| Ledger | Ephemeral (24 h). | Pinned on report; corroboration outcomes stored. |
| Payoff bound | N/A | Cover reduces damage only; never awards. Fake body evidence bounded by anchoring; wall lies bounded by symmetric conflict rules. |

The tier is a **match rule** (like `rules.geometry`) chosen at Convex `combat:prepare` and carried in the ticket, so the DO enforces one policy per match and the client cannot downgrade it mid-match.

## 9. Recommended explicit trust boundaries

1. **Phone → DO: every spatial message is a claim, not a measurement.** Structural validation proves well-formedness only. The only inputs the DO treats as *authenticated facts* are: the ticket, the connection identity, its own receive clock, and (competitive) attestation assertions.
2. **Shooter evidence may award a hit; victim evidence may veto it.** The victim's own pose stream is the only witness the shooter does not control. Extend `anchoredToPhone` to sighting mode behind a \(\sigma\) gate.
3. **Room evidence may only *reduce* what a claimant can do.** Cover blocks or attenuates; it never scores. Conflicts resolve against the party who benefits. Absence of geometry is *unknown*, never *free*.
4. **Opaque `CollaborationData` never reaches a verdict.** Relay, cap, rate-limit; nothing else.
5. **Client-declared confidence is a quality hint for honest fallback, never a trust input.** Trust is earned only by corroboration.
6. **Attestation authenticates the app instance, never the observation.** Use it to make client rewrites expensive in competitive tier; do not let it upgrade any claim to fact.
7. **Exact accounting lives in the DO; edge rate limits are a pre-filter.**
8. **The ledger stores verdicts and provenance, not sensor payloads.** Raw frames/depth never leave the phone by default.
9. **Convex remains the only path to lobby/match state and to the spectator, through the authenticated projection; no spatial evidence is projected.**
10. **Saved arenas are a stronger \(T_{AB}\) prior, not a permission.** Nothing in normal play may require them.

## 10. What cannot be done without room sensors (stated as limits)

- The DO cannot distinguish a synthesized body/depth/mesh from a real one when only one phone has observed the region. Corroboration is the only remedy and it fails under collusion.
- The DO cannot detect a wall neither phone has seen or a wall that only the cheater has seen and omitted.
- Sub-window timestamp backdating within the lag-compensation window is inherent to any lag-compensated design [E19, practitioner]; it is bounded by the window, not removed.
- Client-declared `tracking === "normal"`, `associationConfidence`, `uncertaintyMeters`, and per-joint confidences are unverifiable scalars.
- No claim in this brief about ARKit behaviour on a physical device (alignment accuracy, sighting-derived \(T_{AB}\) convergence, LiDAR/non-LiDAR mixed matches) has device evidence; §5 and the numeric suggestions in §4 are labeled speculation and need the experiment protocol below.

## 11. Proposed experiment protocol (next spike)

1. **Sighting-derived alignment.** Two named devices, two rooms sizes; log accepted sightings and the victim's pose; offline-estimate yaw+translation and \(\sigma\) vs number of sightings. Success: \(\sigma < 2\) m within the first minute of honest play.
2. **Anchoring false-positive rate.** With honest play, count how many legitimate sighting hits would be refused by `anchoredToPhone` at 2 m in the sighting frame once \(\sigma\) is under threshold. Success: < 2 % refusals.
3. **Wall-conflict rules.** Scripted fake patches (omission, insertion, oversized) against a recorded honest patch stream in the simulation package's test harness; assert conflicts resolve against the beneficiary and honest verdicts are unchanged.
4. **Attestation cost.** Measure App Attest assertion latency on device for a fire command; decide whether fire-time assertion is viable or must be pre-issued.

## Sources

Repository (read 2026-09-26; paths relative to repository root):

- [R1] `packages/combat-protocol/src/index.ts` — envelope, `pose`, `fire`, `BodyObservation`, `BodyCollider` types; `sentAtMs`/`capturedAtMs` semantics.
- [R2] `packages/combat-protocol/src/validation.ts` — exact-key and range validation.
- [R3] `packages/combat-simulation/src/index.ts` — admission gates, sighting-mode gating (`COVER_OBSERVATION_MS`, 0.8 / 0.1 m), pose-observation ignore in sighting, `anchoredToPhone` use in shared-frame mode.
- [R4] `packages/combat-simulation/src/history.ts` — `MAX_SPEED = 15`, `POSITION_SLACK = 0.1`, 8π rad/s, `COVER_OBSERVATION_MS = 1_000`, `BODY_ANCHOR_METERS = 2`, `bodyMovementValid`, `anchoredToPhone`.
- [R5] `packages/combat-simulation/src/flight.ts` — `resolveSighting` (shooter-space intersection against shooter-supplied colliders).
- [R6] `services/combat-worker/src/room.ts`, `connection.ts` — ticket admission, token buckets, idempotency/fingerprint, epoch handling, `IDLE_RETENTION_MS`, `MAX_UNCONFIRMED_COLLAB_BYTES`.
- [R7] `services/combat-worker/src/store.ts` — SQLite tables for commands (fingerprint, result), events, shared maps, chunks.
- [R8] `services/combat-worker/src/maps.ts`; `ios/**/Targeting/SharedArena/DuelFrame/DuelFrameModels.swift` (`maximumBytes`) — host-only upload, 8 MiB cap, SHA-256 frame ID, immutability.
- [R9] `services/combat-worker/src/report.ts` — authenticated, capped, deduplicated report → GitHub issue.
- [R10] `services/combat-worker/src/auth.ts`, `validation.ts` — HS256 ticket verification and claim checks.
- [R11] `convex/functions/combat.ts`, `convex/lib/combat_ticket.ts` — `combat:prepare`, `combat:ticket` (120 s, 1/s/player), HMAC projection ingestion.
- [R12] `ios/**/Targeting/TargetingSession.swift`, `MapLab/MapLabARDriver.swift`, `SharedArena/SharedArenaSession.swift` — ARKit configuration, plane detection, collaboration, world-map install, body tracking, Vision fallback; absence of `sceneDepth`/`sceneReconstruction`/`ARMeshAnchor`.
- [R13] `ios/**/Features/Realtime/RealtimeBodyAssociation.swift`, `RealtimeArenaController.swift`, `ios/**/Services/Realtime/CombatWire.swift` — 50 ms pose pump, association thresholds, fire payload construction.
- [R14] `.github/workflows/deploy.yml`; `scripts/release/combat-deploy.mjs` — normal deploy excludes the worker; guarded operator deploy.
- [R15] `docs/decisions/0010-quick-play-relocalized-frame-and-phone-proxy.md`, `0011-quick-play-continuous-collaboration.md`, `0013-quick-play-sighting-hits.md`; `docs/features/shared-spatial-hit-registration/requirements.md` — accepted trust limitations.

Primary documentation (accessed 2026-09-26):

- [E1] Apple, *Establishing your app's integrity* (App Attest) — https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity
- [E2] Apple, *Validating apps that connect to your server* — https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
- [E3] Apple, `DCAppAttestService.generateAssertion(_:clientDataHash:completionHandler:)` — https://developer.apple.com/documentation/devicecheck/dcappattestservice/generateassertion(_:clientdatahash:completionhandler:)
- [E4] Apple, *DeviceCheck* framework overview — https://developer.apple.com/documentation/devicecheck
- [E5] Apple, `ARFrame.sceneDepth` — https://developer.apple.com/documentation/arkit/arframe/scenedepth
- [E6] Apple, `ARWorldTrackingConfiguration.supportsSceneReconstruction(_:)` — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)
- [E7] Apple, `ARMeshAnchor` — https://developer.apple.com/documentation/arkit/armeshanchor
- [E8] Apple, `ARPlaneAnchor.Classification` — https://developer.apple.com/documentation/arkit/arplaneanchor/classification-swift.enum
- [E9] Apple, `VNDetectedPoint.confidence` / `VNHumanBodyPoseObservation` — https://developer.apple.com/documentation/vision/vndetectedpoint/confidence ; https://developer.apple.com/documentation/vision/vnhumanbodyposeobservation
- [E10] Apple, `ARWorldMap` — https://developer.apple.com/documentation/arkit/arworldmap
- [E11] Apple, `ARSession.CollaborationData` — https://developer.apple.com/documentation/arkit/arsession/collaborationdata
- [E12] Apple, `ARCamera.TrackingState` — https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
- [E13] Apple, `ARBodyAnchor` / `estimatedScaleFactor` — https://developer.apple.com/documentation/arkit/arbodyanchor
- [E14] Cloudflare, *Durable Objects* overview and *Limits* — https://developers.cloudflare.com/durable-objects/ ; https://developers.cloudflare.com/durable-objects/platform/limits/
- [E15] Cloudflare, *Durable Object Storage API* — https://developers.cloudflare.com/durable-objects/api/storage-api/
- [E16] Cloudflare, *Rate Limiting binding* — https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/
- [E21] Apple, *App privacy details on the App Store* — https://developer.apple.com/app-store/app-privacy-details/

Academic / practitioner / tertiary (marked as such in text):

- [E17] **[academic]** Slocum, Ruoff, Zhang, Yang, Chen, Kotcher, Roesner, *"That Doesn't Go There": Attacks on Shared State in Multi-User Augmented Reality Applications*, USENIX Security 2024 — https://www.usenix.org/conference/usenixsecurity24/presentation/slocum
- [E19] **[practitioner]** Gambetta, *Fast-Paced Multiplayer (Part IV): Lag Compensation* — https://www.gabrielgambetta.com/lag-compensation.html
- [E20] **[tertiary]** Wikipedia, *Footspeed* (peak recorded human sprint ≈ 44.72 km/h ≈ 12.4 m/s) — https://en.wikipedia.org/wiki/Footspeed
