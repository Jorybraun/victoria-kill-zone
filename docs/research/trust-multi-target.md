# Trusting client-chosen target identity in 3–4-player Quick Duel (BIO-37)

Status: Research complete — 2026-09-27.
Method: One repository audit of the sighting-mode fire path (iOS association → `fire.observation` → `CombatSimulation` → `resolveSighting`), one threat enumeration for each identity attack named in the assignment, one primary-source pass on the Apple and Cloudflare primitives the design can actually lean on (Nearby Interaction availability semantics, ARKit body tracking, App Attest, Durable Object state/alarms), and one synthesis into validation rules, trust tiers, and a fail-closed/fail-open table. No code was edited, no build or device run was performed, and nothing in this brief is physical-device evidence. Claims are tagged **[repo]** (read from `main` at `3d89b7f8` on 2026-09-27), **[primary]** (Apple/Cloudflare documentation), **[academic]**, **[practitioner]**, or **[speculation]**. Absences are stated as absences.

This brief builds on `docs/research/client-evidence-threat-model.md` (BIO-36) and `docs/research/zero-step-architecture-synthesis.md` §9–§11. It does not restate the BIO-36 trajectory/depth/map threat matrix, the App Attest placement argument, or the shared-frame material: per the product owner, the shared-frame / Saved Arena path (ADR 0010/0011, `SharedArena`/`DuelFrame`) is being removed, and the "aligned-frame" association code cited below is quoted only to show what will *not* be available, not as a design option.

## 1. The question

Quick Duel is the only play mode. Each phone runs its own AR frame, the match Durable Object (DO) is the combat authority, and start is never gated by a setup step. Today the mode is capped at two players because a body sighting cannot tell *which* opponent was hit: the client simply names the only opponent. The owner wants 2–4 players.

With three or four players the `targetPlayerId` on a fire becomes a **choice the shooter makes**, and the DO has no room sensor to check it. The question is: **given only each player's own pose stream, the shooter's sighting, whatever mutual sightings exist, physical plausibility, and rate limits, which target-identity lies can the DO detect, which can it only bound, and how should friend play fail when it cannot tell?**

## 2. What the repository does today (confirmed evidence)

### 2.1 Identity is decided on the shooter's phone, by roster count

`RealtimeAssociationPolicy.associateSighting` returns a body association only when exactly one connected remote roster member exists; it then attaches that player's ID to whatever skeleton the camera currently sees, with `confidence = observationConfidence`, `handDistanceMeters = 0`, `marginMeters = .infinity`. **[repo]** [R6] There is no per-body identity reasoning in sighting mode. The "aligned-frame" `associate(...)` path (nearest hand-to-phone distance, 0.45 m cap, 0.35 m margin) requires remote phone poses in a shared frame **[repo]** [R6] and goes away with the shared-frame removal.

The fire payload in sighting mode is built in `RealtimeArenaController` from the camera ray plus the association: `targetPlayerId` from the association, `associationConfidence` from the association, a **constant** `uncertaintyMeters = 0.08`, and colliders generated from the skeleton. **[repo]** [R7] Uncertainty is therefore not a measurement today; it is a literal.

### 2.2 The camera keeps one body

`TargetingSession` uses `ARBodyTrackingConfiguration` where supported and a throttled `VNDetectHumanBodyPoseRequest` otherwise. The Vision path `compactMap`s every returned observation into a scored candidate (body confidence, bound area, crosshair proximity) and keeps only `.max(by: score)`. **[repo]** [R8] `ARBodyAnchor` "tracks the movement of a single person" **[primary]** [E4], and `ARFrame.detectedBody` is a single optional `ARBody2D` **[primary]** [E5]. Consequence: **the wire never learns how many bodies were in view**. A "two bodies visible → refuse" rule (ADR 0013's candidate B) cannot be enforced by the DO from current evidence; it would have to be a client-side self-report. **[repo]** [R8][R11] This is an absence.

### 2.3 What the DO checks in sighting mode

In `CombatSimulation` the sighting fire path is:

```ts
const opponents = players.filter(other => other.playerId !== p.playerId);
if (opponents.length !== 1) return "ambiguousTarget";
if (!observation || !validObservation(observation)) return "noSighting";
if (observation.targetPlayerId !== opponents[0].playerId) return "invalidInput";
if (observation.capturedAtMs > now) return "futureInput";
if (now - capturedAtMs > COVER_OBSERVATION_MS /*1000*/ || associationConfidence < 0.8
    || uncertaintyMeters > 0.1 || colliders.length === 0) return "noSighting";
```

**[repo]** [R2][R3] Pose-message `observations` are discarded in sighting mode (`[]`), so no victim-side or third-party body evidence is retained. **[repo]** [R2] `resolveSighting` sweeps the shooter's ray against the **shooter-supplied** colliders only; the target's own pose stream is not consulted, only `health` and `protectedUntilMs`. **[repo]** [R4] Convex rejects a sighting roster above `QUICK_DUEL_MAX_PLAYERS = 2` at prepare and at join. **[repo]** [R9]

So today the 3–4-player case is already **fail-closed at three layers** (Convex prepare/join, DO `ambiguousTarget`, client `remote.count == 1`). Lifting the cap means deliberately opening those gates; the rest of this brief is about what must be added before they are opened.

### 2.4 Controls that already exist and carry over

Structural validation (exact keys, finite bounded vectors, near-unit direction, confidence ∈ [0,1], uncertainty ∈ [0,10], 1–32 colliders) **[repo]** [R1]; pose plausibility (`MAX_SPEED = 15` m/s + 0.1 m slack, 8π rad/s, `poseAgeMs = 100`, `rewindMs = 250`, `clockUncertaintyMs = 25`) **[repo]** [R1][R3]; fire ray must originate within 0.5 m of the shooter's stored pose and within ≈15° of its forward **[repo]** [R2]; command fingerprints + monotone `clientSequence` for idempotency, conflicting reuse rejected **[repo]** [R5]; per-connection token buckets (90-token burst, refill at `commandsPerSecond = 60`), a Nearby Interaction token bucket, 24 h idle retention **[repo]** [R5]; tickets are HS256 with roster claims minted by Convex **[repo]** [R5][R9]. All of this bounds *message* plausibility. None of it says anything about *who the body was*.

### 2.5 Absences (repository-wide search, 2026-09-27)

- No code sends per-body candidate lists, body counts, bearing to peers, or per-joint confidences on the fire message. [R1][R7]
- No App Attest / DeviceCheck code exists (unchanged from BIO-36). [R5]
- No Nearby Interaction data reaches `CombatSimulation`; the NI models in `ios/**/Targeting/NearbyInteraction/` are rendezvous-oriented (optional direction, ≤ 50 m distance, finite-vector validation) and belong to the path being removed. [R10]
- No dispute/ledger table distinguishes "hit adjudicated on shooter evidence alone" from "hit corroborated". [R5]

## 3. Adversary and asset model (delta from BIO-36)

BIO-36 §3 adversaries (modified client, replay proxy, colluding pair) all apply. What changes with 3–4 players:

- **The asset is the mapping body → playerId**, not the body geometry. A shooter who really sees *someone* now controls *who* takes damage.
- **Payoff is asymmetric**: in a 2-player match a target lie is worthless (there is one target). In a 3–4-player match, redirecting hits to the player at lowest health, or to the one leading, converts an honest sighting into a chosen kill. **[inference]**
- **A third honest player is a new witness.** Unlike 2-player, the DO can sometimes hear from someone who is neither shooter nor claimed victim. This is the only genuinely new *evidence* the roster size brings; everything else is new *attack surface*.
- **Denial becomes cheap**: in 2-player, "not being identified" just means not being shot. In 3–4-player, one player's ambiguity can be used to poison verdicts against others (e.g., stand next to the leader so shots on the leader become "ambiguous").

Trusted facts remain exactly the BIO-36 list: ticket claims (roster, playerId, match), connection identity, DO receive clock, sequence/fingerprint state. `associationConfidence`, `uncertaintyMeters`, `capturedAtMs`, colliders, and `targetPlayerId` are all client claims. **[repo]** [R1][R5]

## 4. Threat matrix for target identity

Each row: what the attacker sends, what the DO can see today, what it could see with the evidence listed in §5, and the residual.

### 4.1 Claim a hit on the weakest / arbitrary player

- **Attack.** Honest sighting of body X; `targetPlayerId` set to the roster member with lowest `health` (visible to every client via snapshots). **[repo]** [R2]
- **Today.** Undetectable once `opponents.length !== 1` is lifted: the DO checks only roster membership, alive, protection window. [R2][R4]
- **With §5 evidence.** Detectable *only* when the DO holds an estimate of where the claimed victim is relative to the shooter and that estimate contradicts the ray. Victim-pose anchoring (§5.1) gives this once a relative-frame estimate exists; third-party sightings (§5.2) give it when a bystander was watching. Without either, the DO can only bound it: rate/entropy limits on *whom* a shooter hits versus who is nearest in the shooter's own sighting history (§5.4). **[inference]**
- **Residual.** A shooter who names the victim who *is actually* in front of them is honest by definition; the lie only works when the true body belongs to someone else, and that is exactly the case where the true body's owner is an honest witness whose pose stream can veto. Two-of-three honesty makes the lie detectable in a 3-player match once frames are estimated; in a 4-player match with two colluders it is not (§4.4).

### 4.2 Identity spoofing via radio beacons (Nearby Interaction / BLE)

- **Attack.** If identity were derived from a UWB/BLE bearing ("the peer whose NI direction best matches the crosshair is the target"), an attacker (a) replays or relays another peer's discovery token, (b) places a second device near a different player, or (c) simply reports a fabricated direction — NI results are consumed on the *shooter's* phone and would cross the wire as client claims. **[inference]**
- **What primary docs establish.** NI provides `distance` and `direction` per peer; either may be `nil` — out of range → both nil, out of the narrow line-of-sight cone → direction nil; obstacles such as people or walls break the line of sight; best case is within 9 m, portrait, facing with the rear camera. **[primary]** [E1][E2] Direction is only available where `supportsDirectionMeasurement` is true, and Apple documents distance-only devices as a distinct capability class. **[primary]** [E2][E3] Camera Assistance (iOS 16+) widens coverage by fusing with ARKit but still runs on the shooter's device. **[primary]** [E6] Apple documents no anti-spoofing, authentication, or integrity property for NI measurements; none was found. This is an absence in the documentation as read, not proof of absence in the system.
- **Assessment.** NI direction is at best an *additional shooter-side hint*, unavailable on part of the device mix, unavailable when a person stands between two phones (precisely the crowded 4-player case), and carried to the DO as an unverifiable claim. **It cannot be a security input.** The repository already handles direction-unavailable cases in its rendezvous models [R10], confirming the field is optional in practice. Whether NI direction is even *useful* as a disambiguation hint in a 3 m room with bodies occluding is **[speculation]** without device evidence; no device test exists.

### 4.3 Confidence and uncertainty inflation

- **Attack.** Send `associationConfidence = 1.0`, `uncertaintyMeters = 0.01`, tight colliders, for any body or no body.
- **Today.** These fields gate admission (≥ 0.8, ≤ 0.1 m) and nothing else. Since `uncertaintyMeters` is already a client constant [R7], the check `uncertaintyMeters > 0.1` is a no-op against an honest client and a formality against a dishonest one. Confidence ≥ 0.8 is a quality filter for honest clients, not a security control. **[repo]** [R2][R7]
- **Recommendation.** Keep them as *honest-client quality hints* (they stop a laggy honest phone from firing on a stale skeleton) and add nothing to the trust model on their basis. Use them for **tier demotion only**: a shooter whose distribution of confidence is implausibly perfect (e.g., 100% of fires at exactly 1.0 over N shots) is flagged, never rewarded. Vision confidences are per-point scores with no documented calibration guarantee **[primary]** [E7]; no threshold on them can be defended as security.

### 4.4 Colluding players

- **Attack.** A and B collude: A fires with `targetPlayerId = C` while B's pose stream and B's own sightings are shaped to corroborate A's claim (or simply to never veto it). In a 4-player match, two colluders form a majority against any single honest witness.
- **Assessment.** BIO-36 already states that two colluding phones defeat cross-phone corroboration by construction. With rosters of 3–4 this becomes concrete: **corroboration must never be a vote among clients.** The DO should require corroboration to come from the *claimed victim's own authenticated stream* (a veto right the victim always has, §5.1), not from "any two players agree". A victim cannot be out-voted about where their own phone was.
- **Residual.** Colluders can still (i) shoot each other for free hits on their own account — only relevant if there is scoring beyond the match, and the synthesis already recommends room evidence never *creates* score; (ii) have the colluding "victim" waive their veto. Neither harms an honest third party. What harms C is only A claiming C *while C's stream contradicts it*, which §5.1 catches without any vote. **[inference]**

### 4.5 Replayed and backdated sightings

- **Attack.** Capture a valid observation of C at t₀, resend it at t₁ with a fresh `commandId`; or set `capturedAtMs` back to when C was in front of the shooter.
- **Today.** Fresh `commandId`/`clientSequence` defeats fingerprint dedup **[repo]** [R5]; `capturedAtMs` must be ≤ now and within `COVER_OBSERVATION_MS = 1 000 ms` **[repo]** [R2][R3]. The 1 s window is 10× the pose freshness window (100 ms) and 4× the rewind window (250 ms). Within that second, an observation of C can be attached to a ray fired after C moved; `resolveSighting` will still intersect the *stale* colliders. **[repo]** [R4]
- **Recommendation.** Tighten sighting `capturedAtMs` age to the rewind window (250 ms) and require `capturedAtMs ≥ (time of pose poseSequence) − rewindMs`, i.e., the observation must be contemporaneous with the pose the fire is anchored to. Additionally bind the observation to the ray: require the colliders' centroid to lie within the shooter's forward cone and within `weapon.rangeMeters` — cheap and already in the shooter's own frame. **[inference]** Replay across matches is already impossible (ticket is match-scoped) **[repo]** [R5].

### 4.6 Denial — hiding from identification

- **Attack.** A player keeps their phone pose stream stale, moves to make Vision lose them, or stands adjacent to the leader so any sighting is ambiguous, hoping ambiguity protects them or the leader.
- **Assessment.** Two distinct denials: **(a)** *self-denial* — a player whose own pose stream is stale cannot exercise a veto; the correct policy is that a stale victim forfeits the veto (shooter evidence stands), so hiding never protects; **(b)** *ambiguity poisoning* — making the DO unable to distinguish two victims. Because the camera keeps only one body (§2.2), ambiguity is not even visible to the DO today; if a client-side body count is added, a rule "two bodies → refuse" is a self-report and thus a *gift* to the poisoner (the leader just claims two bodies are always visible). Ambiguity must therefore never block a *match*, and should block a *shot* only on the DO's own evidence (two victims' pose estimates both consistent with the ray), never on a client's say-so. **[inference]**

### 4.7 Cross-cutting: the 100-ms pose stream is not an identity oracle

`poseAgeMs = 100` ensures pose freshness, and `phoneMovementValid` bounds speed; neither prevents a modified client from streaming a *plausible but false* trajectory. A colluder can drift their phone pose to wherever the shooter needs it. So victim-pose anchoring is a veto in the hands of the victim, not a proof in the hands of the DO. **[repo]** [R3] **[inference]**

## 5. Validation the DO can actually perform

Ordered from "available today" to "requires new evidence".

### 5.1 Victim's own pose stream as veto (needs a relative-frame estimate)

Each phone streams `PhonePose` at ~50 ms in its own frame [R7]; the DO stores it (`phoneAt`) [R3]. In shared-frame mode `anchoredToPhone` required body colliders to lie within `BODY_ANCHOR_METERS = 2` of the target's phone [R3]; in sighting mode it is skipped because the frames differ. With the shared-frame ritual removed, the *only* way to reuse this check is the BIO-36 §5 idea: **estimate a per-pair rigid transform from sightings themselves** (shooter's ray + collider centroid says "victim is at p in my frame"; victim's stream says "I am at q in mine"; accumulate (p,q) pairs, solve the transform, track residual). That estimator is **[speculation]** and unvalidated on devices; it is inherited from BIO-36, not new here.

What is new for 3–4 players: the estimator is *per ordered pair*, so a 4-player match has up to 12 transforms, each fed only by the shooter's sightings of that particular victim. Convergence is therefore slower and uneven. Policy implications:

- Before pair (A→C) has a transform with residual below threshold, victim-anchoring for A's claims on C is **unavailable**, not failed. The verdict falls through to §5.3–5.4.
- When available, it is a **veto**: if C's phone at `capturedAtMs` (in A's frame via the transform) is farther than `BODY_ANCHOR_METERS` plus transform uncertainty from the colliders' centroid, the hit is refused (`identityMismatch`, new refusal) in the strict tier, or recorded as *disputed* and applied in the friend tier (§6).
- **Bonus check specific to multi-target:** if the *same* centroid is within anchor distance of a *different* roster member D's estimated position and not C's, the DO has positive evidence of misattribution, not just absence of corroboration. This is the clearest signal available and is what actually catches §4.1.

### 5.2 Mutual and third-party sightings

Pose messages carry `observations: BodyObservation[]` but sighting mode zeroes them [R2]. Retaining them (bounded: ≤ roster−1 per pose, exact-key validation already exists [R1]) lets the DO see, when B looks at C, where B thinks C is. Uses:

- Feed the pair-transform estimator for (B→C) without waiting for B to fire. **[inference]**
- Bystander veto: if B's contemporaneous sighting of C places C where A's ray could not have reached (after both transforms are estimated), A's hit on C is disputed. **[inference]** This is *witness*, not *vote*: it only ever *reduces* an outcome (BIO-36 rule).
- Denial symmetric: C's own sightings of A (C is looking at A) place A relative to C, giving C's veto a second source even if C's pose stream is briefly stale.

Byte cost: `BodyObservation` with ≤ 32 colliders per target, 3 targets, 20 Hz — well inside current per-connection buckets but should be capped explicitly (e.g., ≤ 1 observation per target per tick). **[inference]**

### 5.3 Physical plausibility in the shooter's own frame (available today)

All of these need no cross-frame estimate and should be added regardless of tier:

- Observation colliders' centroid within the shooter's forward cone (reuse the ≈15° fire-cone constant) and within `weapon.rangeMeters`. [R2]
- Collider set anthropometrically bounded (BIO-36 §4.2 speculation; still speculation).
- `capturedAtMs` within `rewindMs` of the anchoring pose, not `COVER_OBSERVATION_MS` (§4.5).
- Per-shooter **target-switch plausibility**: two consecutive fires on different victims whose centroids (in the shooter's frame) are farther apart than a body could have moved plus the shooter could have turned in the elapsed time are jointly implausible — one of the two claims is stale or fabricated. Uses only the shooter's own colliders and the existing 15 m/s and 8π rad/s bounds. **[inference]**

### 5.4 Rate limits and distribution guards (available today, DO-side)

Existing buckets bound fires/s [R5]. Add target-aware accounting, all in the DO where exact accounting belongs (BIO-36):

- Max hits per victim per window from a single shooter (weapon rate already bounds this; make it explicit per target).
- **Target-choice entropy guard [speculation]:** in a match where a shooter's *own* sightings (pose-message observations) show victim X nearest most of the time but fires overwhelmingly name victim Y, flag the shooter. This is a heuristic for the ledger, not a refusal.
- Alarm-driven periodic audit inside the DO: a single alarm per DO can drive a schedule **[primary]** [E9]; in-memory state must be persisted because eviction/hibernation loses it **[primary]** [E8]. Any ledger described here must live in the DO's SQLite store, not in instance fields. [R5]

### 5.5 What the DO cannot do (stated as limits)

- It cannot tell how many bodies the camera saw (§2.2). Any body-count rule is client self-report.
- It cannot verify NI/BLE bearings (§4.2).
- It cannot verify Vision or ARKit confidence (§4.3).
- It cannot distinguish an honest victim from a colluding one who waives the veto (§4.4).
- Before a pair transform is estimated, it cannot check *any* identity claim against independent evidence; the first N shots of every pairing in every match are shooter-word-only. This is inherent to zero-setup and is the price of removing the ritual. **[inference]**

## 6. Trust tiers

### 6.1 Friend tier (the only tier the product ships now)

Goal: play starts instantly, never stalls, cheating among friends has bounded, visible payoff.

- Start immediately with roster 2–4; no gate on transform convergence. **[matches product decision]**
- Fire on a structurally valid sighting **applies the hit** (fail open on identity) with a verdict flag: `attribution: "shooterOnly" | "victimAnchored" | "disputed"`. Snapshots expose the flag so the UI can render disputed hits distinctly (design decision; out of scope here).
- Victim anchoring, when available and contradicting, marks `disputed` but **still applies** the hit in this tier. Rationale: a false veto (bad transform estimate, honest but drifting phone) would otherwise silently break the game for honest players and would be indistinguishable from cheating to them; friend play optimizes for not being wrong *against* honest players. **[inference]**
- Positive misattribution (§5.1 bonus: centroid matches D, not C) is the one identity signal strong enough to **refuse** even in friend tier, because the alternative is C taking damage for a body that was demonstrably D's. Refuse with `identityMismatch`; do not redirect to D (never let DO evidence *create* a hit on someone the shooter did not name).
- All plausibility rules in §5.3 and the replay tightening in §4.5 are enforced (fail closed on the *shot*): they only reject shots an honest client would not send.
- Ledger every fire with attribution flag, transform residual, and which vetoes were available. Retained with the match (24 h) [R5]. End-of-match summary can show "N disputed hits" — social enforcement is the actual control in friend play.

### 6.2 Verified tier (future; not required by BIO-37)

- App Attest per BIO-36 §6 (authenticates app instance; **[primary]** [E10] assertion counter and challenge defeat replay of the attestation, not of the observation).
- Victim anchoring **enforcing**: disputed → refused (`identityMismatch`), but only once pair residual < threshold; before that, shots are still shooter-only, so the tier changes *what a dispute does*, not *when disputes exist*.
- Third-party witness veto enforcing.
- Rate/entropy guards escalate to refusal after a threshold.
- Body-count self-report may be accepted as *self-refusal* (client says "two bodies, I refuse to fire") but never as grounds to refuse *another* player's shot.

## 7. Fail closed vs fail open

| Condition | Friend tier | Verified tier | Why |
|---|---|---|---|
| Roster 3–4, no transform yet for (shooter→victim) | **Open**: apply, flag `shooterOnly` | **Open**: apply, flag `shooterOnly` | Zero-setup means the first shots are always unverifiable; closing here re-creates a setup gate. |
| Structural/temporal invalid (`validObservation`, future, > rewind window) | **Closed** (shot) | **Closed** (shot) | Honest clients never send these. |
| Colliders outside shooter cone/range | **Closed** (shot) | **Closed** (shot) | Shooter's own frame; no estimate needed. |
| `targetPlayerId` not on roster / self / disconnected / dead / protected | **Closed** (shot) | **Closed** (shot) | Already the rule; keep. |
| Victim pose stream stale (> poseAgeMs) at `capturedAtMs` | **Open**: apply, `shooterOnly` | **Open**: apply, `shooterOnly` | Hiding must never protect (§4.6a). |
| Victim anchoring available and contradicts | **Open**: apply, `disputed` | **Closed**: `identityMismatch` | Friend tier tolerates estimator error; verified tier has earned the right to refuse. |
| Centroid matches a *different* roster member, not the claimed one | **Closed**: `identityMismatch` | **Closed** | Positive evidence of misattribution; never redirect. |
| Two victims both consistent with the ray (DO's own estimate) | **Open**: apply to named victim, `disputed` | **Closed**: `ambiguousTarget` | Only the DO's evidence may call ambiguity; never a client's. |
| Client self-reports "multiple bodies visible" | Client may refrain from firing; DO ignores as evidence | Same | Self-report; a poisoner's tool otherwise. |
| NI/BLE bearing present | Ignored for verdicts; may be logged | Ignored for verdicts | Unverifiable, unavailable on part of the mix [E1–E3]. |
| Rate / entropy guard tripped | **Open**: apply, flag | **Closed** after threshold | Heuristic. |
| Transform estimate degrades mid-match | Demote pair to `shooterOnly`; adjudicated hits stand | Same | BIO-36 §11 rule. |
| Match-level: any identity uncertainty | **Never** pauses or blocks the match | Same | Denial must not have match-wide payoff. |

Principle: **fail closed on the shot only when the DO can state the failure in the shooter's own frame or on the DO's own estimate; fail open (apply + flag) whenever the only thing missing is corroboration; never fail closed on a client's self-report about ambiguity; never fail at match scope.**

## 8. Wire and code implications (for the implementer; not implemented here)

Sequenced so each step is independently shippable and testable in `packages/combat-simulation` without devices:

1. `combat-protocol`: add `attribution` to hit events; add `identityMismatch` refusal; keep `BodyObservation` shape (no new client fields needed for steps 1–4). [R1]
2. `combat-simulation`: replace `opponents.length !== 1` with roster/alive/protected checks on the named victim; add §5.3 cone/range/contemporaneity rules; tighten sighting age to `rewindMs`. [R2][R4]
3. `combat-simulation`: stop discarding pose-message observations in sighting mode; cap per tick. [R2]
4. `combat-simulation`: pair-transform estimator + `disputed`/`identityMismatch` logic behind a `rules.trustTier` field defaulting to friend. **[speculation-dependent — needs the BIO-36 §11 spike for thresholds]**
5. `convex`: raise `QUICK_DUEL_MAX_PLAYERS` to 4 only after 1–3 land. [R9]
6. iOS: lift `remote.count == 1`; the client must now choose a target — the honest client's best available heuristic is crosshair proximity among *its own* sightings, which is exactly what the DO's entropy guard later compares against. NI direction may be a tie-breaker hint on `supportsDirectionMeasurement` devices; it must be treated as optional and unverifiable. [R6][E2][E3]

Ownership per `AGENTS.md`: 1 is Integration (shared contracts), 2–4 Backend, 5 Backend, 6 iOS targeting.

## 9. Next spike (device evidence required before step 4)

- Two named devices, one LiDAR/one not: does the pair-transform residual from sightings alone fall below `BODY_ANCHOR_METERS` within a playable number of shots? (BIO-36 §11 protocol.)
- Three named devices in a 3 × 4 m room: how often does Vision's `max(by: score)` select the *wrong* body when two are within the crosshair cone? This determines how often honest clients produce `disputed` and therefore whether friend-tier fail-open is tolerable.
- NI direction availability with a person between two phones, on one `supportsDirectionMeasurement` pair — to close or confirm the §4.2 speculation.

## Sources

Repository (read 2026-09-27 at `main` = `3d89b7f82b218ef81b33858d1e3102c82a055785`; paths relative to repository root):

- [R1] `packages/combat-protocol/src/index.ts`, `validation.ts` — `LIMITS` (players 4, tickMs 50, poseAgeMs 100, rewindMs 250, clockUncertaintyMs 25, commandsPerSecond 60, commandsPerTick 64), `BodyObservation`, exact-key/range validation.
- [R2] `packages/combat-simulation/src/index.ts` — sighting fire path (`opponents.length !== 1` → `ambiguousTarget`; target-ID equality → `invalidInput`; age/confidence/uncertainty/colliders → `noSighting`), pose-observation discard in sighting mode, fire-ray anchoring to stored pose (0.5 m, ≈15°).
- [R3] `packages/combat-simulation/src/history.ts` — `MAX_SPEED = 15`, `POSITION_SLACK = 0.1`, 8π rad/s, `COVER_OBSERVATION_MS = 1_000`, `BODY_ANCHOR_METERS = 2`, `phoneAt`, `anchoredToPhone`, `bodyMovementValid`.
- [R4] `packages/combat-simulation/src/flight.ts` — `resolveSighting` sweeps the shooter's ray against shooter-supplied colliders; checks only target `health` and `protectedUntilMs`.
- [R5] `services/combat-worker/src/room.ts`, `connection.ts`, `auth.ts`, `store.ts` — ticket admission, fingerprint/sequence idempotency, token buckets (90 burst; NI bucket), 24 h idle retention, SQLite store; absence of attestation and of an attribution ledger.
- [R6] `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeBodyAssociation.swift` — `associateSighting` (single connected remote; `marginMeters = .infinity`), aligned-frame `associate` (0.45 m / 0.35 m), `fresh` (100 ms), min confidence 0.8.
- [R7] `ios/.../Features/Realtime/RealtimeArenaController.swift`, `Services/Realtime/CombatWire.swift` — sighting fire payload, constant `uncertaintyMeters = 0.08`, 50 ms pose pump.
- [R8] `ios/.../Targeting/TargetingSession.swift` — `ARBodyTrackingConfiguration` with Vision fallback; `detectPose` keeps `.max(by: score)` only.
- [R9] `convex/functions/combat.ts`, `matches.ts` — `QUICK_DUEL_MAX_PLAYERS = 2`, `QUICK_DUEL_FULL` at prepare and join.
- [R10] `ios/.../Targeting/NearbyInteraction/NearbyRendezvousModels.swift` — optional peer direction, ≤ 50 m distance, finite-vector validation (rendezvous path slated for removal).
- [R11] `docs/decisions/0013-quick-play-sighting-hits.md` — sighting geometry, 2-player cap, follow-up options (NI bearing; "only one visible body").
- [R12] `docs/research/client-evidence-threat-model.md`, `docs/research/zero-step-architecture-synthesis.md` §9–§11 (BIO-36) — inherited trust boundaries, tiers, corroboration model.

Primary documentation (accessed 2026-09-27):

- [E1] Apple, `NINearbyObject` — https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject ("If a session can't provide peer direction or distance, it sets the values to nil.")
- [E2] Apple, *Initiating and maintaining a session* (Nearby Interaction) — https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session (9 m, portrait, facing; narrow direction cone; people/walls break line of sight; nil semantics; capability checks).
- [E3] Apple, `NIDeviceCapability.supportsDirectionMeasurement` / `NISession.deviceCapabilities` — https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability/supportsdirectionmeasurement ; https://developer.apple.com/documentation/nearbyinteraction/nisession/devicecapabilities
- [E4] Apple, `ARBodyAnchor` — https://developer.apple.com/documentation/arkit/arbodyanchor ("tracks the movement of a single person").
- [E5] Apple, `ARFrame.detectedBody` — https://developer.apple.com/documentation/arkit/arframe/detectedbody (single optional `ARBody2D`).
- [E6] Apple, `NINearbyPeerConfiguration.isCameraAssistanceEnabled` — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled
- [E7] Apple, `VNDetectHumanBodyPoseRequest` / `VNDetectedPoint.confidence` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest ; https://developer.apple.com/documentation/vision/vndetectedpoint/confidence
- [E8] Cloudflare, *In-memory state in a Durable Object* — https://developers.cloudflare.com/durable-objects/reference/in-memory-state/ (state lost on eviction/hibernation; persist to storage).
- [E9] Cloudflare, *Durable Objects Alarms* — https://developers.cloudflare.com/durable-objects/api/alarms/ (one alarm per DO; at-least-once; schedule many events via storage).
- [E10] Apple, *Validating apps that connect to your server* (App Attest) — https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server (one-time challenge; assertion `counter`).

Academic / practitioner (inherited from BIO-36, not re-fetched):

- [P1] Slocum et al., *That Doesn't Go There: Attacks on Shared State in Multi-User Augmented Reality Applications*, USENIX Security 2024 — **[academic]**; taxonomy transfers, measurements do not.
- [P2] Gambetta, *Fast-Paced Multiplayer* series — **[practitioner]**; lag compensation and server reconciliation framing for the rewind window.

No practitioner source specific to multi-target identity in phone-AR combat was found; this is stated as an absence.
