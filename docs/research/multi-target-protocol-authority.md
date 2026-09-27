# Multi-target hit attribution for Quick Duel: protocol, authority, ledger (BIO-37)

Status: Research complete — 2026-09-27. Design only; nothing here is implemented. Builds on — does not repeat — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) and its seven BIO-36 briefs, and applies the product decisions recorded in that ticket's brief: the shared-frame / Saved Arena concept (ADR 0010/0011/0012 paths, `SharedArena`/`DuelFrame` code) is being removed; Quick Duel (ADR 0013 `sighting` geometry, each phone in its own AR frame, the match Durable Object as combat authority) is the only play mode; start is never gated by a setup step; the owner wants 2–4 players. Nothing in this document is physical-device evidence: the build-log records no completed two-phone `sighting` match [R9], and no 3–4-player trial of any kind.
Method: one repository audit of `packages/combat-protocol` (types + exact-key validation), `packages/combat-simulation` (`control`, `resolveSighting`, `resolveFlights`, body/phone history), `services/combat-worker` (`CombatRoom`, `Store`, `BulletLedger`, `report`), Convex geometry selection, the iOS targeting → association → fire path, and the existing `verdict-ledger.v1` contract; one primary-doc pass (Apple Vision/ARKit, Cloudflare Durable Objects); then the design. Repository claims cite file paths and line numbers as of `main` at the audit date (R-sources); external claims carry numbered sources (S-sources). Speculation is marked **[speculation]**; absences are stated as absences.

## 1. The question

In `sighting` geometry a hit is the shooter's own camera observation of a body. With one opponent that body *is* the opponent, so the protocol carries a single `targetPlayerId`. With two or three opponents the camera cannot say which person it saw. Design how the `fire` command and the Durable Object attribute a hit to one of several opponents — candidate lists with per-candidate confidence, an ambiguity policy, cross-corroboration from the targets' own streams, mutual sightings, deterministic tie-breaks, replay compatibility, message bounds — such that 2-player is the same rule with one candidate, and define the verdict-ledger fields a dispute needs.

## 2. What the repository does today (confirmed)

Every claim in this section was read from source on `main`; none is inferred.

### 2.1 Wire contract (`packages/combat-protocol`)

- `PROTOCOL_VERSION = 1`. `LIMITS`: `players = 4`, `messageBytes = 16_384` (client→server), `serverMessageBytes = 131_072`, `commandsPerSecond = 60`, `commandsPerTick = 64`, `commandHistory = 512`, `eventHistory = 1024`, `projectiles = 128` [R1].
- `BodyObservation = {targetPlayerId, capturedAtMs, associationConfidence, uncertaintyMeters, colliders: BodyCollider[]}`; `BodyCollider` is a sphere `{id, kind, zone, center, radius}` or capsule `{id, kind, zone, a, b, radius}` [R1 L22–31].
- `fire = {kind, shotId, poseSequence, origin, direction, observation?: BodyObservation | null}` — **exactly one** optional observation [R1].
- `projectileTerminal` carries one `targetPlayerId`, one `zone`, one `damage`; `reason ∈ {bodyHit, shieldBlocked, missExpired, cancelled}`. Refusal reasons include `noSighting` and `ambiguousTarget` [R1 L115].
- Validation is **exact-key**: `fire` must have exactly the key set `kind shotId poseSequence origin direction` or that set plus `observation`; an observation must have exactly `targetPlayerId capturedAtMs associationConfidence uncertaintyMeters colliders`, with 1–32 colliders; unknown keys are rejected [R2]. Consequence: any new field is a protocol change that must land in the validator before any client emits it, or every such `fire` is refused as `invalidInput`.

### 2.2 Authority verdict (`packages/combat-simulation`)

- `CombatSimulation.control`, `fire` branch, `sighting` geometry [R3 L279–300]:
  ```ts
  const opponents = players.filter(other => other.playerId !== p.playerId);
  if (opponents.length !== 1) return "ambiguousTarget";
  ... if (observation.targetPlayerId !== opponents[0]!.playerId) return "invalidInput";
  if (observation.capturedAtMs > this.now) return "futureInput";
  if (this.now - observation.capturedAtMs > COVER_OBSERVATION_MS /*1000*/ || observation.associationConfidence < 0.8
    || observation.uncertaintyMeters > 0.1 || observation.colliders.length === 0) return "noSighting";
  ```
  Then the projectile is spawned and `resolveSighting` runs immediately; the projectile never enters the live list.
- `resolveSighting` sweeps the shooter's ray against every supplied collider, picks the nearest by ray parameter, checks target alive / protected, applies `shieldBlocked` or `bodyHit` with zone damage — all in the shooter's own camera space, no shared frame, no rewind [R4]. **The authority never asks "which player"; the client already answered.**
- In `sighting`, pose commands' `observations` are discarded (`this.sighting ? [] : e.command.observations`) [R3 L160], so the `BodyHistory` / `coverObserved` / `anchoredToPhone` machinery [R5] is **inactive** in the only shipping geometry. There is no server-held record of who saw whom other than the fire command itself.
- Deterministic precedent: `resolveFlights` collects impacts across all players and sorts by `atMs || projectileId || distance || shield-first || targetId || zone`, applying only the first valid impact per projectile [R4 L167]. Commands within a tick are ordered `sentAtMs || playerId || clientSequence` [R3 L12]; players are stored sorted by `playerId` [R3 L27]. Every existing tie-break is total and string-comparable, which is the property the design below must keep.
- Checkpoint validation is versioned (`version === 1`) and bounds histories (`phones ≤ 4`, `bodies ≤ 12`, `samples ≤ 16`) [R6]. Adding server-side state for attribution therefore either fits inside existing bounded structures or bumps the checkpoint version.

### 2.3 Durable Object (`services/combat-worker`)

- `CombatRoom.admitCommand` fingerprints, dedupes (`UNIQUE(player_id, command_id)`), checks epoch/sequence/rate, queues; `tick` forks the simulation, advances, commits `{room, events, commands, members}` in one `transactionSync`, `storage.sync()`, then broadcasts and acks [R7][R8]. The Worker holds **no target-selection policy**; attribution is whatever `CombatSimulation` emits.
- `Store` tables: `room`, `members`, `commands(player_id, client_sequence, command_id, fingerprint, event_sequence, result_json)`, `events(sequence, payload)`, plus `shared_maps`/`map_chunks` (shared-frame residue slated for removal) [R8 L40–65]. `commands` is pruned to `LIMITS.commandHistory = 512` rows and `events` to 1024 [R8 L110–132] — the durable record of *why* a shot resolved as it did is therefore lost after ~512 commands, i.e. well inside a single match at 60 commands/s.
- `BulletLedger` stores projectile rows and spawn/segment/terminal payloads with shot and segment bounds; it stores no observation, candidate, confidence, or corroboration data [R10].
- `report.ts` pins version manifests, epochs and a player transcript into devin-report issues; nothing per-shot [R11].
- Cloudflare limits that bound the design: each Object is single-threaded; SQLite row/BLOB ≤ 2 MB, statement ≤ 100 KB, ≤ 100 bound parameters, ≤ 100 columns per table; received WebSocket message ≤ 32 MiB (the repository's own 16 KiB is the operative bound) [S1].

### 2.4 Lobby (`convex`)

- `QUICK_DUEL_MAX_PLAYERS = 2`; `selectCombatGeometry` promotes `phoneProxy` to `sighting` only when roster ≤ 2 and never downgrades `sighting`; `prepare` throws `QUICK_DUEL_FULL` when `sighting && players.length > 2` [R12 L27–57]. `interface-contracts.md` states the same: `maxPlayers` forced to 2, third join fails [R13 L704].
- Roster in the combat ticket is `{playerId, displayName, role}`; the `players` table has **no colour, appearance, or team field** [R12 L86–89][R14]. Absence: there is nothing the camera could use to tell players apart by appearance, and nothing in the data model to hold such a thing.

### 2.5 iOS targeting → association → fire

- `TargetingSession` runs `VNDetectHumanBodyPoseRequest`; when several bodies are returned it scores each (`bodyConfidence·0.55 + min(1, area·4)·0.30 + crosshairProximity·0.15`) and keeps **only the maximum**; extra bodies are discarded with no count, track id, or ambiguity signal to the caller [R15 L1169–1174, L1253–1258]. `TargetingSkeleton` carries `joints, bones, capturedAt` and no identity [R15 L268–276]. On devices where `ARBodyTrackingConfiguration.isSupported`, the session takes `frame.anchors … first(where: isTracked)` and runs Vision only when no tracked anchor exists [R15 L799, L1108–1111].
- `RealtimeAssociationPolicy.associateSighting`: `guard remote.count == 1 … return sole remote id`; no geometry [R16 L55–64]. The general `associate` (used by the non-sighting geometries) matches the single skeleton's hand to the nearest remote *phone pose in a shared frame* (max 0.45 m, margin 0.35 m, pose age 100 ms, `playerId` sort on ties) [R16 L20–51] — it depends on the shared frame being removed and is therefore not a basis for Quick Duel.
- `RealtimeArenaController.fireOnce` (sighting) sends the camera ray as `origin/direction` plus one observation `{targetPlayerId: body.association.playerID, associationConfidence, uncertaintyMeters: 0.08, colliders}`; no reticle-vs-collider test on the client [R17 L406–435]. Refusals surface as "No target in view." (`noSighting`) and "Too many players in view." (`ambiguousTarget`) [R18 L70–71].
- Decoding: `CombatWire.Observation` is synthesized `Codable` (missing keys throw; extra keys ignored); `Terminal.reason` and `fireRefused.reason` are free `String`s with `default:` rendering, but unknown event `kind` / server message `type` **throw** [R19]. So new *reasons* are tolerated by shipped clients; new *event kinds* are not.
- Spectator renders Convex `events` with a single optional `targetPlayerId` [R20]; it does not read the combat-worker wire at all.

### 2.6 Apple primary documentation (what it does and does not say)

- Vision: `VNDetectHumanBodyPoseRequest.results` is "the observed body poses" — an array of `VNHumanBodyPoseObservation`, i.e. the API is multi-body by contract; each recognized point carries a confidence [S2][S3]. Apple publishes no identity, re-identification, or cross-frame track id for body-pose observations — absence, and the reason attribution cannot come from Vision alone.
- ARKit: `ARBodyTrackingConfiguration` describes tracking "a person" and exposes `frame.detectedBody`; the fetched page does not state a maximum tracked-body count [S4]. The repository takes the first tracked anchor regardless [R15 L1108]. **[speculation]** ARKit body tracking is widely described by practitioners as single-body; this brief does not rely on that and treats the anchor path as one-body-in, same as Vision after scoring.
- No Apple document consulted describes the reliability of body-pose detection on a specific phone in a specific park; the device evidence list in ADR 0013 remains open [R21].

## 3. Why the 2-player rule is a degenerate case, not a different rule

Read together, §2.2 and §2.5 show that the current system has *two* independent "exactly one opponent" guards — client (`remote.count == 1`) and authority (`opponents.length !== 1 → ambiguousTarget`) — and both exist because the identity of the observed body is being *derived from the roster*, not observed. The general form of that derivation is: **the candidate set is the set of living, connected opponents; the observation is evidence about which member of that set was seen; the authority picks a member only when the evidence separates one candidate from all others by a fixed margin.** With one opponent the set has one member, the margin is trivially satisfied, and the rule reduces to today's behaviour exactly. The design below is that general rule.

## 4. Design

### 4.1 Wire: candidate list, additive, bounded

Replace the single `observation` with a **candidate list**, keeping the old key valid for the transition (see §4.7).

```ts
export interface BodyCandidate {
  targetPlayerId: string;            // roster member ≠ shooter; unique within the list
  confidence: number;                // 0…1, client belief that the observed body is this player
  cue: "sole" | "bearing" | "pose" | "manual" | "none"; // how the client formed the belief (§4.2)
}
export interface SightingObservation {
  capturedAtMs: number;              // as today
  bodyConfidence: number;            // Vision mean joint confidence (today's associationConfidence semantics)
  uncertaintyMeters: number;         // as today (client sends 0.08)
  colliders: readonly BodyCollider[];// 1…32, shooter camera space, as today
  bodiesInView: number;              // 1…8, count of Vision results this frame (§4.3)
  candidates: readonly BodyCandidate[]; // 1…LIMITS.players-1, sorted by targetPlayerId
}
// fire: {kind, shotId, poseSequence, origin, direction, sighting?: SightingObservation | null}
```

Design choices, with reasons:

- **One skeleton, many identities.** The client sends the colliders of the *one* body it aimed at (Vision scoring already yields one) and a belief distribution over *who* that body is. This matches what the client actually knows and keeps the geometry test (`resolveSighting`) unchanged. Sending several skeletons was considered and rejected: Vision gives no track id [S2], so the authority could not relate skeleton *k* to any player either; it would only multiply bytes.
- **Confidence is evidence, not proof.** BIO-36's threat-model brief already concluded client confidence cannot be trusted as proof [R22]; the authority treats `confidence` as an ordering input and applies its own veto rules (§4.4). The design never lets a high number alone create a hit the geometry does not support.
- **`bodiesInView`** is the one honest ambiguity signal the client has today and currently throws away [R15 L1169]. It costs one integer and is central to the policy in §4.3.
- **Sorted by `targetPlayerId`** so the canonical fingerprint in `admitCommand` [R7] is order-independent and the list has one encoding.
- **Bounds.** Candidates ≤ `LIMITS.players − 1 = 3`, each ≈ 60–80 bytes JSON; colliders unchanged at ≤ 32. Worst-case `fire` grows from today's ≈ 3–4 KiB (32 capsules × ~110 bytes + envelope) by < 300 bytes — far inside `messageBytes = 16 KiB` [R1] and irrelevant to Cloudflare's 32 MiB [S1]. The server-side terminal event (§4.6) grows by at most 3 short candidate rows, inside `serverMessageBytes`. No limit constant needs to change.

### 4.2 Where the client's belief comes from (and what this brief does not claim)

The protocol above is agnostic to the cue. The cues the repository can actually produce today, in decreasing strength:

1. **`sole`** — exactly one living, connected opponent (today's rule) → one candidate, `confidence = 1`. Reduces to §3.
2. **`none`** — several opponents, no discriminating signal → all living, connected opponents as candidates with equal confidence `1/n`. This is the *honest* encoding of "I saw someone"; the authority policy (§4.3) decides what to do with it.
3. **`bearing`** — ADR 0013 point 8's named candidate: Nearby Interaction per-peer direction [R21]. Absence: the fetched Apple NI pages did not render in this pass, so this brief makes **no** claim about direction availability, device coverage or accuracy; the BIO-36 briefs already covered NI's limits and this brief does not repeat them. Treated here only as a *future* cue that would populate `confidence` non-uniformly. **[speculation]** whether any device mix in the owner's fleet supports it is undetermined.
4. **`pose`** — a per-peer relative-pose estimate without a shared frame is exactly what the removed shared-frame work failed to deliver; this brief does **not** propose it and lists the cue name only so the enum is not reopened later.
5. **`manual`** — the shooter selects a target in the HUD (tap a roster chip before firing). **[speculation, product]** the only zero-infrastructure cue that yields a single candidate with 3–4 players; costs one tap and changes gameplay. Recorded as an option for the owner, not recommended by this brief.

Consequence: with no new sensing, 3–4-player Quick Duel produces `none` for every shot, and the whole question becomes the ambiguity policy.

### 4.3 Ambiguity policy — compared, one recommended

Let `C` be the candidate list after the authority's roster filter (living, connected, ≠ shooter), `n = |C|`, and `g` the geometry result of `resolveSighting` on the supplied colliders (hit zone or miss).

| Policy | Rule when `n > 1` and no candidate separates | Fairness | Cheat surface | Replay | Player experience |
|---|---|---|---|---|---|
| **A. No hit** | `fireRefused(ambiguousTarget)` (today's behaviour extended) | Never wrong | None | Trivial | With 3–4 players and cue `none`, **every** shot is refused; the mode is unplayable. Acceptable only as the guard *inside* B. |
| **B. Best guess with margin, else no hit** | Attribute to the unique top candidate if `top − second ≥ margin`; otherwise refuse | Wrong only when the client's belief is wrong; bounded by margin | Client can bias `confidence` → mitigated by veto (§4.4) and ledger (§4.6) | Deterministic given the command | With cue `none` degenerates to A; with any discriminating cue, plays |
| **C. Split damage** | Apply `damage / n` (or weighted by confidence) to every candidate | Always partly wrong: punishes players who were provably not aimed at | Trivial to exploit: aim at anyone, damage everyone; `bodiesInView = 1` and three victims is nonsense | Deterministic but the ledger can never say *who* was hit | Reads as random damage; contradicts "if you cannot be seen you cannot be hit" (ADR 0013 §4) [R21] |
| **D. Best guess, victim-corroborated** (B + §4.5 veto) | As B, but a candidate whose own stream proves it could not have been seen is removed *before* the margin test | Strictly ≤ B's error | Reduces the "attribute to whoever" bias because the authority can strike candidates the client cannot know about | Deterministic: corroboration inputs are commands already in the ordered batch | Same as B, and with `none` **it is the only policy that can turn 3 equal candidates into 1** without new sensing |

**Recommendation: D — best-guess with a fixed margin, after server-side candidate elimination; no hit when the survivors still do not separate.** Split damage is rejected outright: it damages players the shooter demonstrably did not see, which is the one thing ADR 0013's cover rule forbids, and it makes disputes unanswerable. Pure best-guess without a margin is rejected because with `none` it becomes a coin flip the ledger cannot defend. Pure no-hit is kept as the fallback branch, which is what makes 2-player identical to today.

Margin: **[proposal]** `0.35` on the normalized confidence scale, mirroring the existing `minimumMargin = 0.35` in `RealtimeAssociationPolicy.associate` [R16] so the codebase has one notion of "separated". With `n = 2` equal candidates (0.5/0.5) the margin fails → refuse; with one candidate → passes trivially.

### 4.4 Authority veto rules (evidence can only remove candidates)

In order, in `CombatSimulation.control` before geometry; each yields the named refusal, all replay-stable because they read only the snapshot and the command:

1. **Roster filter.** Drop candidates not in `players`, equal to the shooter, dead, or disconnected. If none remain → `noSighting` (there was no one to hit). Refuse the whole command as `invalidInput` if the list has duplicates, is unsorted, or a confidence is outside 0…1 — the validator should already have caught this.
2. **Freshness, confidence, uncertainty, non-empty colliders** exactly as today (`COVER_OBSERVATION_MS`, `bodyConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`) → `noSighting`.
3. **Count sanity.** `bodiesInView < 1` → `noSighting`. **[proposal]** if `bodiesInView === 1` and the shooter's client nonetheless lists `n ≥ 2` with cue `none`, that is the expected honest state and is *not* an error; the authority does not use `bodiesInView` to attribute, only to record (§4.6) and to gate the corroboration in §4.5.
4. **Victim corroboration** (§4.5) removes candidates.
5. **Margin test** (§4.3). Survivors `n = 1` → that player. `n ≥ 2` and top − second < margin → `ambiguousTarget`. Otherwise top.
6. **Geometry** `resolveSighting` unchanged; `missExpired`, `shieldBlocked`, `bodyHit` as today.

Nothing in 1–5 can *add* a hit; that is the invariant BIO-36 asked for [R22] and the property that keeps the client-asserted design defensible for co-located Phase 1 play.

### 4.5 Cross-corroboration from the targets' own streams

The authority already receives every player's pose commands each tick. In `sighting` they are discarded [R3 L160]. The design keeps discarding *frame-dependent* content (positions in a private AR frame are meaningless to another phone — this is why the shared frame is being removed) but retains three **frame-free** facts per player, bounded and checkpointable inside the existing `phones ≤ 4 × samples ≤ 16` history [R6]:

| Fact (per player, per pose sample) | Source | Used for |
|---|---|---|
| `trackingNormal: boolean` | already in pose (`phoneAt` requires normal tracking) [R5] | a candidate whose camera is not tracking is *not* removed (they can still be seen) — retained only for the ledger |
| `bodiesInView` and their own `candidates` at that time | the victim's *own* recent `fire`/sighting reports | **mutual sighting** (below) |
| `capturedAtMs` freshness | as today | stale players are `disconnected`-equivalent for the roster filter |

**Mutual sighting rule.** If candidate *V* reported, within `COVER_OBSERVATION_MS` of the shooter's `capturedAtMs`, a sighting whose candidate list contains the shooter *S* with cue `sole` or with `confidence ≥ 0.8`, then *V* and *S* were plausibly facing each other and *V* stays; that is corroboration *for* V. Conversely — and this is the only eliminating case the repository can support without new sensing — if *V* reported `bodiesInView = 0` with normal tracking in that window **and** *V*'s own camera ray was pointed away, nothing can be concluded, because seeing and being seen are not symmetric (V may face a wall while S sees V's back). **Absence stated plainly:** without a shared frame or per-peer ranging there is *no* frame-free fact that proves "V could not have been in S's view". Corroboration in the current sensing envelope is therefore **advisory for the ledger and for the margin (a mutual-sighting bonus), never a veto**. The elimination step 4 in §4.4 is thus empty today and becomes real only when a cue in §4.2 (3) ships. This brief prefers stating that plainly to inventing a veto the evidence cannot support.

**[proposal]** mutual-sighting bonus: add `+0.2` to a candidate's confidence when the mutual rule holds, before the margin test, capped at 1. With three candidates at `1/3` each, one mutual sighting yields `0.53 vs 0.33` — a margin of 0.20, **below** 0.35 → still refused. This is deliberate: a bonus alone must not manufacture attribution. The number is a knob for the record, not a claim of correctness.

What corroboration **does** deliver today: a per-shot, server-side record of what every candidate's own phone said at the moment of the shot (§4.6), which is what a dispute actually needs.

### 4.6 Deterministic tie-breaks

All comparisons are on data in the ordered command batch or the snapshot, so a replay of the same command log yields the same verdict [R3 L12, L27]. Order, applied only after the margin test has produced a top candidate that ties *exactly* with another (possible when confidences are equal and a bonus applies to both):

1. higher post-bonus `confidence`;
2. candidate with the **more recent** mutual sighting of the shooter (`capturedAtMs` descending) — the same "latest evidence wins" direction as `history.ts` [R5 L70];
3. **lower** remaining `health` (**[proposal]**: prefers finishing a fight to spreading damage; alternative "higher health" is equally deterministic — owner's call);
4. `targetPlayerId.localeCompare` ascending — the terminal, string-total order used everywhere else [R4 L167][R16].

Exact ties after step 1 with margin ≥ 0.35 cannot occur by construction (two candidates cannot both exceed the other by 0.35), so 2–4 only matter when the owner later lowers the margin; they are specified now so the rule never depends on iteration order or floating-point accident.

### 4.7 Replay, checkpoint and release compatibility

- **Additive key, one version.** Keep `observation?` valid in `PROTOCOL_VERSION = 1` for the transition and add `sighting?` as a second exact-key alternative in `validation.ts`; a `fire` may carry one or the other, never both. The simulation maps a legacy `observation` to `SightingObservation{candidates: [{targetPlayerId, confidence: 1, cue: "sole"}], bodiesInView: 1, bodyConfidence: associationConfidence}` before `control`, so old clients and all existing `sighting.test.ts` cases [R23] keep their verdicts, and the `contracts/fixtures/combat.v1.json` envelopes stay valid [R24]. **Alternative:** bump `PROTOCOL_VERSION` to 2 and drop `observation`. The repository already pins `protocolVersion` in the client manifest and reports mismatches [R11]; this is the cleaner end state but forces a lock-step client release. Recommended: additive now, remove in the deletion record that also removes `shared_maps`.
- **Checkpoint.** Store the frame-free per-player sighting facts (§4.5) inside the existing bounded `bodies ≤ 12 / samples ≤ 16` structures or bump `checkpoint.version` to 2 with a validator branch [R6]; do not grow unbounded lists. Recovery from a checkpoint plus event replay stays deterministic because every input is a command.
- **Events.** Do **not** add a new event `kind` (shipped iOS decoders throw on unknown kinds [R19]). Extend `projectileTerminal` with optional additive fields (`attribution`, below); iOS `Codable` ignores unknown keys [R19]; the spectator never reads this wire [R20]. New refusal reasons are safe (free `String` with `default:`), so `ambiguousTarget` can gain siblings if needed.
- **Fingerprint.** The canonical fingerprint in `admitCommand` [R7] covers the whole command, so sorted candidates give a stable idempotency key; a retry with a different candidate list is correctly a conflict.
- **Lobby.** `QUICK_DUEL_MAX_PLAYERS` and `QUICK_DUEL_FULL` [R12] become `LIMITS.players`; `selectCombatGeometry` stops needing the `≤ 2` clause. Both are one-line backend changes but are protocol-adjacent contract changes (`interface-contracts.md` L704) and so need Integration ownership.

### 4.8 What the client changes (for completeness; iOS-targeting ownership)

`RealtimeAssociationPolicy.associateSighting` returns a candidate list instead of an optional id: `remote.count == 1 → [sole]`, else all living connected remotes at `1/n` with cue `none` [R16]. `TargetingSession` surfaces `results.count` alongside the winning observation [R15]. `fireOnce` sends `sighting` instead of `observation` [R17]. Nothing else on the client changes; specifically **no** scan, alignment, relocalization, map, rendezvous or NI code is required or reintroduced.

## 5. Verdict ledger for disputes

The repository has two half-ledgers: `BulletLedger` (projectile events, no evidence) [R10] and the Convex `verdict-ledger.v1` contract (host-adjudicated, single `targetPlayerId`, "backend ready, no client yet") [R13]. Neither records *why* a target was chosen, and the `commands` table that does hold the input is pruned at 512 rows [R8]. A dispute ("I was behind the tree", "I shot Bob not Carol") needs one durable row per `fire` in the Durable Object, written in the same `commit()` transaction as the events so it cannot diverge from the verdict:

| Field | Type | Why a dispute needs it |
|---|---|---|
| `matchId, authorityEpoch, eventSequence` | as `room` | join to events and reports [R8][R11] |
| `shotId, shooterPlayerId, clientSequence, commandFingerprint` | string/int | idempotency and proof that the stored input is the admitted input [R7] |
| `sentAtMs, receivedAtMs, capturedAtMs, matchTimeMs` | int | freshness gate (`COVER_OBSERVATION_MS`) is the most common refusal |
| `origin, direction` | Vec3 | shooter camera ray as submitted |
| `bodiesInView, bodyConfidence, uncertaintyMeters, colliderCount, colliderHash` | int/num/hash | what the shooter's camera saw; hash (not the colliders) keeps the row small — the full colliders are in the pruned command, and BIO-36 already proposed an observation hash [R25] |
| `candidatesSubmitted` | `[{targetPlayerId, confidence, cue}]` ≤ 3 | the client's claim, verbatim |
| `candidatesAfterRoster, candidatesAfterVeto` | `[targetPlayerId]` | which authority rule removed whom (§4.4 steps 1, 4) |
| `bonuses` | `[{targetPlayerId, mutualSightingAtMs}]` | corroboration actually applied (§4.5) |
| `marginTop, marginSecond, marginRequired` | num | the arithmetic of the decision |
| `tieBreakRule` | `null \| 1..4` | which §4.6 rule decided, if any |
| `attributedTargetPlayerId` | string ∣ null | the verdict's target |
| `reason` | terminal reason or refusal reason | `bodyHit / shieldBlocked / missExpired / ambiguousTarget / noSighting / …` |
| `zone, damage, targetHealthBefore, targetHealthAfter, shieldActive` | as today | outcome |
| `victimSnapshot[]` | per candidate: `{connected, trackingNormal, lastPoseAtMs, lastOwnSightingAtMs, lastOwnBodiesInView, sawShooter: boolean}` | the frame-free facts from the victim's own stream at verdict time (§4.5) |
| `rulesSchemaHash, protocolVersion, workerVersionTag` | string | reproduce the rule set that produced the verdict [R11] |

Bounds: ≤ 3 candidates × 5 small arrays keep a row well under 2 KB, far below Cloudflare's 2 MB row cap [S1]; at 60 commands/s cap and realistic fire cadence (150 ms) a 10-minute match writes ≤ 4 000 rows × 4 players, tens of MB at most, inside the 10 GB per-object budget [S1]; retention should follow `match_reports`, not `commandHistory`. The same fields, minus `victimSnapshot`, map onto `verdict-ledger.v1`'s `ShotVerdictRecord` with `targetPlayerId = attributedTargetPlayerId`, `verdict ∈ hit/miss/rejected`, `rejectionReason = reason` — so the Convex ledger needs only an additive `attribution` object, not a new contract, if the owner wants disputes visible outside the Durable Object.

Additive `projectileTerminal.attribution` (server → client, optional): `{candidates: [{targetPlayerId, confidence}], margin: number, tieBreakRule: number | null}` — enough for the HUD to say "hit Bob (2 in view)" and for the shooter's report to match the ledger row.

## 6. Two-player as the special case — worked through the rule

Roster `{S, V}`. Client: `remote.count == 1 → candidates = [{V, 1, sole}]`, `bodiesInView = k`. Authority: roster filter keeps V (alive, connected); freshness/confidence gates identical to today; corroboration empty; margin `1 − 0 ≥ 0.35` passes; tie-break unused; geometry as today. Every branch of `sighting.test.ts` [R23] — including "refuses a mismatched targetPlayerId as invalidInput" (a candidate not in the roster is dropped at step 1 → `noSighting`; keeping `invalidInput` for a *non-roster* id is a one-line choice in the roster filter) and "refuses fire on a 3-player sighting roster as ambiguousTarget" (which must be **rewritten**, since a 3-player roster is now legal and refuses only when candidates fail the margin) — is reproducible from the general rule. The one behavioural difference in 2-player is the ledger row and the additive `attribution` field.

## 7. What this design does not solve, stated as absences

- **No new sensing means `none` for every 3–4-player shot, and D then refuses every shot.** The protocol, authority and ledger in §4–5 are the necessary substrate; a discriminating cue (§4.2 items 3 or 5) is what makes 3–4-player playable. Which cue is a product/hardware decision this brief cannot make without device evidence — and the BIO-36 briefs already documented the sensing options and their limits [R22][R25].
- **No physical-device evidence exists** for 2-player `sighting` [R9], let alone for multiple bodies in Vision at park ranges; the scoring weights in `TargetingSession` [R15] have never been measured against a second person in frame.
- **Bystanders** (ADR 0013 consequence) remain: any body the shooter aims at is attributed to a roster member; `bodiesInView` in the ledger makes this auditable but not preventable [R21].
- **Corroboration cannot veto** without a frame-free "could not be seen" fact (§4.5); the design records rather than pretends.
- **Nearby Interaction** direction semantics were not verified from Apple's pages in this pass (fetch failed); nothing here depends on them.

## 8. Decision list for the owner (not decided here)

1. Adopt policy D (recommended) vs. B; margin `0.35`.
2. Additive `sighting` key in v1 (recommended for the transition) vs. `PROTOCOL_VERSION = 2`.
3. Tie-break step 3: lower health vs. higher health.
4. Whether to ship the protocol/ledger substrate *before* a discriminating cue exists (3–4-player lobby opens but every shot refuses) or hold the lobby cap at 2 until a cue ships (recommended: hold the cap; ship substrate + ledger behind it so 2-player gains the ledger now).
5. Whether the "manual target" cue (§4.2 item 5) is acceptable gameplay as the zero-hardware path to 3–4 players.

## Sources

Repository (`Jorybraun/victoria-kill-zone`, `main`, read 2026-09-27; line numbers as of that revision):

- [R1] `packages/combat-protocol/src/index.ts` — `LIMITS`, `BodyCollider` L22–24, `BodyObservation` L25–31, `fire`/terminal types, refusal reasons L115.
- [R2] `packages/combat-protocol/src/validation.ts` — exact-key `keys(...)`, `observation(...)`, `fire` case.
- [R3] `packages/combat-simulation/src/index.ts` — `ordered` L12, player sort L27, `sighting` getter L133, pose observation discard L160, `control` fire branch L275–314.
- [R4] `packages/combat-simulation/src/flight.ts` — `resolveSighting`; `resolveFlights` comparator L167; `BODY_ANCHOR_METERS` use L177.
- [R5] `packages/combat-simulation/src/history.ts` — `COVER_OBSERVATION_MS = 1_000` L8, `BODY_ANCHOR_METERS = 2` L10, `anchoredToPhone` L50, history sort L70, `coverObserved` L78.
- [R6] `packages/combat-simulation/src/state.ts` — checkpoint validator, `version !== 1` L72, history bounds L120–124.
- [R7] `services/combat-worker/src/room.ts` — `admitCommand`, `tick`, commit/sync/broadcast.
- [R8] `services/combat-worker/src/store.ts` — tables L40–65, `commit()` L110–132.
- [R9] `docs/build-log.md` — no completed `sighting` two-phone entry; 2026-09-22 arena 5Q85SK stall L532–534.
- [R10] `services/combat-worker/src/bullet-ledger.ts`.
- [R11] `services/combat-worker/src/report.ts` — issue body L239–269, release section L189–232.
- [R12] `convex/functions/combat.ts` — `QUICK_DUEL_MAX_PLAYERS` L27, `selectCombatGeometry` L29–40, `prepare` L43–69, ticket roster L86–89.
- [R13] `docs/interface-contracts.md` — `verdict-ledger.v1` L656–695; Quick Duel cap L704.
- [R14] `convex/functions/schema.ts` — `matches` L50–94, `players` L98–131.
- [R15] `ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift` — `TargetingSkeleton` L268–276, `usesBodyTracking` L799, `poseRequest` L809, anchor path L1105–1111, `detectPose` L1153–1175, `bodyConfidence` L1187–1190, candidate score L1253–1258; `Targeting/BodyTargetingGeometry.swift` L85, L97–118.
- [R16] `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeBodyAssociation.swift` — `associate` L20–51, `associateSighting` L53–64, `hitSkeleton` L90–94.
- [R17] `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeArenaController.swift` — `fireOnce` L406–435.
- [R18] `ios/VictoriaKillZone/VictoriaKillZone/Features/Realtime/RealtimeCommandState.swift` L70–71.
- [R19] `ios/VictoriaKillZone/VictoriaKillZone/Services/Realtime/CombatWire.swift` — `Observation` L32–38, fire encoder L116–121, `Terminal` L150–154, event/message decoders L164–176, L205–221; `Features/Replay/CombatReplaySession.swift` L97–102.
- [R20] `spectator/src/domain/spectator.ts` L62–71.
- [R21] `docs/decisions/0013-quick-play-sighting-hits.md` — decision points 3–5, 8; consequences.
- [R22] `docs/research/client-evidence-threat-model.md` (BIO-36) — §threat table L92–93: `associationConfidence` is "self-reported quality, useful for honest-client fallback policy, worthless for trust"; corroboration should raise trust only when victim evidence agrees.
- [R23] `packages/combat-simulation/tests/sighting.test.ts`.
- [R24] `contracts/fixtures/combat.v1.json`; `ios/.../VictoriaKillZoneTests/CombatContractFixtureTests.swift`; `packages/combat-simulation/tests/contract-fixture.test.ts`.
- [R25] `docs/research/zero-step-architecture-synthesis.md` (BIO-36) — L121 `evidence_ledger(shot_id, tier, sigma, corroboration, observation_hash, surface_hash)`; L248 "ledger stores verdicts and provenance, never sensor payloads".

External (accessed 2026-09-27):

- [S1] Cloudflare, "Limits · Durable Objects" — https://developers.cloudflare.com/durable-objects/platform/limits/ (single-threaded Objects; SQLite row/BLOB 2 MB, statement 100 KB, 100 bound params, 100 columns; 10 GB per Object; 32 MiB received WebSocket message). Primary.
- [S2] Apple, `VNDetectHumanBodyPoseRequest` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest ("The observed body poses" results). Primary.
- [S3] Apple, `VNHumanBodyPoseObservation` / `VNRecognizedPoint` — https://developer.apple.com/documentation/vision/vnhumanbodyposeobservation (joint names / recognized points). Primary; the fetched page lists joint and joint-group names — the per-point `confidence` property is on `VNRecognizedPoint`, referenced from the request page's "See Also" list [S2], not re-fetched separately.
- [S4] Apple, `ARBodyTrackingConfiguration` — https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration ("When ARKit identifies a person…", `detectedBody`). Primary; states no body-count maximum.
