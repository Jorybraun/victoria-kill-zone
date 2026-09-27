# Quick Duel only: shared-frame removal and 2–4 player target identity — architecture synthesis (BIO-37)

Status: research synthesis, not a decision. Tracks [BIO-37](https://linear.app/biossphere/issue/BIO-37). Read-only: no code, branch, commit, PR, deployment, ADR or device trial was produced. **Nothing in this document is physical-device evidence.** Companion provenance: [multiplayer-identity-synthesis.provenance.md](multiplayer-identity-synthesis.provenance.md).

Builds on — does not repeat — [zero-step-architecture-synthesis.md](zero-step-architecture-synthesis.md) (BIO-36) and its seven briefs. BIO-36 settled where combat authority lives, the local-surface / bounded-evidence plan for walls and room awareness (still valid and untouched here), the confidence-is-a-hint trust principle and the release gates. This synthesis answers only what BIO-36 left open once the product owner fixed the following, which are **taken as given, not re-argued**:

- Shared frame / Saved Arena is removed entirely and does not return: ADR 0010/0011, `SharedArena`, `DuelFrame`, scanning, alignment, relocalization, map-linking, rendezvous, `ARWorldMap` save/load and collaborative sessions are not future options.
- Quick Duel (ADR 0013 camera body-sighting) is the only play mode; each phone keeps its own AR frame; the match `CombatRoom` Durable Object (DO) is combat authority; start is never gated by setup; the target is 2–4 players with zero setup; the Convex lobby already knows the roster.

Method: seven independent BIO-37 briefs and their provenance sidecars (§2) were read in full; every repository fact they disagree on, and every fact this synthesis leans on for a decision, was re-checked against `main` at `3d89b7f` (2026-09-27, clean tree); platform facts were kept only where a brief cites an official Apple or Cloudflare page and no brief contradicts it; the result was reduced to one removal plan, one identity architecture, one trust table, one product model, one physical matrix and one ordered slice list.

Labels used throughout:

- **[repo]** — read directly from this repository at `3d89b7f` (re-verified in this synthesis; file:line given where load-bearing).
- **[Apple n]** / **[Cloudflare n]** — official vendor documentation, cited by numbered source in §13, as fetched by the named brief.
- **[B1]…[B7]** — one of the input briefs (§2); used for claims this synthesis did not independently re-derive.
- **[inference]** — follows from the above but was not observed.
- **[proposal]** — a design choice made here; every number attached to a proposal is a placeholder until §8 measures it.
- **[speculation]** — plausible, unverified, flagged.
- **Absence** — looked for and not found; stated as an absence, never converted into a claim.

## 1. Executive recommendation

1. **Remove first, identify second, raise the cap last.** Removal (§4) is pure debt reduction and leaves the product a working two-player Quick Duel at every step. Identity (§5) ships as a *dark substrate* behind the unchanged two-player cap. The cap switch to 4 is a separate, final slice that is gated on physical-device rows (§8), because the repository contains **no mechanism that can name which of several opponents a camera saw** [repo][B1 §7 D-1][B4 §7].
2. **Lifting the cap is not a copy change.** Four independent seams hard-code two players: iOS `QuickDuel.maxPlayers = 2` (`Domain/LobbyModels.swift` L247), iOS `associateSighting` `guard remote.count == 1` (`Features/Realtime/RealtimeBodyAssociation.swift` L61), Convex `QUICK_DUEL_MAX_PLAYERS = 2` / `QUICK_DUEL_FULL` (`convex/functions/combat.ts` L27; `matches.ts` create/join) and the simulation `if (opponents.length !== 1) return "ambiguousTarget"` (`packages/combat-simulation/src/index.ts` L283); a fifth, `TargetingSession` keeping one body via `.max(by: score)` (L1173), discards the only ambiguity signal the phone has [repo]. Raising only the lobby would produce matches in which every sighting shot is refused.
3. **Wire: one body's geometry, a bounded candidate distribution over who it is.** The client sends the colliders of the single body it aimed at plus `bodiesInView` and ≤ 3 `{targetPlayerId, confidence, cue}` candidates sorted by `playerId`, as an additive `sighting` key beside today's `observation` under protocol v1 [B4 §4.1, §4.7]. The margin is **derived by the DO** from the candidate confidences, never trusted as a separate client field.
4. **Authority rule: filter, gate, separate, then resolve — and never guess.** Candidates are filtered to living, connected, non-shooter roster members; today's freshness/quality gates apply; the unique survivor wins; with ≥ 2 survivors the top candidate wins only if it leads the runner-up by a fixed margin (proposal `0.35`, mirroring `minimumMargin` at `RealtimeBodyAssociation.swift` L18); otherwise `ambiguousTarget`. No health-based tie-break, no split damage, no redirect [B4 §4.3][B6 §4.1]. Two players is the same rule with one candidate [B4 §6].
5. **Fail closed on attribution, fail open on corroboration, never fail at match scope.** A shot that cannot be attributed is refused (it already costs no ammo or cooldown — refusal returns before `p.ammo--`, `index.ts` L283–291 [repo]); a decisively attributed shot that simply lacks independent corroboration is applied and ledgered `shooterOnly`; no identity state ever pauses, blocks or returns a match to setup [B6 §7][B5 §7].
6. **Nothing the client says about identity is a security input.** Candidate confidences, cues, `bodiesInView`, UWB samples and appearance scores are honest-client fairness inputs and audit data. Colluding or modified clients can defeat them; the design bounds and records that, it does not claim to prevent it [B6 §3–§5][BIO-36 B6].
7. **The discriminating cue is unproven on every candidate path.** With no new sensing, every 3–4-player shot is cue `none` and the rule refuses it [B4 §7]. Plain Nearby Interaction bearing (UWB-to-UWB only) [B3 §7], session-local appearance memory with track continuity [B2 §7], and a manual target tap [B4 §4.2 item 5] are the only candidates; each needs the §8 device rows before any ADR commits to it. Recommended default: build the trial-mode capture, measure bearing and appearance against manual ground truth, and hold the manual tap as the owner-approved fallback if both miss the threshold (§10 O1–O3).
8. **ADR 0014 records the removal and the attribution rule; a later ADR fixes cue and thresholds from device data.** ADR 0014 supersedes 0010/0011, amends 0013's two-player statement to "2–4 subject to the identity gate", and notes the missing ADR 0012 as an absence (`docs/decisions/` has no 0012 file; ADR 0013 L3/L7 cites it) [repo][B1 §4.7 D-H].

## 2. Inputs and how they were reconciled

| Id | Brief (uncommitted input, 2026-09-27, `main` `3d89b7f`) | Track |
|---|---|---|
| B1 | `shared-arena-removal-inventory.md` | File-by-file removal inventory; keep-list; 10-step PR stack; ownership gaps |
| B2 | `vision-opponent-identification.md` | Vision/ARKit identity signals; capability matrix; client confidence content |
| B3 | `radio-ranging-identification.md` | Nearby Interaction / BLE as identity; fusion rule without a shared frame |
| B4 | `multi-target-protocol-authority.md` | Candidate wire shape; ambiguity policies; veto order; tie-breaks; ledger |
| B5 | `roster-ux-multiplayer.md` | Product model; copy audit; lobby/HUD states; user-facing acceptance |
| B6 | `trust-multi-target.md` | Identity threat matrix; trust tiers; fail-open/closed table |
| B7 | `device-validation-multiplayer.md` | 2–4 phone × UWB × LiDAR physical matrix; metrics; evidence capture; fixture gaps |

All seven confirm the same repository premises (fire carries origin/direction and an optional `BodyObservation` chosen by `associateSighting`; Vision drives the body path; Convex owns lobby/prepare; `CombatRoom` runs `packages/combat-simulation`; wire types live in `packages/combat-protocol`) and all seven state that no physical device was used. They disagree on eleven points; the resolutions are in §3.1 and in the section where each matters, and are listed with reasons in the provenance sidecar.

## 3. Repository facts (verified, with the disagreements resolved)

### 3.1 Facts this synthesis depends on

| # | Fact | Evidence [repo] |
|---|---|---|
| F1 | Sighting fire is refused `ambiguousTarget` whenever the roster has ≠ 1 other player, **before** the observation is read and **regardless of life or connection state**; the named target must equal that one opponent (`invalidInput`); age > `COVER_OBSERVATION_MS` (1 000 ms), `associationConfidence < 0.8`, `uncertaintyMeters > 0.1` or no colliders → `noSighting`. All of these return before `p.ammo--` / `lastFireAtMs`, so a refused sighting shot costs no ammo or cooldown. | `packages/combat-simulation/src/index.ts` L281–291 |
| F2 | Client target choice is roster elimination only: `guard remote.count == 1, let target = remote.first, target.connected`. The shared-frame `associate` path uses `maximumHandDistance = 0.45`, `minimumMargin = 0.35`. | `RealtimeBodyAssociation.swift` L17–18, L61 |
| F3 | `uncertaintyMeters` is the literal `0.08` on the fire path. | `RealtimeArenaController.swift` L423 |
| F4 | Vision candidates are reduced to one by `.max(by: { $0.score < $1.score })`; no body count or track id reaches the wire. | `Targeting/TargetingSession.swift` L1173 |
| F5 | Convex `QUICK_DUEL_MAX_PLAYERS = 2`; `convex/domain/config.ts` default `maxPlayers: 2`; `docs/interface-contracts.md` documents "`maxPlayers` is forced to 2, a third join fails `QUICK_DUEL_FULL`". | `convex/functions/combat.ts` L27; `convex/domain/config.ts` L8; `docs/interface-contracts.md` "Realtime combat v1" |
| F6 | `CombatRules` keys are `durationMs, geometry, respawnMs, protectionMs, weapon, shield, slowField`; `rulesSchemaKeyPaths` hashes **key paths only**; `DEFAULT_RULES.geometry = "trackedBody"`. No player cap lives in rules, so changing the cap or narrowing the geometry union does not move `rulesSchemaHash`; deleting `slowField` does. | `packages/combat-protocol/src/index.ts` L45–68 |
| F7 | Worker store: `schema_migrations` seeded with version 1; `shared_maps` and `map_chunks` DDL; the store **throws** on any version ≠ 1. A v2 migration therefore needs the version check changed in the same PR. `commands`/`events` are pruned at `LIMITS.commandHistory`/`eventHistory`. | `services/combat-worker/src/store.ts` L41–42, L58–67, L128–130 |
| F8 | Worker relays `niToken` per `playerId` (`niTokens` map, replay to late joiners). | `services/combat-worker/src/room.ts` L44, L160–161, L231–233 |
| F9 | `Info.plist` declares `NSNearbyInteractionUsageDescription`. | `ios/VictoriaKillZone/VictoriaKillZone/Info.plist` L53 |
| F10 | Refusal copy: `ambiguousTarget` → "Too many players in view."; `noSighting` → "No target in view."; tracking → "…players and the arena reference."; default → "…when the arena is ready."; roster-full → "Quick Duel is 2 players; use a Saved Arena for 3–4". | `Features/Realtime/RealtimeCommandState.swift` L60, L70–74; `LobbyModels.swift` L250 |
| F11 | `docs/decisions/` contains 0001–0011 and 0013; there is no 0012. | `ls docs/decisions` |
| F12 | The only ≥ 3-player sighting test asserts the ceiling: "refuses fire on a 3-player sighting roster as ambiguousTarget". | `packages/combat-simulation/tests/sighting.test.ts` L80–83 |

### 3.2 Disagreements between briefs, resolved

1. **Ambiguity policy.** B4 recommends best-guess-with-margin, else refuse; B6's friend tier "fails open on identity" (apply + flag); B2 and B5 recommend refuse. **Resolved:** these answer different questions. When the client's candidates do not separate, the shot is **refused** (B2/B4/B5). When they do separate but no independent evidence corroborates them, the shot is **applied and flagged `shooterOnly`** (B6). §5.4.
2. **Victim-pose veto via a pair-transform estimator** (B6 §5.1, inherited from BIO-36 §5 as speculation). **Resolved: out of scope.** Estimating a rigid transform between two phones' AR frames from sightings is frame alignment by another name, which the owner has removed. B6's `identityMismatch` and "centroid matches a different player" checks depend on it and are not adopted. This leaves the DO with no frame-free "could not have been seen" fact — B4 §4.5 states the same absence.
3. **"Plausibly in view" roster elimination** (B2 §3.10: opponents "whose own phone reports a camera pose broadly consistent with being in front of the shooter"). **Resolved: corrected.** Each phone's pose is in its own frame, so no such comparison exists without a shared frame [inference from F1, B4 §4.5]. Only frame-free elimination remains: dead, respawning, disconnected, protected.
4. **Mutual-sighting confidence bonus** (B4 §4.5, `+0.2`). **Resolved: ledger-only by default.** A bonus derived from another client's self-report is a client-to-client vote, which B6 §4.4 rules out; it can be revisited if §8 shows it separates honest cases without adding misattribution.
5. **Tie-break by lower health** (B4 §4.6 step 3). **Resolved: rejected.** B6 §4.1 identifies "redirect to the lowest-health player" as the attack payoff. With a positive margin, exact ties cannot survive; if the margin is ever set to 0, a tie refuses.
6. **Client-supplied margin / `identity` block** (B2 §6) vs **candidates only** (B4) vs **no new client fields** (B6 §8). **Resolved:** B4's candidate list, with B2's provenance folded into `cue` and one `trackAgeMs`; margin computed by the DO. B6's "no new fields" was scoped to its veto steps, which item 2 drops.
7. **Use of `bodiesInView`.** B4 uses it as a sanity check; B6 §4.6 warns that a body-count rule is a self-report that can poison other players' shots. **Resolved:** the DO records it and rejects only the incoherent `bodiesInView < 1`; it never raises ambiguity on another player's behalf. The *shooter's own* client may self-refuse on it (affects only that shooter).
8. **Nearby Interaction code.** B1 deletes all NI code, the `niToken` relay and the usage string; B2/B3 would keep per-peer session primitives for a bearing hint. **Resolved:** delete in the removal stack (it is rendezvous-shaped, F8, and shared-frame-purposed); any bearing cue is a new, identity-purpose slice re-introduced only if §8 rows Q1/T1 pass (§10 O2).
9. **Ownership.** B6 §8 calls `packages/combat-simulation` "Backend"; `AGENTS.md` gives Backend only `convex/**`. **Resolved by `AGENTS.md`:** `packages/**`, `services/**`, `ios/**/Features|Services|Domain/**` have no named owner; this synthesis follows B1 in assigning them to Integration provisionally and lists it as an owner decision (§10 O8), as BIO-36 did.
10. **Cap switch timing.** B1 step 6 bundles cap raise with the rule change; B4/B6 hold the cap until a cue exists; B5 ships steps 1–3 dark. **Resolved:** substrate dark behind cap 2; cap switch is the last slice, gated on §8.
11. **Colour/glyph slots** (B5 §5.2) vs **"never assign team colours"** (B2 §7). **Resolved:** no conflict. B2 forbids anything *worn or displayed on the person* as an identity signal; B5's slot colour + glyph is HUD/roster presentation only and is never read by the camera.

## 4. Removal plan

### 4.1 Inventory summary (from [B1 §4], re-grouped by dependency)

| Group | Delete | Simplify | Rename | Keep |
|---|---|---|---|---|
| iOS leaf features | `Features/Arenas/*`, `Features/MapLab/*`, `Targeting/MapLab/*`, `Domain/SavedArenaModels.swift`, `Domain/MapLabModels.swift`, `Services/SavedArenaStore.swift`, `Services/MapLabStore.swift`; Home Saved-Arena/MapLab section; `RootView`/`AppEnvironment` sheets and injection | `HomeView`, `WaitingRoomView`, `LobbyStore` copy (§6.3) | — | Invite QR (`QRScannerView`), debug-fire button |
| iOS realtime | `RealtimeArenaMode`, map/collab/`frameReady` paths in `RealtimeArenaController`, `RealtimeReferencePanel`, map-stage presentation, aligned `associate(...)`, `CombatMapClient`, `VKZ_QUICKPLAY_MAP_FALLBACK` | controller becomes sighting-only | — | `fireOnce`, pose pump, `associateSighting` (generalised later, §5) |
| iOS shared-frame core | `Targeting/SharedArena/*` except diagnostics, `Targeting/QuickPlay/SharedOrigin*`, `Targeting/NearbyInteraction/*`, `NearbyRendezvous*`, `DuelPeerLink` tracer (pending O9), shared-frame hooks in `TargetingSession`, `NSNearbyInteractionUsageDescription` | `TargetingSession` keeps body targeting + `LocalSurfaces/*` | `DuelFrameDiagnostics.swift` / `DuelFrameDiagnosticEvent` → a mode-neutral name (e.g. `MatchDiagnostics` / `MatchDiagnosticEvent`), **wire shape unchanged** — `ReportProblemView` and `MatchReportClient` depend on it [B1 §5 item 2] | `BodyTargetingGeometry`, `LocalSurfaces/*` (BIO-36 plan) |
| iOS package | `Transport/CombatTransport/**`, `Package.swift` entry, `EngineLinkageTests` (if O10 = delete) | `verify-ios.sh` package loop | — | — |
| Xcode | every deleted file's pbxproj references, in the **same PR** as the deletion | — | renamed diagnostics file reference | `check-xcode-sources.py` |
| Worker | `maps.ts`, map route/regex and `["GET","PUT"]` allow-list, `collab` relay + budgets, `niToken` relay + bucket, tests `maps`/`collab`/`ni-token`, benchmark collab traffic | `store.ts` → `schema_migrations` v2 dropping `shared_maps`/`map_chunks` **and** accepting versions 1→2 (F7) | report section "Setup log (untrusted)" → "Diagnostic log (untrusted)" [proposal] | `report.ts`, `/v1/matches/:id/report`, `match_reports`, `manifest.ts`, `/health` |
| Protocol / simulation | `LIMITS.collab*`, `mapBytes`, `niTokenBytes`, `collab`/`niToken` validators (with Worker); later (v2) `frameReady`, `frameEpoch`, `pose.observations`, `slowField` | `DEFAULT_RULES.geometry = "sighting"`, union narrowed to `"sighting"` (hash unchanged, F6); simulation collapsed to the sighting path | phase `calibrating` → `ready` in protocol v2 only | `pose`, `fire`, projectile spawn/terminal pair, refusal reasons |
| Convex | `combatGeometry` arg after one release (O11); `trackedBody`/`phoneProxy` schema literals after stored rows are gone | `selectCombatGeometry` → always sighting | — | `convex/domain/fire.ts`, `shots.ts`, `g2.v1.json`, geofence radius |
| Spectator | `arena-calibrating` demo scenario | "ALIGNING ARENA" → "WAITING FOR HOST" copy now; literal later | phase literal with protocol v2 | evidence folders |
| Scripts / contracts | shared-frame replay scenarios, smoke `frameEpoch` (v2) | `combat.v1.json`, `scenarios.ts`, `combat-deploy.mjs` | — | `check-release-manifest.mjs`, `release-manifest.json` (values change only in the PR that changes rules/protocol) |
| Docs / design | nothing deleted | prose in `interface-contracts.md`, `roadmap.md`, runbooks, feature docs | — | ADRs (status lines only), `docs/research/*`, `design/evidence/**` |

**Rename-versus-delete rule [proposal].** Delete when the concept is shared-frame-only and has no surviving consumer. Rename when a surviving path (report, lobby phase, diagnostics) depends on the type or literal — and rename *without changing the wire shape* until protocol v2. Do **not** rename internal non-player-visible types (`RealtimeArenaView`, `RealtimeArenaController`, `arenaState`) during removal: churn with no product value, and it widens every diff that must also touch pbxproj [B5 §8 scope note].

### 4.2 Superseding ADR

`docs/decisions/0014-quick-duel-only.md` [proposal, Integration-owned], containing: Quick Duel is the only mode; the shared-frame concept list from the owner's decision; each phone its own frame; DO authority; start never gated; 2–4 target **subject to the identity gate in §5/§8**; the attribution rule of §5.4 (without thresholds); the trust principle of §7. Status edits: ADR 0010 and 0011 "Superseded by ADR 0014"; ADR 0005, 0006, 0008, 0009 "Superseded in part by ADR 0014" where they rely on shared frame or `trackedBody`/`phoneProxy`; ADR 0013 amended (cap statement, roster rule), not superseded; the missing ADR 0012 noted as an absence rather than cited [B1 §4.7]. A later ADR (0015) fixes the cue(s) and thresholds from §8 data.

### 4.3 Dependency-ordered stacked PR series

Stack order follows [B1 §6] with two changes: the cap switch is removed from the removal stack (it becomes identity slice N8), and the neutral copy cleanup gets its own step so the 2-player product stops pointing at a mode that no longer exists as soon as the UI is gone.

| Step | PR | Owner (per `AGENTS.md`; * = unassigned path, Integration provisional) | Why `pnpm verify` stays green |
|---|---|---|---|
| R0 | ADR 0014 + status lines | Integration | docs only |
| R1 | iOS: remove Saved Arena + MapLab UI, stores, models, routes, tests, pbxproj | Integration* (Features/Services/Domain, pbxproj); iOS targeting for `Targeting/MapLab/*` via handoff | leaf features; `check-xcode-sources.py` passes because deletions and pbxproj edits land together |
| R2 | iOS: Quick Duel is the only realtime mode (controller sighting-only; no map/collab/`niToken`/`frameReady` sent); `LobbyStore` always requests sighting | Integration* | server still accepts the removed messages, so mixed client versions keep working |
| R3 | iOS: delete `SharedArena`, `DuelFrame`, Nearby, `SharedOrigin`; rename diagnostics; remove NI usage string | iOS targeting (`Targeting/**`) + Integration (pbxproj, Info.plist) | no consumer remains after R1–R2; report wire shape unchanged |
| R4 | iOS: drop `CombatTransport` package (if O10 = delete) | Integration | no importer after R3 |
| R5 | Worker: remove map, collab, `niToken`; `schema_migrations` v2 (drop tables, accept 1→2); benchmarks | Integration* | clients from R2 never send these; unknown types already refused [B1 W-1..W-4]; migration tested on fresh **and** pre-populated DO storage |
| R6 | Copy: delete Saved-Arena/scan/align/arena strings reachable at 2 players (§6.3); roster-full → "This match is full (2 players)."; spectator "WAITING FOR HOST" | Integration* (iOS copy) + Spectator + Design (slice copy) | string changes + string-table test |
| R7 | Protocol: sighting is the only geometry (`DEFAULT_RULES`, union, simulation collapse, fixture regen) | Integration (+ Backend for `selectCombatGeometry`) | key paths unchanged → `rulesSchemaHash` unchanged (F6); `combat.v1.json` regenerated and all three contract-fixture suites re-run in the same PR |
| R8 | Protocol v2: drop `frameEpoch`, `frameReady`, `pose.observations`, `slowField`, `collab` limits; `calibrating` → `ready`; legacy `observation` key (after N4 ships) | Integration + Backend + Spectator | one atomic contract bump with new `rulesSchemaHash`, `protocolVersion: 2`, min/max protocol fields in `release-manifest.json`; rollback runbook applies |
| R9 | Docs/design prose prune; design slices marked superseded | Integration + Design | docs only |

R1–R4 (iOS) and R5 (Worker) may proceed in parallel once R2 has merged; R5 must not precede R2. R8 is deferrable debt: nothing in the product is mixed-state while it waits. Each iOS step also needs `pnpm verify:ios` on macOS because only that runner catches pbxproj drift [B1 §8 risk 2].

### 4.4 Removal acceptance (code tier)

- `rg -n "SharedArena|DuelFrame|MapLab|SavedArena|NearbyRendezvous|collab|niToken" ios services packages convex spectator scripts contracts` returns only ADR/design/research history and the renamed diagnostics type (after R5); `frameReady|frameEpoch|trackedBody|phoneProxy` likewise after R8 [B1 §9].
- A sighting match reaches `running` on host `start` with no `frameReady` command in the Worker (simulation/Worker test), at roster 2 now and 2/3/4 once N2 lands.
- Debug fire still passes `g2.v1.json`-driven tests; `ReportProblemView` still uploads a log that `report.ts` renders; `check-release-manifest.mjs` passes with manifest changes only in R7/R8.

## 5. Identity architecture

### 5.1 The five two-player seams, and what each becomes

| Seam | Today [repo] | Becomes [proposal] | Slice |
|---|---|---|---|
| iOS lobby | `QuickDuel.maxPlayers = 2`; `rosterFullMessage` names Saved Arena | `LIMITS.players` (4); count-aware copy | R6 (copy), N8 (cap) |
| Convex | `QUICK_DUEL_MAX_PLAYERS = 2`; `QUICK_DUEL_FULL` at create/join/prepare; `config.ts maxPlayers: 2` | cap = `LIMITS.players`; `QUICK_DUEL_FULL` at 4; `prepare` unchanged otherwise (≥ 2, all connected and ready) | N8 |
| Authority | `opponents.length !== 1 → ambiguousTarget`; `targetPlayerId === opponents[0]` | §5.4 rule | N2 |
| `associateSighting` | exactly one connected remote → that player, `marginMeters = .infinity` | returns a candidate list (§5.2) | N4 |
| `TargetingSession` | one body per frame (`.max(by: score)`) | all scored bodies kept for the frame; the aimed body (reticle-nearest by the existing score) is the one whose colliders are sent; `bodiesInView` and per-body score exported | N4 |
| `fireOnce` | one `observation`, constant `uncertaintyMeters: 0.08` | one `sighting` (§5.3); uncertainty stays the constant until measured (it is not an identity input) | N4 |

### 5.2 Client candidate generation

Candidate hierarchy [proposal; B2 §7, B3 §4.2, B4 §4.2 reconciled]. The client always produces a distribution over **living, connected opponents** as it currently believes them from the snapshot; every tier falls through to the next when unavailable.

| Cue | When | Candidates / confidence | Hardware | Evidence status |
|---|---|---|---|---|
| `sole` | exactly one living, connected opponent (always true at roster 2; at 3–4 when others are dead/respawning/disconnected) | `[{V, 1.0}]` | none | code-tier today; device-unmeasured |
| `bearing` | shooter and a candidate both UWB with fresh plain-NI `direction` (age ≤ A) | argmin angular residual between the aimed body ray and each peer's rotated `direction`; confidence from residual margin | UWB on **both** phones; permission | Apple documents device-relative direction and nil semantics [Apple 5–7]; angular error on moving phones is **unmeasured** [B3 §6] |
| `appearance` | a track that was labelled by `sole`, `bearing` or `manual` earlier this match is re-seen | descriptor similarity per labelled player; confidence = best − second | none (mask-cleaned where available) | **unmeasured**; degenerates with similar clothing [B2 §3.6, §9] |
| `track` | the aimed body continues a track labelled within a horizon H | carried label; weaker with `trackAgeMs` | none | Vision gives no track id [Apple 1–2]; association hand-rolled; swap rate unmeasured |
| `manual` | shooter tapped an opponent chip before firing (only if O3 enables it) | `[{chosen, 1.0}]` | none | gameplay change; product decision |
| `none` | several survivors and no cue separates | all survivors at `1/n` | none | the honest default; the authority refuses it |

Inference that matters for sequencing: `appearance` and `track` **need a label source**. Without `bearing` or `manual`, labels can only be seeded in `sole` moments, which in a 3–4-player match occur only while other opponents are dead, respawning or disconnected. Appearance is therefore a *multiplier* on another cue, not an independent one [inference from B2 §7 item 3].

Rejected and not built: face recognition (biometric templates, no Vision identity API, no persistent accounts) [B2 §3.8]; BLE RSSI (no bearing, permission cost) [B3 §5]; assigned team colours, wearables, visible markers, phone-screen beacons (`AGENTS.md` markerless rule; screen glow is an open product question, O12) [B2 §3.6–§3.7]; Camera Assistance (requires `ARWorldTrackingConfiguration` for `setARSession`; the live session runs `ARBodyTrackingConfiguration`; documented best for stationary peers) [B3 §4.3][Apple 8–9]; `VNDetectHumanBodyPose3DRequest` and `ARBodyAnchor` as identity sources (single-body surfaces) [B2 §3.4–§3.5]; per-pair frame estimation (§3.2 item 2).

### 5.3 Wire shape (additive under protocol v1)

```ts
export interface BodyCandidate {
  targetPlayerId: string;            // roster member ≠ shooter; unique in list
  confidence: number;                // 0..1, client belief (quality hint, not proof)
  cue: "sole" | "bearing" | "appearance" | "track" | "manual" | "none";
}
export interface SightingObservation {
  capturedAtMs: number;              // as today
  bodyConfidence: number;            // today's associationConfidence semantics (Vision joint confidence)
  uncertaintyMeters: number;         // as today
  colliders: readonly BodyCollider[];// 1..32, the ONE aimed body, shooter camera space
  bodiesInView: number;              // 1..8, Vision/ARKit bodies this frame
  trackAgeMs: number;                // 0..60_000, age of the label on the aimed body
  candidates: readonly BodyCandidate[]; // 1..LIMITS.players-1, sorted by targetPlayerId
}
// fire: {kind, shotId, poseSequence, origin, direction, observation?, sighting?}  — exactly one of the two
```

Bounds and validation [proposal; B4 §4.1, §4.7]: exact-key validation as for every existing message (`validation.ts`); `candidates` length 1…3, unique ids, sorted (a mis-sorted list is `invalidInput`, so the canonical fingerprint has one encoding); confidences finite in [0, 1] and summing to ≤ 1 + 1e-6; `fire` carrying both `observation` and `sighting` is `invalidInput`. Legacy `observation` is mapped by the simulation to `sighting{candidates:[{target, 1, "sole"}], bodiesInView: 1, trackAgeMs: 0}` so every existing `sighting.test.ts` verdict and `combat.v1.json` envelope is unchanged. Growth ≈ 300 bytes worst case, inside `messageBytes` (16 KiB); no `LIMITS` constant changes [B4 §4.1]. **No new event `kind`**: `projectileTerminal` gains optional `attribution` fields, because shipped iOS decoders throw on unknown kinds but ignore unknown keys [B4 §4.7]. **Margin is not a wire field**: it is `top − second` over the filtered candidates, computed by the DO and written to the ledger; a client margin would be redundant and could disagree.

### 5.4 Durable Object attribution rule

Applied inside the existing sighting branch (F1), in this order, deterministic over the ordered command batch [proposal]:

1. **Shape.** Validate `sighting` as above; `bodiesInView < 1` → `noSighting`.
2. **Freshness and quality.** Unchanged gates: `capturedAtMs ≤ now` (`futureInput`), age ≤ `COVER_OBSERVATION_MS`, `bodyConfidence ≥ 0.8`, `uncertaintyMeters ≤ 0.1`, colliders non-empty → else `noSighting`.
3. **Roster filter.** Drop candidates that are not roster members, equal the shooter, are dead/respawning, or are disconnected. A candidate id not in the roster at all is `invalidInput` (preserves today's `sighting.test.ts` "mismatched targetPlayerId" verdict). Zero survivors → `noSighting`.
4. **Renormalise** survivors' confidences to sum 1.
5. **Separation.** One survivor → it. Two or more → top wins iff `top − second ≥ margin` (proposal `0.35`); otherwise `ambiguousTarget`. Candidates with equal confidence can never pass a positive margin, so there is no tie-break rule; `targetPlayerId` ascending is used only to make the ledger's candidate order canonical.
6. **Geometry.** `resolveSighting` on the supplied colliders against the attributed player: `bodyHit` / `shieldBlocked` / `missExpired` as today (health and `protectedUntilMs` checked there).
7. **Attribution flag.** `projectileTerminal.attribution = {basis: "sole" | "separated", corroboration: "shooterOnly"}` (the only value reachable today; §7).

Deliberately absent: health-based tie-breaks, split damage, redirecting to a player the shooter did not name, and any veto from a client's self-reported ambiguity [§3.2 items 4–5, 7][B4 §4.3][B6 §4.6]. Refusals stay free (no ammo, no cooldown — F1), so the player can re-aim immediately.

### 5.5 Two-player special case

Roster `{S, V}`: client emits `[{V, 1, "sole"}]` (or legacy `observation`); filter keeps V if alive and connected; margin `1 − 0` passes; geometry unchanged. The only observable differences from today are the ledger row and the additive `attribution` field [B4 §6]. One deliberate behaviour change to confirm (O13): today a sighting shot at a *dead* or *disconnected* sole opponent passes the `opponents.length` check and resolves in `resolveSighting`; under step 3 it becomes `noSighting`. `sighting.test.ts` L80–83 ("3-player roster → ambiguousTarget") is **rewritten**, not deleted: 3-player with `none` candidates → `ambiguousTarget`; 3-player with one living opponent → `bodyHit`; 3-player separated → `bodyHit` on the named player.

### 5.6 Verdict ledger

A DO SQLite table `sighting_verdicts`, one row per sighting `fire` (accepted or refused), written in the same `transactionSync` commit as the events so it cannot diverge from the verdict; bounded per match (one row per admitted fire; weapon cadence bounds the count) and retained with the room (24 h idle retention) [B4 §5][Cloudflare 1–2 via B6]. This replaces nothing: `BulletLedger` stays the projectile record, and Convex `verdict-ledger.v1` (host adjudication) is left untouched pending O7.

| Field | Why a dispute needs it |
|---|---|
| `matchId, authorityEpoch, eventSequence` | join to events and match reports |
| `shotId, shooterPlayerId, clientSequence, commandFingerprint` | proves the stored input is the admitted input |
| `sentAtMs, receivedAtMs, capturedAtMs, matchTimeMs` | freshness is the most common refusal |
| `origin, direction` | shooter's ray as submitted |
| `bodiesInView, bodyConfidence, uncertaintyMeters, colliderCount, colliderHash, trackAgeMs` | what the camera saw, without storing geometry beyond the pruned command |
| `candidatesSubmitted` `[{targetPlayerId, confidence, cue}]` ≤ 3 | the client's claim, verbatim |
| `candidatesAfterFilter` + `filterReasons` | which roster rule removed whom |
| `marginTop, marginSecond, marginRequired` | the arithmetic of the decision |
| `attributedPlayerId` (nullable), `basis`, `corroboration` | the verdict and its evidence class |
| `reason` | `bodyHit / shieldBlocked / missExpired / ambiguousTarget / noSighting / invalidInput / futureInput` |
| `zone, damage, targetHealthBefore, targetHealthAfter` | outcome |
| `peerSightingsInWindow` `[{playerId, capturedAtMs, namedShooter}]` | ledger-only mutual-sighting record (§3.2 item 4) |

Exposure: rendered by `report.ts` into the existing Worker match report and exportable per match by an operator script for §8 scoring [B7 §8.2 E5]. It contains no images, no descriptors and no device identifiers.

## 6. Product model, lobby and HUD

### 6.1 Model [B5 §4, proposal]

One mode (**Quick Duel**), one noun per concept: a **match**, **players**, a lobby **code**. No player-visible "arena", "play area", "scan" (except QR), "align", "reference", "map", "frame", "shared" or "sync". Flow: Home → `QUICK DUEL` or `JOIN DUEL` → lobby (code + QR, `n/4`, ready pills) → host `START` when all present players are ready (≥ 2) → 3-2-1 → live → results → rematch. The fourth slot being empty never blocks start; no screen asks anyone to point at, stand near, face or wait for anyone.

### 6.2 Lobby and HUD states

- **Roster rows**: slot glyph + colour (●1 ▲2 ■3 ◆4), name, `HOST`/`YOU`, `READY`/`NOT READY`/`DISCONNECTED`. Colour is never the sole carrier of identity [Apple 10–11 via B5]. Slot is a Convex-assigned lobby fact carried into the combat roster (new field; absence today) [B5 §5.2]. It is presentation only and never a camera signal.
- **Capability badge** (only if the chosen cue is hardware-dependent, i.e. `bearing`): neutral "Limited targeting" with an info sheet; never blocks ready or start [B5 §5.4]. Any NI permission prompt is asked at READY, and denial degrades rather than blocks (O4).
- **Live HUD**: local health and time; an opponent strip (glyph, short name, health, live/respawning/disconnected) visible without opening the menu; kill feed (last 3); incoming hit names the shooter from the authority's `shooterId` [B5 §6.2–§6.3]. No directional arrow (there is no shared frame to compute one) [inference].

| State | Cue on the aimed body | Trigger result |
|---|---|---|
| No body | none | shot sent without `sighting`; authority `noSighting` → "No one in your sights" |
| Body, one candidate separates (identified) | frame + that player's glyph, colour and name; matching strip chip highlighted | shot sent; outcome from authority |
| Body, candidates do not separate (ambiguous) | neutral frame with "?", never a name or another player's colour | **shot still sent** with its honest candidates [proposal, resolving B5 O4]: the authority is the single decision point, the refusal is free (F1), and the ledger then measures ambiguity rate; feedback "Can't tell who that is — get a clearer look" |
| Accepted hit | hit marker + "Hit ▲ Maya · torso −25" from `projectileTerminal` | — |
| Hit on me | red border + "Hit by ◆ Sam" | — |
| Limited identity on my phone | persistent small tag "Limited targeting — hits need a clear view of one player" | play continues |
| Disputed / shooter-only attribution | results screen lists hits per shooter; no in-match "disputed" badge until a corroboration class other than `shooterOnly` exists (§7) | — |

Honesty caveat: "Hit Maya" means the authority accepted the shooter's phone's attribution. Victim-side naming of the shooter is the product's main in-room check on misattribution [B5 §6.4].

### 6.3 Copy deletions (complete list in [B5 §8])

Delete now (R6, reachable at 2 players): Home "Your world. The arena.", the "Saved Arenas are the 2–4 player mode" subtitle, "SAVED ARENAS", "Create a 2–4 player match in a saved arena.", "Saved Arena tools", "SCAN & SAVE A PLAY AREA"; `WaitingRoomCopy` `.savedArena` strings ("Arena", "Align arena", "All players ready. Next, align your shared play area.", "You're ready. Waiting for the host to begin alignment."); "… players · Shared play area"; `LobbyStore` "JOIN ARENA" → "JOIN DUEL"; roster-full "Quick Duel is 2 players; use a Saved Arena for 3–4" → "This match is full (N players)."; `RealtimeCommandState` "…the arena reference." → "Tracking needs a fresh view of players." and "…when the arena is ready." → "The action was not accepted. Try again."; `ambiguousTarget` "Too many players in view." → "Can't tell who that is — get a clearer look" (the current string misdescribes a roster-size rule, F1); `RealtimeCombatSession` "…join a new arena." → "…join a new match."; spectator "ALIGNING ARENA" → "WAITING FOR HOST"; "Find a clear play area." → "Find a clear, open space.". Delete with the feature (R1–R3): every stage title, guidance and menu string of the scan/share/align/reference/map flows. Keep: "SCAN QR CODE" (QR), `hitscan` (wire value). Singular-opponent strings ("Waiting for opponent", "Both players ready…") become count-aware at N8. Classic-mode "arena" strings are outside this decision (O14).

## 7. Trust model

Trusted facts are unchanged from BIO-36: ticket claims (roster, `playerId`, match), connection identity, DO receive clock, sequence/fingerprint state [B6 §3]. Everything in `sighting` is a client claim.

| Condition | Behaviour | Scope | Why |
|---|---|---|---|
| Structural/temporal invalid (shape, future, stale, low quality, empty colliders) | **Closed**: refuse shot | shot | honest clients never send these |
| Candidate not on roster / self | **Closed**: `invalidInput` | shot | as today |
| Candidate dead / respawning / disconnected | **Closed**: filtered; zero survivors → `noSighting` | shot | frame-free, DO-owned facts |
| ≥ 2 survivors that do not separate by margin | **Closed**: `ambiguousTarget` | shot | refusing is never unfair; guessing is |
| Survivors separate, no corroboration available | **Open**: apply, `corroboration: "shooterOnly"` | shot | zero-setup means first-shot corroboration never exists; closing re-creates a gate [B6 §7] |
| Client self-reports several bodies | recorded; may self-refuse on the shooter's own phone; never raises ambiguity for another player | shot | a self-report is a poisoner's tool [B6 §4.6] |
| NI/BLE sample present | input to the shooter's own candidate confidences only; never a DO verdict input; logged | shot | unauthenticated, unavailable on part of the mix [B6 §4.2] |
| Identity source missing on a phone | that phone falls back to `sole`/`none` | shot | same algorithm on all phones [B2 §4] |
| Any identity uncertainty | **Never** pauses, blocks start, or returns to setup | match | denial must not have match-wide payoff [B6 §7] |

Forbidden as security inputs [proposal, consolidating B2 §6, B3 §7, B4 §4.1, B6 §4]: `confidence`, `cue`, `bodyConfidence`, `uncertaintyMeters`, `bodiesInView`, `trackAgeMs`, appearance scores, NI `distance`/`direction`, BLE RSSI, and any peer's self-reported pose or sighting. Also forbidden as mechanisms: face templates, anything worn, screen beacons, and any cross-phone frame estimate. Additive DO-side guards that stay within this model and need no device data: per-shooter, per-target hit accounting in the ledger; a flag (not a refusal) for implausibly perfect confidence distributions [B6 §4.3, §5.4]. Collusion by two of four players defeats every cross-client check; the model provides fairness among honest clients and auditability, not anti-cheat [B6 §4.4, §5.5]. App Attest remains the BIO-36 future tier and is not required here.

## 8. Physical acceptance matrix

Rules: named device models and iOS versions, probe results, `releaseSha`, Worker version tag and Convex deployment recorded per `docs/build-log.md`; a Code, Simulator or Staging result never closes a Physical row; every physical contradiction of a code-tier assumption becomes a fixture [B7 §6, BIO-36 §15]. **No target value below is a measurement.**

### 8.1 Device classes and rosters [B7 §4–§5]

Classes by runtime probe: **L+/L−** (LiDAR via `supportsSceneReconstruction(.mesh)`), **U0** (no precise distance), **U1** (distance + direction), **U2** (extended distance; model mapping is repository copy, not Apple fact). Rosters: P1–P3 (2 phones, LiDAR mix — baseline), Q1 (U1/U1), Q2 (U1/U0), T1 (3 × U1), T2 (U1, U1, U0), T3 (3 × U0), F1 (4 × U1), F2 (U1, U1, U0, U0), with depth mixed across T/F for thermal. Minimum distinct hardware: four phones — L+U1, L−U1, L−U0, plus one more U1 [B7 §5 inference]. Capability gap to close first: `DeviceCapabilityReport` has no UWB fields and is not attached to `MatchReport` (E1) [B7 §2 R7].

### 8.2 Rows

| Id | Scenario | Rosters | Metrics |
|---|---|---|---|
| S0 | last `setReady` → first accepted/refused fire, no setup UI | P1–P3, T1, F1 | time-to-first-shot per phone; permission prompts |
| S0b | 5th joiner | F1 | "This match is full (4 players)." with no mode suggestion |
| S1 | two opponents side by side (0–1 m) at 3/5/8 m | T1–T3, F1–F2 | identity precision/recall, misattribution, refusal rate, candidate-margin distribution, NI direction availability, bearing vs angular separation |
| S2 | crossing | T1–T3 | swap rate per 20 crossings (track only / + appearance / + bearing) |
| S3 | partial occlusion of the target, other fully visible | T1, T3 | misattribution; zone correctness |
| S4 | similar clothing, position swap after a 1 s camera blink | T1, T3 | appearance-margin distribution; post-swap misattribution |
| S5 | one opponent behind another | T1, F1 | misattribution; NI `nil` rate for the occluded peer |
| S6 | opponent out of view; fire at empty space | T1–T3 | out-of-view misattribution; false hits on empty space (must be 0) |
| S7 | non-player bystander | T1, T3 | bystander attribution rate per cue |
| S8 | 3 min at cap with kills/respawns | F1, F2 | K/D agreement with referee; stalls; `authorityEpoch` bumps |
| H1–H3 | 5 min at 2/3/4; with/without 3 `NISession`s; forced thermal states | all | camera fps, Vision completion rate, `thermalState` transitions, battery delta |
| L1 | daylight, shade, dusk; motion blur while panning | T1, T3 | body-pose recall/precision per band |
| X1 | NI permission denied; U0 shooter; unsupported device | Q2, T2 | play continues; cue falls back; no gate |
| X2 | NI plain sessions coexisting with the `ARBodyTrackingConfiguration` targeting session | Q1, F1 | camera ray unaffected; no `activeSessionsLimitExceeded` / `resourceUsageTimeout` |

Metric definitions follow [B7 §6.4]: precision = attributed-to-X-and-labelled-X / attributed-to-X; recall = labelled-X-and-attributed-X / labelled-X (refusals count against recall only); misattribution = accepted shots attributed to someone other than the labelled target / accepted shots.

### 8.3 Measurements required before an ADR commits

- **Before committing to UWB `bearing`:** Q1 direction availability and angular error between two *moving, hand-held, portrait* phones at 3/6/9 m; T1/F1 three concurrent sessions per phone without session-limit errors and their update rate; X2 coexistence with the body-tracking session; S1 bearing separation at ≤ 1 m spacing and 6 m range; S5 occlusion `nil` rate; H2 thermal delta; X1 fallback. Apple documents none of these numbers [B3 §3.4, §6].
- **Before committing to appearance descriptors / tracks:** S2 swap rate, S4 margin distribution (similar vs distinct clothing), L1 lighting bands, how often a label can be seeded (share of match time in `sole`, `bearing` or `manual` state), H1 cost of descriptor + mask [B2 §9].
- **Before raising the cap at all:** S0/S0b/S6/S7/S8 at T and F rosters, plus the first measured misattribution rate so the owner can set O6. Every row reports against a SHA that passed `combatNotVerifiedForSha` with `serverRelease == firstServerRelease` [B7 §10].

### 8.4 Evidence capture to build first [B7 §8.2]

E1 UWB capability fields in `DeviceCapabilityReport`, attached to `MatchReport`; E2 1 Hz fps/thermal ring in the duel loop; E3 debug-only **trial mode**: shooter taps the intended victim before each shot (ground truth), phone logs visible-body count, per-body box and score, NI samples, pose age and emitted candidates keyed by `shotId`, joined offline with the §5.6 ledger; E4 referee sheet; E5 per-match ledger export; E6 indexed screen recordings. Trial mode is never shipped to players and contains no device identifiers.

## 9. Code-tier fixtures missing today [B7 §9]

Absent and required before Physical rows can be scored: any ≥ 3-player sighting fixture where a fire is *accepted*; `combat.v1.json` with roster > 2; a four-client sighting load scenario (current load/benchmark runs use `trackedBody` + `frameReady`); an XCTest for a successful 3–4-player association; a `TargetingSession` two-body reduction test from recorded frames; a Worker migration test on a pre-populated store; a staging `--verify` probe room with more than two players (the current probe room is `maxPlayers: 2` and must change with the cap).

## 10. Open decisions, each with a recommended default

| # | Decision | Recommended default |
|---|---|---|
| O1 | Which discriminating cue is attempted first | Build E3 trial mode; measure `bearing` (UWB pairs) and `appearance`+`track` in the same trials against manual ground truth; commit in ADR 0015 only to what passes §8.3 |
| O2 | Does any NI code survive removal | Delete all NI in R3/R5; re-introduce a minimal identity-purpose per-peer session + token exchange only if O1 selects `bearing` |
| O3 | Manual target tap as gameplay | Not enabled by default; approved as the fallback cue if O1's candidates miss the O6 threshold, because it is the only zero-hardware cue that separates 3–4 opponents |
| O4 | When NI permission is requested | At READY in the lobby, never before PLAY; denial degrades to `sole`/`none` |
| O5 | Ambiguity margin | `0.35` placeholder until S1 margin distributions exist |
| O6 | Release misattribution threshold | Set by the owner after the first T1/T3 trial; cap stays 2 until set and met |
| O7 | Convex `verdict-ledger.v1` | Leave untouched (host-adjudication artefact); the DO ledger is new and separate |
| O8 | Owner of `packages/**`, `services/**`, `ios/**/Features|Services|Domain/**` | Integration, recorded in `AGENTS.md` by Integration before R1 |
| O9 | `DuelPeerLink` tracer (`Features/Game/DuelPeerLink.swift`, conforming `CombatTransportArenaLink`/`FallbackArenaPeerLink`/`ArenaPeerLink`): debug-fire scope or shared-frame | Remove the link protocol and tracer methods with R3 and keep the rest of classic `DuelSession` (B1 §3.11, I-14); the debug-fire owner confirms before R3 |
| O10 | `CombatTransport` package | Delete in R4 if no importer remains after R3 |
| O11 | `combatGeometry` compatibility window in `matches.create` | Accept only `"sighting"` for one release, then drop the argument |
| O12 | Is a phone-screen glow a "visible target marker" | Treat as one (not built) unless the owner rules otherwise |
| O13 | Shots at a dead/disconnected sole opponent become `noSighting` | Adopt (fairness; frame-free fact), called out in the N2 PR |
| O14 | Classic (geofenced) mode "arena" copy | Out of scope; left to the debug-fire owner |
| O15 | Protocol v2 timing | After N4 has shipped the `sighting` key to all supported clients; bundle the `calibrating` → `ready` rename |
| O16 | Tighten sighting freshness from 1 000 ms toward `rewindMs` (250 ms) [B6 §4.5] | Keep 1 000 ms until trial mode measures capture-to-fire latency |
| O17 | Name at 3–4 players | Keep "Quick Duel" |

## 11. Implementation slices (dependency order: removal first, identity second, cap last)

| Slice | Owner | Files (principal) | Tests | Evidence required |
|---|---|---|---|---|
| R0–R9 | §4.3 | §4.1 | §4.4 | code tier + `pnpm verify` (and `pnpm verify:ios` for iOS steps) per PR |
| N1 Protocol: additive `sighting`, `BodyCandidate`, optional `attribution` on `projectileTerminal` | Integration | `packages/combat-protocol/src/index.ts`, `validation.ts`; `contracts/fixtures/combat.v1.json`; `docs/interface-contracts.md`; iOS `CombatWire.swift` decode of `attribution` | exact-key, bounds, sorting, both-keys-refused; three contract-fixture suites; `check-release-manifest.mjs` (hash unchanged — no rules keys move) | code |
| N2 Simulation: §5.4 rule; legacy mapping | Integration* | `packages/combat-simulation/src/index.ts`, `flight.ts` | rewrite `sighting.test.ts` L80–83; new 3/4-player cases (sole-by-elimination, separated, not separated, dead/disconnected filtered, non-roster `invalidInput`); 2-player regression; replay determinism | code; cap still 2 in Convex |
| N3 DO ledger | Integration* | `services/combat-worker/src/store.ts` (migration v3), `room.ts` commit, `report.ts`; export script | same-transaction write; bounds; migration on fresh and populated storage; report rendering | code + staging (`vkz-combat-staging`) |
| N4 iOS: multi-body targeting and candidate association | iOS targeting (`TargetingSession`) + Integration* (`RealtimeBodyAssociation`, `RealtimeArenaController`, HUD "?" state) | as named, plus pbxproj if files are added | two-body reduction from recorded frames; `associateSighting` returns `[sole]` at 2 and `none` at 3–4; `fireOnce` sends `sighting` | code + simulator; device behaviour unclaimed |
| N5 Evidence capture E1–E6 | iOS targeting + Integration | `DeviceCapabilityProbe.swift`, `MatchReportClient.swift`, trial-mode flag, telemetry ring | report schema tests; trial mode excluded from release builds | code |
| N6 Device campaign | Integration (records `docs/build-log.md`) | build-log entries, recordings, referee sheets | — | **Physical**: §8 rows with named devices |
| N7 Cue per O1/O3 | iOS targeting (+ Integration for any new token exchange, Info.plist) | per chosen cue | cue unit tests; re-scored trial logs | **Physical**: re-run S1–S7 with the cue on |
| N8 Cap switch and product copy | Backend (`convex/**`) + Integration (iOS lobby, `interface-contracts.md`, deploy probe, fixtures) + Spectator + Design | `convex/functions/combat.ts`, `matches.ts`, `convex/domain/config.ts`; `LobbyModels.swift`; `WaitingRoomView.swift`; `scripts/release/combat-deploy.mjs` probe room; roster slot field | `combat-admission.test.ts` at 2/3/4 and 5th refused; lobby state machine; string-table test; staging probe with 3–4 members | **Physical**: S0, S0b, S8 at T/F rosters meeting O6 |
| N9 ADR 0015 | Integration | `docs/decisions/0015-…` | — | cites N6/N7 build-log entries |

Hard ordering: R2 before R5; N1 before N2 and N4; N2 before N8; N5 before N6; N6 before N7's ADR and before N8; R8 after N4 has shipped to all supported clients. N1–N5 can proceed in parallel with R6–R9 once R2 has merged.

## 12. Absences (stated, not converted into claims)

- No physical-device evidence exists for any sighting match, two-player or more, in the repository or in any BIO-37 brief (no post-ADR-0013 entry in `docs/build-log.md`) [B7 §2 R12].
- No Apple API maps a detected body to a peer device; Vision returns anonymous observations with no track id [Apple 1–2 via B2/B5].
- Apple publishes no latency or accuracy figure for multi-person body pose, instance masks, object tracking, NI direction on moving phones, NI power, or a numeric concurrent-session cap [B2, B3, B7].
- Apple does not document whether NI accepts an `ARBodyTrackingConfiguration`-driven session [B3 §4.3][B7 §11].
- No frame-free fact lets the DO prove "V could not have been in S's view" [B4 §4.5].
- No slot/colour field exists in Convex `players` or `CombatPlayerState` [B5 §2].
- No ≥ 3-player accepted-sighting fixture, test, load scenario or staging probe exists [B7 §9].
- ADR 0012 is cited by ADR 0013 but absent from `docs/decisions/` (F11).
- No practitioner or academic source on multi-target identity in phone-AR combat was found by any brief.

## 13. Sources

Input briefs (uncommitted, 2026-09-27, each with a provenance sidecar):

- [B1] `shared-arena-removal-inventory.md` (+ `.provenance.md`)
- [B2] `vision-opponent-identification.md` (+ `.provenance.md`)
- [B3] `radio-ranging-identification.md` (+ `.provenance.md`)
- [B4] `multi-target-protocol-authority.md` (+ `.provenance.md`)
- [B5] `roster-ux-multiplayer.md` (+ `.provenance.md`)
- [B6] `trust-multi-target.md` (+ `.provenance.md`)
- [B7] `device-validation-multiplayer.md` (+ `.provenance.md`)

Repository (`main` `3d89b7f`):

- [R1] `AGENTS.md` — ownership table, Phase 1 cap 4, markerless rule, debug-fire rule, physical-evidence rule, `pnpm verify`.
- [R2] `docs/research/zero-step-architecture-synthesis.md` and `.provenance.md` (BIO-36).
- [R3] `docs/decisions/0010`, `0011`, `0013` (and absence of 0012).
- [R4] `packages/combat-protocol/src/index.ts`, `validation.ts`.
- [R5] `packages/combat-simulation/src/index.ts`, `flight.ts`, `history.ts`; `tests/sighting.test.ts`.
- [R6] `services/combat-worker/src/room.ts`, `store.ts`, `report.ts`, `bullet-ledger.ts`, `routes.ts`.
- [R7] `convex/functions/combat.ts`, `matches.ts`, `schema.ts`; `convex/domain/config.ts`, `fire.ts`.
- [R8] `ios/VictoriaKillZone/VictoriaKillZone/{Targeting/TargetingSession.swift, Features/Realtime/{RealtimeBodyAssociation,RealtimeArenaController,RealtimeCommandState}.swift, Domain/LobbyModels.swift, Info.plist}`.
- [R9] `docs/interface-contracts.md` (Realtime combat v1); `release-manifest.json`; `scripts/ci/check-release-manifest.mjs`, `check-xcode-sources.py`, `verify-ios.sh`; `contracts/fixtures/combat.v1.json`; `scripts/release/combat-deploy.mjs`.

Primary documentation (as fetched and quoted by the named brief, 2026-09-27; not re-fetched here):

1. Apple — `VNDetectHumanBodyPoseRequest` — https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest (B2, B5, B6, B7)
2. Apple — Detecting Human Body Poses in Images ("returns a unique observation for each detected human body pose") — https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images (B2, B5, B7)
3. Apple — `ARBodyAnchor` ("tracks the movement of a single person") — https://developer.apple.com/documentation/arkit/arbodyanchor (B2, B5, B6)
4. Apple — `ARFrame.detectedBody` (single optional `ARBody2D`) — https://developer.apple.com/documentation/arkit/arframe/detectedbody (B2, B5, B6, B7)
5. Apple — `NINearbyObject` (distance/direction may be nil; direction relative to the local device) — https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject (B2, B3, B6)
6. Apple — Initiating and maintaining a session (best within 9 m, portrait, rear cone; people/walls block) — https://developer.apple.com/documentation/nearbyinteraction/initiating-and-maintaining-a-session (B3, B6, B7)
7. Apple — `NIDeviceCapability` — https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability (B3, B7)
8. Apple — `NISession.setARSession(_:)` (requires `ARWorldTrackingConfiguration`) — https://developer.apple.com/documentation/nearbyinteraction/nisession/setarsession(_:) (B3)
9. Apple — WWDC22 10008 What's new in Nearby Interaction (camera assistance best for stationary devices; one ARSession per app) — https://developer.apple.com/videos/play/wwdc2022/10008/ (B3)
10. Apple HIG — Accessibility ("Convey information with more than color alone") — https://developer.apple.com/design/human-interface-guidelines/accessibility (B5)
11. Apple HIG — Color — https://developer.apple.com/design/human-interface-guidelines/color (B5)
12. Apple — WWDC20 10668 Meet Nearby Interaction (several sessions per device; four devices × three sessions) — https://developer.apple.com/videos/play/wwdc2020/10668/ (B3)
13. Apple Support — Ultra Wideband availability — https://support.apple.com/en-us/109512 (B3)
14. Cloudflare — In-memory state in a Durable Object — https://developers.cloudflare.com/durable-objects/reference/in-memory-state/ (B6) [Cloudflare 1]
15. Cloudflare — Durable Objects Alarms — https://developers.cloudflare.com/durable-objects/api/alarms/ (B6) [Cloudflare 2]
