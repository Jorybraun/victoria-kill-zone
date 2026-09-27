# Vision-only opponent identification for 2–4 player Quick Duel (BIO-37)

Status: research brief, not a decision — 2026-09-27. Tracks [BIO-37](https://linear.app/biossphere/issue/BIO-37). Read-only: no code, branch, commit, PR, deployment, ADR or device trial was produced. **Nothing in this document is physical-device evidence.** Companion provenance: [vision-opponent-identification.provenance.md](vision-opponent-identification.provenance.md).

Builds on — does not repeat — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) (BIO-36) and its seven briefs. BIO-36 settled *where combat authority lives* and *what a shot-evidence packet looks like*; this brief answers only the question BIO-36 and [ADR 0013](../decisions/0013-quick-play-sighting-hits.md) §8 left open: **with three opponents on the roster and a body under the crosshair, which one is it?** Shared-frame, map-linking, relocalization, rendezvous and collaborative-session material is out of scope by product decision (that machinery is being removed) and is not evaluated here.

Method: repository facts re-checked against `main` at `3d89b7f` (2026-09-27, clean tree); Apple primary documentation and WWDC transcripts for every Vision / ARKit / Nearby Interaction claim; practitioner or academic material only where Apple publishes nothing, and marked as such. Confidence vocabulary follows BIO-36 §1: **repo fact**, **platform fact** (Apple-documented), **inference**, **proposal**, **speculation**, **unmeasured** (physical behaviour nobody in this repo has measured).

## 1. The question, and its frozen constraints

- **Product:** Quick Duel is the only mode. Each phone runs its own AR frame; the match Durable Object is combat authority; a hit is the shooter's own camera observation of the victim (ADR 0013 §3–4). PLAY is never gated by any setup step. Roster cap 2–4 (AGENTS.md Phase 1 cap = 4).
- **Rule set that constrains identity mechanisms** (repo facts): the game is *markerless*; **"visible target markers"** are on the AGENTS.md do-not-add list; no persistent accounts. Camera frames stay on device (BIO-36 §5: the client sends evidence packets, never imagery) [22][24].
- **What the lobby already knows** (repo fact): Convex holds the roster — player IDs, host, ready state — and hands the Durable Object a `players` array. Identity therefore only needs to pick **one of at most three known IDs** (or refuse), never to recognise a stranger.
- **Why it is 2 players today** (repo fact, §2): the client attributes the observed body to "the only opponent"; with ≥ 2 opponents that attribution is undefined, so Convex refuses `sighting` rosters above 2 and the simulation returns `ambiguousTarget` [23][25].

The honest framing of the research question is therefore: *what evidence can one phone gather, on device, that separates opponent A from B and C, how often will that evidence be absent or ambiguous, and how should the client and authority behave when it is?*

## 2. Current repository behaviour (verified at `3d89b7f`) [25]

| Layer | File | What it does today | Consequence for 3–4 players |
|---|---|---|---|
| Vision | `ios/.../Targeting/TargetingSession.swift` | One `VNDetectHumanBodyPoseRequest` per ~0.1 s (`visionInterval = 0.1`), orientation `.right`; **all** returned observations are scored (`bodyConfidence·0.55 + min(1, area·4)·0.30 + crosshairProximity·0.15`) and **only the max is kept** | Other visible bodies are discarded every frame; no per-person track, no identity state |
| Association | `ios/.../Features/Realtime/RealtimeBodyAssociation.swift` | `associateSighting` filters `players` to remotes, `guard remote.count == 1`, returns that player with `confidence = observationConfidence`, `marginMeters = .infinity` | Returns `nil` for any roster with ≥ 2 opponents — identity is roster-based, not visual |
| Fire | `ios/.../Features/Realtime/RealtimeArenaController.swift` | Sighting fire sends camera ray + optional `BodyObservation{targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters: 0.08, colliders}` | `uncertaintyMeters` is a hard-coded constant, not a measurement |
| Wire | `packages/combat-protocol/src/index.ts` | `BodyObservation` above; `fire` carries `observation?: BodyObservation \| null` | No field exists for "candidate set", "margin" or "ambiguous" |
| Authority | `packages/combat-simulation/src/index.ts` | `opponents.length !== 1 → "ambiguousTarget"`; then `targetPlayerId` must equal that opponent; freshness ≤ `COVER_OBSERVATION_MS`, `associationConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`, `colliders.length > 0` | Authority validates *shape and roster membership*, never *whether the camera really saw that player* — it cannot, it has no imagery (BIO-36 §5 "confidence is a quality hint, not a trust input") |
| Lobby | `convex/functions/combat.ts` | `QUICK_DUEL_MAX_PLAYERS = 2`; `selectCombatGeometry` returns `sighting` for ≤ 2 | The cap is a deliberate refusal, not an oversight |

Two consequences drive everything below. **(a)** The client already sees every body Vision detects; the missing piece is a *multi-track, roster-aware chooser* plus a wire shape that can say "ambiguous". **(b)** The authority's `ambiguousTarget` refusal already exists as a code path; the 3–4 player design question is how to move the refusal from "roster > 2" to "this particular shot is ambiguous".

## 3. Candidate identity signals

Each mechanism is scored on: **What it yields** (platform fact), **Can it name a player?**, **Rule status** under markerless / no-visible-marker / on-device-only, and **Evidence status**.

### 3.1 Multi-person 2D body pose — `VNDetectHumanBodyPoseRequest` (already in use)

- **Platform facts:** returns "a unique observation for each detected human body pose" with 19 points and per-point confidence [1][2]. Apple's accuracy guidance: subject height ≥ ⅓ of image height, key regions visible, flowing clothing degrades detection, "dense crowd scenes is likely to produce inaccurate results" [2].
- **Names a player?** No. It yields *N anonymous skeletons per frame* with no cross-frame identity; observation `uuid`s are per-result, not per-person (inference from the API shape — Apple does not document any cross-frame identity for pose observations; stated as an absence).
- **Value here:** it is the *detector* that every other signal hangs off: it gives the bounding box for tracking (§3.3), the crosshair-intersection test, and the torso region for appearance sampling (§3.6). It also gives a body-height-in-image proxy for range, useful for ordering candidates by depth on non-LiDAR phones (inference).
- **Rule status:** allowed (already shipped). **Evidence:** multi-body return is documented [2]; recall/precision with 3–4 moving adults at 3–15 m outdoors is **unmeasured**.

### 3.2 Person segmentation — `VNGeneratePersonSegmentationRequest`, `VNGeneratePersonInstanceMaskRequest`, ARKit `personSegmentationWithDepth`

- **Platform facts:** the semantic request "produces a matte image for a person it finds" — one mask for *all* people, with a `qualityLevel` speed/accuracy knob [3]. The instance request (iOS 17) "produces a mask of individual people" as a `VNInstanceMaskObservation` with `allInstances`; Apple's sample "generates segmented masks for up to four individuals … one mask for everyone if more than four" [4][5][6]. ARKit's `personSegmentationWithDepth` frame semantic yields a per-pixel segmentation buffer plus estimated depth for people occlusion; in WWDC19 Apple states the buffers are generated by ML from the camera image on A12-class silicon at camera cadence [7][8].
- **Names a player?** No. Segmentation answers *where person pixels are*, not *who*. Its uses for identity are indirect: (i) a cleaner pixel region than a skeleton bounding box for appearance sampling (§3.6); (ii) an occlusion test — if the crosshair pixel is not inside any person mask, refuse the shot; (iii) with ARKit's estimated depth, a **depth order** for overlapping bodies, which is the one signal that resolves "who is in front" during a crossing (inference).
- **Cost caveat:** instance masking is documented on still images and the sample is limited to four instances [5]; Apple publishes **no latency figure** for running it per frame alongside body pose on iOS 17 devices — stated as an absence. The semantic request's `qualityLevel` exists precisely because the accurate level is expensive [3] (inference on why the knob exists).
- **Rule status:** allowed. **Evidence:** API surface documented; real-time cost with body pose concurrently running is **unmeasured**.

### 3.3 Temporal tracking — `VNTrackObjectRequest` and hand-rolled association

- **Platform facts:** `VNTrackObjectRequest` "tracks the movement of a previously identified object across multiple images or video frames" [9]; it is seeded from a `VNDetectedObjectObservation` bounding box, run through `VNSequenceRequestHandler`, "a single tracking request represents a single tracked object in a one-to-one relationship", has a `trackingLevel` speed/accuracy setting, and Apple's guidance is to *re-seed from a fresh detector every ~10 frames* because trackers drift and miss newcomers [10][11]. The sample identifies tracked objects by the seed `uuid` and draws low-confidence (< 0.5) results dashed [10].
- **Names a player?** Not by itself — it preserves *"this box is the same box I seeded"* over short horizons. It is the mechanism that carries an identity decision made once (§3.6–3.8) forward through frames where the discriminating evidence is momentarily absent.
- **Known limits (inference, consistent with Apple's re-seed guidance [10]):** bounding-box trackers are appearance/motion correlators; when two similar boxes overlap and separate (players crossing), the tracker may follow the wrong one with *high* reported confidence — the confidence value measures track quality, not identity correctness. Apple documents no behaviour for occlusion or crossing; absence stated.
- **Alternative (proposal):** since body pose already runs at 10 Hz, a lightweight nearest-neighbour association on skeleton root position + image height (a Hungarian assignment or greedy IoU) may suffice and avoids a second Vision pipeline; `VNTrackObjectRequest` is then optional. Which is cheaper on A12–A17 is **unmeasured**.
- **Rule status:** allowed. **Evidence:** documented as an object tracker; identity persistence through crossings is **unmeasured and undocumented**.

### 3.4 3D body pose — `VNDetectHumanBodyPose3DRequest`

- **Platform facts:** iOS 17 request returning a 17-joint `VNHumanBodyPose3DObservation` with positions **in metres relative to the camera**, `bodyHeight` (measured with depth metadata, else a 1.8 m reference), and `cameraOriginMatrix`; **"this initial revision returns one skeleton for the most prominent person detected in the frame"** [12][13][14].
- **Names a player?** No, and — decisively for this brief — it **cannot even enumerate** the three opponents: one skeleton per frame. It is useful only for the *selected* candidate, to estimate range in metres on non-LiDAR phones (with the 1.8 m default-height caveat) for cross-checking against a peer-reported or UWB range (§3.9).
- **Rule status:** allowed. **Evidence:** single-person limit is an Apple statement [14]; its per-frame latency on iOS 17 devices is **unmeasured** (Apple's session frames it as a photo-library use case; no live-video figure is given — absence).

### 3.5 ARKit body tracking — `ARBodyTrackingConfiguration`, `ARBodyAnchor`, `ARFrame.detectedBody`

- **Platform facts:** `ARBodyTrackingConfiguration` "tracks human body poses" with the rear camera and creates an `ARBodyAnchor` whose `skeleton: ARSkeleton3D` and `estimatedScaleFactor` describe the body in world space; body detection is on by default; `ARFrame.detectedBody` (`ARBody2D`) gives screen-space joints for "a person ARKit recognizes" [15][16][17]. Apple documents `detectedBody` as a singular property [16][17].
- **Names a player?** No. The API surface exposes *a* detected body, not a set (absence: Apple does not document multi-body tracking for this configuration; the singular `detectedBody` and the motion-capture framing imply one). Running `ARBodyTrackingConfiguration` would also replace the current `ARWorldTrackingConfiguration` session that supplies the camera ray and, today, coexists with Vision; whether world tracking quality, people occlusion and body tracking can all be held together on the current session is **unmeasured** and partly undocumented.
- **Value here:** a world-space `ARBodyAnchor` for the selected target would give a metre-scale position without LiDAR, the same role as §3.4. Not a discriminator between opponents.
- **Rule status:** allowed. **Evidence:** documented single-body surface; not a multi-opponent solution.

### 3.6 Appearance re-identification — clothing colour, torso histograms, team colours

- **What it is:** at match start (or on the first unambiguous sighting) sample the torso pixels of each opponent and keep a per-player colour descriptor for the session; at fire time compare the crosshair body's descriptor to the three stored ones. Nothing is worn or added — it reads what players already wear.
- **Rule status — allowed, with a bright line (inference from AGENTS.md wording):** *passive* appearance is markerless: no marker is added to the world, nothing is "visible target marker" the rule forbids. *Assigned team colours* ("red team wear red") cross the line into a required visible marker and also fail zero-setup; they are **not recommended**. Practitioner note: RealTag-style AR shooters ship a form of colour association [P1], marked as practitioner, no accuracy figure.
- **Where the descriptor comes from (proposal):** the only zero-setup enrolment is *self-bootstrapping* — the first sighting in which exactly one body is visible **and** only one opponent is plausible (e.g. 2-player match, or the other opponents are known-dead/known-far) labels that body. Before any such event, the descriptor set is empty and the mechanism contributes nothing. This makes appearance a **session-local memory**, never an a-priori identity.
- **Failure modes (inference, well known in the re-identification literature — practitioner/academic level, no on-device number):** similar clothing (two players in dark jackets) collapses separation to zero; illumination change (sun/shade, backlight) shifts colour; partial views (torso occluded, back vs front of a jacket) sample different surfaces; auto-exposure/white-balance changes between frames; and any descriptor computed from a skeleton box rather than a segmentation mask mixes in background. Identity confidence from appearance must therefore be *the margin between best and second-best match*, not the best match score.
- **Privacy:** a torso colour histogram is not biometric data and is discarded at match end (proposal). It is the least privacy-sensitive appearance signal available.
- **Evidence:** entirely **unmeasured** in this repo; there is no Apple API for it (absence) — it is ~50 lines of pixel sampling over a Vision mask/box.

### 3.7 Phone-screen flash or glow as a beacon

- **What it is:** the target's phone, which the shooter is roughly aiming at, briefly shows a per-player colour (or a coded blink) on its screen; the shooter's camera looks for that colour near the detected body's wrist/hand joints.
- **Rule status — the judgement call this brief cannot make alone (inference):** the phone is *already* held by every player, so no *new* object is worn; but an emitted, intentionally distinctive light whose only purpose is to be seen by the enemy camera **is functionally a visible target marker**, which AGENTS.md lists under "do not add". It is also detectable by the opposing player's *eyes*, changing gameplay (a beacon reveals your position through partial cover). A *steady* dim tint is less of a give-away than a flash, but the argument does not change. **Verdict: treat as requiring an explicit product-owner acceptance that it does not violate the markerless rule; do not design around it by default.**
- **Technical caveats (inference, unmeasured):** outdoor daylight screens are low-contrast targets at 3–15 m; the hand joint is small in the image; auto-exposure on the shooter's phone is set for the scene, not the screen; the rear camera typically sees the *back* of the target's phone, not the display, when the target aims back — the beacon is visible mainly when the target is *not* aiming at you.
- **Evidence:** none. **Speculation** that it works at range at all.

### 3.8 Face recognition

- **Platform facts:** Vision offers face *detection* (`VNDetectFaceRectanglesRequest` → bounding boxes) and landmarks [18]; Apple publishes **no face-identity/recognition API** in Vision (absence, verified against the Vision request catalogue).
- **Assessment:** implementing recognition would mean shipping or training a face-embedding model and storing per-player face templates — biometric data — for a game with **no persistent accounts** (AGENTS.md). Storing face templates of co-players, even session-locally, is the highest-privacy-risk option on this list and, depending on jurisdiction, may trigger biometric-consent law (inference; not legal advice, no statute verified here). It also fails technically at the ranges in play: faces at 8–15 m are a few dozen pixels (inference from geometry). **Rejected.**

### 3.9 Non-camera corroboration: Nearby Interaction bearing (optional, never a gate)

Not a vision mechanism, but the one signal that can *independently* name a player, so it is scored here for completeness and because ADR 0013 §8 already names it.

- **Platform facts:** `NINearbyObject` for a peer provides `distance` and a `direction` vector when available, "if a session can't provide peer direction or distance, it sets the values to nil"; camera assistance (`isCameraAssistanceEnabled`, iOS 16) combines ARKit 6-DoF with UWB to give `distance`/`direction`/`horizontalAngle` "in a wider range of environmental conditions" [19][20]. BIO-36's frame brief already cites the ~9 m best-operation envelope and ~5 Hz update rate [21] — not repeated here.
- **Names a player?** **Yes** — the NI peer *is* a roster member by construction. Comparing the crosshair body's image bearing against each peer's UWB bearing is a direct three-way disambiguator when direction is available.
- **Rule status:** allowed *only* as an opportunistic input: it needs UWB on both phones, ~9 m, roughly facing back cameras; the repo's `NearbySessionManager` and rendezvous policy exist but belong to the machinery being removed as a *gate*. Reusing per-peer `NISession` purely as a fire-time bearing hint, silently absent on non-UWB phones, does not contradict "PLAY is never gated" (inference). Whether the owner wants to keep *any* NI code is an open decision (§8).
- **Evidence:** documented API; bearing accuracy between two moving phones outdoors is **unmeasured** (BIO-36 noted Apple hints camera assist favours stationary targets).

### 3.10 Roster-aware elimination (free, and the strongest single signal)

The authority already knows, per player, `alive`, `connected`, shield state, and each phone's own pose stream (BIO-36 R1/R2 evidence ladder). Inference: the candidate set at fire time is not "3 opponents" but "opponents who are alive, connected and whose *own* phone reports a camera pose broadly consistent with being in front of the shooter". In a 4-player match where one opponent is dead and one has reported itself 20 m away, one visible body is unambiguous *without any vision identity at all*. This is the direct generalisation of today's `remote.count == 1` rule and costs nothing on the camera. It requires the client to receive (it already does — `players` is in the snapshot) and use per-opponent state, and it depends on the trustworthiness of the *other* phones' self-reports, which BIO-36 §5 already classifies as R1 (self-reported, spoofable) evidence.

## 4. Capability / latency / accuracy matrix — iOS 17 device classes

Rows are device *classes* the roster may mix, not models. **Every latency and accuracy cell is unmeasured**; the matrix records what Apple documents as *available* and what the repo can *honestly claim*. Empty means "no source found" (absence), not "unsupported".

| Signal | Non-LiDAR, no UWB (e.g. SE-class, XR-class) | Non-LiDAR + UWB (iPhone 11-class and later non-Pro) | LiDAR + UWB (Pro-class, iPhone 12 Pro and later) | Documented latency | Documented identity accuracy |
|---|---|---|---|---|---|
| 2D body pose, multi-person [1][2] | Yes | Yes | Yes | none published; repo runs at 10 Hz by choice | n/a — anonymous skeletons |
| Person semantic mask [3] / ARKit people-occlusion buffers [7][8] | Yes (A12+ per WWDC19 for ARKit buffers) | Yes | Yes (LiDAR may improve depth; not documented for this buffer — absence) | ARKit buffers "at camera cadence" on A12 [8]; Vision request: none published | n/a |
| Person *instance* mask [4][5] | iOS 17 | iOS 17 | iOS 17 | none published; still-image sample only | n/a; ≤ 4 instances [5] |
| 3D body pose [12][14] | Yes, 1.8 m reference height | Yes, 1.8 m reference | Yes; depth metadata improves `bodyHeight` [13] | none published | single most-prominent person only [14] |
| ARKit body tracking [15] | A12+ | Yes | Yes | frame-rate coupled; not published separately | single detected body surface [16] |
| Object tracking [9][10] | Yes | Yes | Yes | none published; `trackingLevel` knob | n/a — track quality ≠ identity |
| Appearance descriptor (§3.6) | Yes (custom) | Yes | Yes (mask-cleaned) | trivial vs. the above (inference) | **unmeasured**; degenerate under similar clothing |
| NI bearing (§3.9) | **No** | Yes, pairwise UWB peers only | Yes | ~5 Hz [21] | direction may be `nil` [19]; accuracy unmeasured outdoors |
| Range-in-metres for the chosen target | image-height proxy only | image-height proxy; UWB `distance` when a peer | ARKit depth / LiDAR scene depth; UWB | — | — |
| Roster elimination (§3.10) | Yes | Yes | Yes | network RTT only | depends on peers' honesty (R1) |

Reading the matrix: **the only cell that changes with hardware is bearing/range corroboration.** Every purely visual signal is available on every iOS 17 phone the game supports; therefore the *identity algorithm must be the same on all phones*, with UWB/LiDAR only raising confidence when present. That is consistent with the zero-setup, no-gate requirement and with BIO-36's "R0 body-only is always available" floor.

## 5. Failure modes

| Failure | What happens to identity | Detectable on device? | Honest client behaviour (proposal) |
|---|---|---|---|
| **Occlusion** (target behind cover, another player, a tree) | Skeleton/mask disappears or is partial; Apple warns partial key regions degrade pose [2] | Yes: fewer joints, low confidence, mask absent at crosshair | No observation → no shot (ADR 0013 §4 already) |
| **Players crossing** | Two tracks overlap then separate; trackers may swap [inference from [10]]; appearance descriptors of similar clothing cannot re-split them | Partially: bounding-box IoU > threshold is observable; depth order from people-occlusion depth or 3D pose can say who is in front | Mark both tracks *identity-unstable* for a cool-down; fire attempts during/after a crossing carry reduced confidence or `ambiguous` until a non-visual signal (bearing, roster) re-labels |
| **Similar clothing** | Appearance margin → 0 | Yes: margin is computed | Fall back to tracking continuity + roster elimination; if still ≥ 2 plausible → refuse |
| **Bystander** | An anonymous body that matches no descriptor and no peer bearing | Only when descriptors/bearings exist; a fresh session cannot tell a bystander from an unenrolled opponent | Never attribute a body to a player by elimination alone unless the roster leaves exactly one *alive, connected, plausibly-in-view* candidate (§3.10) |
| **Partial body / extreme close range** | Height > frame; joints missing | Yes | Crosshair-inside-mask test still valid; identity from track continuity |
| **Motion blur / fast pan** | Detection drops for a few frames; tracker drifts | Yes: detection gap length | Keep identity through short gaps (≤ N frames, proposal N tuned on device), then demote |
| **Lighting** (backlight, dusk, shade transitions) | Colour descriptors shift; detection recall drops | Partly (exposure metadata) | Re-sample descriptors on each *unambiguous* sighting; never on ambiguous ones |
| **Camera framing** (subject < ⅓ frame height) | Apple's stated accuracy floor [2] | Yes: bounding box height | Treat < ⅓ height as low observability |
| **Track loss / re-acquisition** | New anonymous track appears | Yes | New track starts *unlabelled*; it inherits an identity only from evidence, never from "the label that was nearby" |
| **Vision vs ARKit disagreement** (different body counts) | Two detectors, two answers | Yes, if both run | Prefer the detector that owns the crosshair test; log disagreement as a device-evidence metric |
| **No / sparse depth** (non-LiDAR) | No depth order during overlap | Yes (device class) | Crossing rule above degrades to "refuse until separated" |
| **Spoofed peer self-reports** | Roster elimination mislabels | No (server-side R1 issue, BIO-36 §5) | Authority treats elimination-only identity as weaker than identity with a camera-side margin |
| **Consent / privacy** | Face templates or imagery leaving the device | Policy, not runtime | §3.8 rejected; §3.6 descriptors are session-local and non-biometric |

## 6. What confidence a client can honestly attach

BIO-36 §5 already fixed the principle — client confidence is a *quality hint*, never a trust input; the authority validates shape, freshness, roster membership and game state, and cannot prove what the camera saw. This brief adds the *content* of that hint for identity. **Proposal**, not measured:

1. **Report a candidate set, not a scalar.** Extend `BodyObservation` (integration-owned contract; change would need an ADR) with something like:
   ```ts
   identity: {
     targetPlayerId: string | null;          // null == ambiguous, shot refused client-side or by authority
     candidates: { playerId: string; score: number }[];   // all alive opponents considered
     margin: number;                          // best − second best, 0..1
     basis: ("rosterOnly" | "trackContinuity" | "appearance" | "bearing" | "depthOrder")[];
     trackAgeMs: number;                      // how long this track has carried this label
     observability: number;                   // joint confidence × frame-height factor, 0..1
   }
   ```
   The authority's `ambiguousTarget` becomes: `targetPlayerId == null`, or `margin` below a policy floor, or `basis == ["rosterOnly"]` while more than one roster candidate is alive and connected.
2. **Confidence is the margin, not the best score.** A 0.9 appearance match against a 0.88 second-best is *ambiguous*; the current `associationConfidence ≥ 0.8` scalar cannot express that.
3. **Label provenance matters.** A label carried purely by tracking for 4 s through a crossing is weaker than one refreshed by bearing 200 ms ago; `basis` and `trackAgeMs` let the authority (and later, replay analysis) weight it — or simply refuse `trackContinuity`-only labels older than a policy horizon.
4. **Refuse rather than guess.** When exactly one candidate survives roster elimination *and* the visual evidence does not contradict it, the honest confidence is "unambiguous by roster" (today's 2-player case, generalised). When two or more survive and no visual/bearing signal separates them past the margin floor, the honest answer is *ambiguous* and the shot should be a miss with explicit `ambiguousTarget` feedback so the player learns to separate targets.
5. **Never present precision the client does not have.** `uncertaintyMeters: 0.08` today is a constant; for identity, the analogous sin would be a fixed `associationConfidence` for a roster-elimination label. Whatever number is sent should be derived per shot from the fields above.
6. **The authority's ceiling.** Even with all of this, the server can only check *internal consistency* (candidate IDs ⊆ alive roster; margin/basis coherent; freshness; the claimed target's own pose stream not wildly inconsistent with being in front of the shooter — R1). A modified client can still assert any label. Identity confidence is therefore a **fairness** mechanism among honest clients, not an anti-cheat one — which is exactly BIO-36's threat-model conclusion and is restated here so nobody reads "confidence" as proof.

## 7. Recommendation

Verdicts are recommendations pending the §9 device evidence.

1. **Ship 3–4 player `sighting` on roster-aware elimination first** (§3.10). Generalise `remote.count == 1` to "exactly one alive, connected, plausibly-in-view opponent"; keep `ambiguousTarget` otherwise; lift `QUICK_DUEL_MAX_PLAYERS` to 4. Zero new camera work, zero setup, playable immediately, and it turns the ADR 0013 §8 "interim candidate" into the floor. Many 3–4 player situations (late-round, spread-out play) already resolve here.
2. **Add per-person tracks and a candidate-set wire shape** (§3.3 hand-rolled association on the existing 10 Hz pose stream; `VNTrackObjectRequest` only if device evidence shows the simple association loses tracks). This is the prerequisite for every visual signal and for honest margins; it is also where the *refuse-on-crossing* rule lives.
3. **Add passive appearance descriptors as session-local memory** (§3.6), bootstrapped only from unambiguous sightings, sampled from a person mask when available and a skeleton torso box otherwise; use the *margin* as the confidence. Never assign team colours; never require anything worn.
4. **Use NI bearing opportunistically** (§3.9) when both phones have UWB and a peer session exists — as a fire-time label refresh, absent silently otherwise, never a PLAY gate. If the owner decides to delete all NI code with the shared-frame removal, drop this item; the rest stands.
5. **Reject** face recognition (§3.8) outright and **do not design around** the screen beacon (§3.7) unless the product owner explicitly rules it is not a "visible target marker".
6. **Do not adopt** `VNDetectHumanBodyPose3DRequest` or `ARBodyTrackingConfiguration` as identity mechanisms — both are documented as single-body surfaces [14][16]; consider 3D pose only later for range on non-LiDAR phones.
7. **Segmentation** is worth adding only if device evidence shows (a) the appearance descriptor from a skeleton box is too noisy, or (b) depth-ordered crossings matter often enough — it is the most expensive component and Apple publishes no per-frame cost.

## 8. Open decisions (owner / integration)

1. Is a phone-screen glow/flash a "visible target marker"? (Decides §3.7 for good.)
2. Does *any* Nearby Interaction code survive the shared-frame removal, even as an optional bearing hint? (Decides §3.9.)
3. Contract change: `BodyObservation` gains an identity/candidate block (integration-owned; needs an ADR successor to 0013 §8).
4. Fallback UX for `ambiguousTarget` in 3–4 player play: silent miss, HUD hint ("targets overlapping"), or a per-target reticle colour that only appears when identity is unambiguous.
5. Policy floors — `margin`, max `trackContinuity` label age, crossing cool-down — are all **to be set from device data**, not chosen in code review.

## 9. Physical-device evidence this brief cannot supply

None of the following exists in the repo or in Apple documentation; each must be measured on named devices per AGENTS.md before any item in §7 is called done.

1. Multi-body pose recall/precision at 3, 8, 15 m, 3–4 adults, daylight and dusk, on at least one non-LiDAR/non-UWB, one UWB-only and one LiDAR+UWB iPhone.
2. Per-frame cost and thermal behaviour of body pose alone vs. pose + semantic mask vs. pose + instance mask, at 10 Hz and at camera cadence.
3. Identity-swap rate through deliberate crossings (two players walk through each other at 5 m; count label swaps per 20 crossings) with tracking-only, tracking + appearance, and tracking + appearance + bearing.
4. Appearance margin distribution for "similar clothing" (all players in dark tops) vs. "distinct clothing".
5. NI `direction` availability rate and angular error between two *moving* UWB phones outdoors.
6. Bystander false-attribution rate with a non-player walking through the arena.
7. Whether `ARBodyTrackingConfiguration` can coexist with the current session without degrading the camera ray — only if §3.5 is ever revisited.

## Sources

Primary (Apple) unless marked. All accessed 2026-09-27.

1. Apple — `VNDetectHumanBodyPoseRequest` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest
2. Apple — Detecting Human Body Poses in Images (multiple observations per request; accuracy guidance: ⅓ frame height, flowing clothing, dense crowds) — https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images
3. Apple — `VNGeneratePersonSegmentationRequest` (single matte for people; `qualityLevel`) — https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest
4. Apple — `VNGeneratePersonInstanceMaskRequest` — https://developer.apple.com/documentation/vision/vngeneratepersoninstancemaskrequest
5. Apple — Segmenting and colorizing individuals from a surrounding scene (iOS 17; up to four instances, else one mask; physical device required) — https://developer.apple.com/documentation/vision/segmenting-and-colorizing-individuals-from-a-surrounding-scene
6. Apple — `VNInstanceMaskObservation` (`allInstances`, `generateMask(forInstances:)`) — https://developer.apple.com/documentation/vision/vninstancemaskobservation
7. Apple — `ARConfiguration.FrameSemantics.personSegmentationWithDepth` — https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/personsegmentationwithdepth
8. Apple — WWDC19 session 607, Bringing People into AR (segmentation + estimated depth buffers from ML on A12, at camera cadence) — https://developer.apple.com/videos/play/wwdc2019/607/
9. Apple — `VNTrackObjectRequest` — https://developer.apple.com/documentation/vision/vntrackobjectrequest
10. Apple — Tracking Multiple Objects or Rectangles in Video (one request per object; seed quality; re-nominate every ~10 frames; confidence < 0.5 shown dashed) — https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video
11. Apple — `VNTrackingRequest.trackingLevel` — https://developer.apple.com/documentation/vision/vntrackingrequest/trackinglevel
12. Apple — `VNDetectHumanBodyPose3DRequest` — https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest
13. Apple — `VNHumanBodyPose3DObservation` (`bodyHeight`, `cameraOriginMatrix`, `heightEstimation`) — https://developer.apple.com/documentation/vision/vnhumanbodypose3dobservation
14. Apple — WWDC23 session 111241, Explore 3D body pose and person segmentation in Vision ("this initial revision returns one skeleton for the most prominent person"; 1.8 m reference height without depth; instance masks for up to four people) — https://developer.apple.com/videos/play/wwdc2023/111241/
15. Apple — `ARBodyTrackingConfiguration` — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration
16. Apple — `ARFrame.detectedBody` — https://developer.apple.com/documentation/arkit/arframe/detectedbody
17. Apple — `ARBodyAnchor` (`skeleton`, `estimatedScaleFactor`) and `ARBody2D` — https://developer.apple.com/documentation/arkit/arbodyanchor , https://developer.apple.com/documentation/arkit/arbody2d
18. Apple — `VNDetectFaceRectanglesRequest` (detection only; Vision publishes no face-identity request — absence) — https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest
19. Apple — `NINearbyObject` (distance/direction may be `nil`) — https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject
20. Apple — `NINearbyPeerConfiguration.isCameraAssistanceEnabled` — https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled
21. In-repo — [shared-arena-frame-options.md](shared-arena-frame-options.md) §4 Option C and sources 22–26 (UWB ~9 m envelope, ~5 Hz, camera-assist caveats); not re-derived here.
22. In-repo — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) (BIO-36: evidence ladder R0–R3, confidence-as-hint principle, threat model).
23. In-repo — [docs/decisions/0013-quick-play-sighting-hits.md](../decisions/0013-quick-play-sighting-hits.md) §5 (cap 2), §8 (identity follow-up candidates), Risks (bystander).
24. In-repo — `AGENTS.md` (markerless; "visible target markers" prohibited; Phase 1 cap 4; physical-device evidence rule).
25. In-repo code at `3d89b7f` — `TargetingSession.swift`, `RealtimeBodyAssociation.swift`, `RealtimeArenaController.swift`, `packages/combat-protocol/src/index.ts`, `packages/combat-simulation/src/index.ts`, `convex/functions/combat.ts` (§2 table).

Practitioner (marked):

- P1. RealTag AR laser-tag shooter — referenced via ADR 0013 Risks ("the RealTag bystander bug"); its colour/body association approach is known only from product descriptions, not documentation; no accuracy figure. Used solely as an existence proof that passive appearance association ships in this genre.

Absences (searched, not found, not converted into claims): Apple per-frame latency for any Vision request on any iPhone; Apple accuracy figures for multi-person pose, instance masks or object tracking; Apple documentation of `VNTrackObjectRequest` behaviour under occlusion/crossing; Apple documentation of multi-body `ARBodyTrackingConfiguration`; a specific App Review guideline clause on face templates (not verified in this round); any academic benchmark of person re-identification on iPhone-class hardware outdoors at 3–15 m.
