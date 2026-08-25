# PEW PEW — Architecture critique and scale plan

Status: Draft for review — 2026-08-24
Owner: Integration
Purpose: This is the re-founding document. It critiques the hackathon prototype honestly, defines the target architecture for a multiplayer, scale-ready product, and sequences the path. It does not change contracts by itself; contract and stack changes flow through decision records.

## 1. Product thesis

Real-world laser tag with the feel of a modern shooter. Phones are weapons and bodies are the arena. The experience that must survive every architectural decision:

- Point at a real person, say "pew pew," and it *fires* — instantly.
- Bullets are real objects in shared space: they travel, they can be dodged, they can be slowed.
- Everyone — every player and every spectator — agrees on what happened.
- Today: 2–4 friends in a park. Tomorrow: squads. Eventually: you round a street corner and someone is *there*, in your world.

Requirements this imposes, in priority order:
1. **Multiplayer-first (4 now, N later).** No identity, contract, or authority model may assume exactly two players.
2. **Co-located now, remote-capable later.** Transport and authority must be abstractions, not assumptions.
3. **Realtime combat plane** with lag-compensated, accountable bullets (ammo, trajectory, verdict — "Call of Duty accounting").
4. **Maintainable increments.** Small slices, contracts, physical-device evidence. No one-shot rewrites.

## 2. Honest critique of the prototype

### 2.1 Fundamental limits (cannot scale; must be replaced)

| # | Limitation | Why it blocks the thesis |
|---|---|---|
| F1 | **1v1 identity is baked in everywhere.** `host`/`guest` roles, "target is the only opponent" validation, "detected human = the opponent" targeting assumption. | Multiplayer breaks the data model, the fire validation, and the perception logic simultaneously. This is the deepest assumption in the system. |
| F2 | **Screen-space 2D hit claims.** A shot is "my crosshair overlapped a body region on my screen." There is no shared space; the shooter's phone is judge and jury. | Cannot support projectiles, dodging, bullet time, 3+ player disambiguation, or any meaningful cheat resistance. Dead end for the core fantasy. |
| F3 | **No realtime plane.** Every gameplay event round-trips through Convex mutations/subscriptions; there is no tick, no interpolation, no rewind history, no clock sync. | Convex is a reactive database, not a game simulation loop. Realtime bullets need a simulation authority with time as a first-class concept. |
| F4 | **No transport or authority abstraction.** iOS talks Convex directly; adding peer transport or a relay means invasive surgery in `LobbyStore`. | Co-located→remote and 2→N are architecture changes today; they should be configuration. |
| F5 | **No identity/matchmaking layer.** Match-scoped anonymous secrets only; lobbies via code entry. | Fine for Phase 0, but open-world encounters, persistence, and progression have no place to attach. |
| F6 | **No spatial persistence.** Arena = GPS circle; no shared coordinate frame between devices. | "Same world" is the product. Two phones cannot currently agree where anything *is* in 3D. |
| F7 | **Voice = speech recognition.** `SFSpeechRecognizer` transcribing "pew pew" — high latency, locale-dependent, fails under breath/noise/repetition. | Fire input must be ~100ms and robust. Transcription is the wrong tool category. |
| F8 | **No delivery loop to devices.** Simulator-only CI; no signing automation, no OTA. | Physical-device evidence is the product's own bar, and iteration speed is capped by cables. |

### 2.2 Incidental defects (broken, but not architectural)

- Scoring/death/mechanics diverged in real play while domain tests pass → device-side reconciliation and lifecycle bugs in `LobbyStore` snapshot handling. Needs an instrumented autopsy, not a guess.
- Monolith iOS classes (`LobbyStore` ~666 lines, `ActiveDuelView` ~401, `ARVisionTargetingSession` ~480) — refactorable, and largely superseded by the new client architecture below.
- Geofence and reload are half-built scaffolds.

### 2.3 What is genuinely worth carrying forward

| Asset | Carry into |
|---|---|
| **Pure domain-layer pattern** (`convex/domain/**`): deterministic rules, exhaustive tests, idempotency fingerprints | The same discipline becomes the simulation core's rule layer — the *pattern* survives even where the runtime changes |
| **Contracts + gates + slices process** (interface-contracts, G-gates, design freezes, ADRs) | Unchanged. This is why the rewrite is survivable. |
| **Targeting state machine + Vision pose pipeline** | Perception layer (L4) — needs calibration and N-player association, not replacement |
| **Voice-fire UX concept + gating logic** | Input layer — swap the recognizer, keep the debounce/gate design |
| **Shared-3D research + KIL-17 ticket tree** (phone proxies, bounded rewind, worldlines) | This *is* the spatial+combat foundation design; it was scoped 1v1, generalize to N |
| **Spectator read-model separation** | L2 projections |
| **The fun.** Countdown → acquire → pew pew → hit flash → death → respawn worked as an experience | The product bar for every future slice |

## 3. Target architecture (the dream, in layers)

Design rule: **every layer is an interface with a co-located implementation now and a scale implementation later.** We grow by swapping implementations, never by rewriting callers.

```
L6  Ops & delivery      CI → signed build → TestFlight OTA → device evidence (Devin loop)
L5  Content systems     WeaponDefinition registry: guns, bullet types, fire modes, effects
L4  Perception (edge)   Vision pose targeting · LiDAR depth · sound-classifier voice fire
L3  Spatial layer       SharedArenaFrame provider:  peer relocalization (now)
                                                    → VPS / geo-anchors (street scale)
L2  Durable state       Match ledger, scores, replays, spectator projections  [Convex today]
L1  Realtime combat     Authoritative simulation: ticks, clock sync, pose history,
                        bounded rewind, projectile worldlines, verdicts
                        Transport: peer mesh / host (co-located)  → edge relay (remote)
L0  Identity & lobby    Match tokens (now) → lightweight accounts, matchmaking, geo presence
```

### L1 — Realtime combat plane (the heart of the rewrite)

- **One authoritative simulation** per match, defined as a pure, deterministic, platform-neutral core: state ∈ {players[N], projectiles[], time}, inputs ∈ {fire, move-sample, time-field}, outputs ∈ {verdicts, events}. Written once, embedded anywhere (host phone today, edge server later) — the same trick the Convex domain layer already proved.
- **Time is first-class:** synchronized match clock, per-player pose history ring buffers, bounded rewind (research baseline 250ms cap), projectile worldlines computed from spawn parameters — never position-streamed.
- **Authority is a deployment choice:** `AuthorityHost` interface with implementations: (a) host-phone arbiter for co-located play, (b) edge/server process for remote or trusted play. KIL-21 latency measurements + the backend research decide the default; the interface makes the decision reversible.
- **Transport is a deployment choice:** `CombatTransport` interface: MultipeerConnectivity/Network.framework mesh now; QUIC/WebSocket relay later. 20–30Hz pose exchange, event-priority fire messages.
- **N-player from day one:** player sets, not pairs. Hit validation against "a targetable player," never "the opponent."
- **Bullet accounting:** every projectile has identity, spawn state, worldline, and terminal verdict recorded to L2 — the CoD-style ledger that also powers killcams/replays later.

### L2 — Durable authority (Convex's real job)

Convex keeps what it is actually good at: match lifecycle, entitlements (ammo grants, time-field charges), terminal verdict ledger, scores, replay evidence, spectator/reconnect projections. It leaves the frame loop forever. If research/measurement later favors consolidating L1+L2 in one game-server stack, the L1 interfaces make that a migration, not a rewrite. **Decision owner: [docs/research/realtime-backend-options.md](research/realtime-backend-options.md) + KIL-21 measurements → ADR.**

### L3 — Spatial layer

- `SharedArenaFrame` provider interface: establish + maintain a common metre-based frame with quality signals (the existing CONTEXT.md vocabulary — Tracking Quality, Phone Pose Sample — generalizes).
- Now: ARKit collaborative/peer relocalization for 2–4 phones in one space (KIL-20).
- Street scale: VPS / geo-anchor providers (ARKit GeoAnchors, ARCore Geospatial, Niantic Spatial — under research R5) slot behind the same interface; open-world presence additionally needs geo-sharded L0 presence (S2-cell style), which is deliberately deferred but not precluded.

### L4 — Perception (stays on-device, feeds claims not verdicts)

- Vision body-pose targeting continues as the *aim assist and claim generator*; the spatial layer's phone proxies (and later body volumes) are what verdicts are computed against.
- N-player association problem (which detected human is which player) is solved spatially: project known player proxies into the camera frame and associate — this is why L3 precedes real multiplayer targeting.
- Voice: replace transcription with an on-device **sound classifier** (SNAudioStreamAnalyzer + small Core ML model for the "pew" utterance class); keep the existing gate/debounce design. Target <150ms trigger latency, measured.

### L5 — Content systems

`WeaponDefinition` registry drives guns, bullet types (hitscan / projectile / special like bullet-time rounds), fire modes, magazines, reload, effects. Server-owned numbers, client-owned presentation. Personal bullet time is a *content capability* on this system (target-local dodge time per existing research), gated behind projectiles passing on devices.

### L6 — Ops & delivery (the Devin loop)

Merge → CI (`pnpm verify` + sim build) → Mac Outpost: archive, sign, upload → **TestFlight internal group** → phones update over the air → Outpost promotion evidence into build-log. Apple Developer account exists (2026-08-23); App Store Connect API key via secret mechanism only.

## 4. What gets kept / completed / retired

| Prototype piece | Fate |
|---|---|
| Convex domain layer + schema | **Keep** as L2; strip 1v1 assumptions (F1) in a contract revision |
| G2 debug-fire path | **Keep** until spatial hitscan replaces it with device evidence (per AGENTS.md) |
| Screen-space hit claim as *verdict source* | **Retire** when phone-proxy hitscan lands; Vision demotes to aim-assist/claims (L4) |
| `host`/`guest` roles, opponent-singular validation | **Retire** in `match.v2` contracts (player sets, roles as capabilities) |
| `LobbyStore`/`ActiveDuelView`/`TargetingSession` monoliths | **Refactor opportunistically**; new client architecture (L1 client runtime) supersedes most of `LobbyStore` |
| Voice `SFSpeechRecognizer` path | **Replace** with sound classifier; keep gating |
| Geofence scaffold | **Complete** (KIL-23 tree) — safety is not optional outdoors |
| Reload scaffold | **Complete** as part of L5 weapon registry (don't build it twice) |
| Spectator | **Keep**, evolve into command map (KIL-24/29/30) |

## 5. Phased plan

Phases are gates, not dates. Every phase ends with physical-device evidence. B-track (bugfix autopsy on current build) runs in parallel with Phase 1 foundations under disjoint write sets.

### Phase 1 — Multiplayer foundations (the re-founding)
1. **ADR 0003:** multiplayer-first Phase 1 (supersedes 1v1-only constraints; raises player cap to 4). *Blocks everything.*
2. **Backend/authority research + decision** (this doc's companion research + KIL-19/20/21 prototypes) → ADR 0004 realtime plane.
3. **`match.v2` contracts:** N-player sets, capability roles, spatial-hit vocabulary (KIL-18/22 generalized to N).
4. **Simulation core v0** (pure, deterministic, tested): players, clock, pose history, bounded-rewind hitscan verdicts. Runs under host authority.
5. **Transport v0:** peer mesh 20–30Hz pose exchange on 2 phones → 4 phones.
6. **Shared arena v0:** relocalization + phone proxies outdoors (KIL-20), quality gates.
7. **Phone-proxy hitscan** end-to-end: fire → rewind verdict → Convex ledger → all phones + spectator agree. **Gate: 4-phone duel, five consecutive clean kill/respawn cycles.**
8. Parallel B-track: game-loop autopsy + fixes on the current build (keeps the demo alive and feeds reconciliation lessons into the client runtime).
9. Parallel: voice classifier spike; TestFlight OTA loop; design slices for calibration/verdict states.

### Phase 2 — Real bullets and the fantasy
1. Projectile worldlines in the simulation core; visible, dodgeable bullets on all devices.
2. Weapon registry v1 (2–3 guns, hitscan + projectile types); reload done properly here.
3. **Bullet time** (target-local dodge time) as an entitlement + time-field input — its own ADR + design slice.
4. Body-volume targets upgrade phone proxies (Vision + LiDAR fusion) where quality allows.
5. Spectator command map with worldlines (KIL-24 tree).
6. **Gate: 4-player projectile match with one bullet-time activation, all devices consistent, on video.**

### Phase 3 — Toward the open world (seeds only, no commitment)
1. Lightweight identity + persistent loadouts (L0).
2. Remote-capable authority: same simulation core behind an edge relay; cross-arena test.
3. VPS/geo-anchor spike behind `SharedArenaFrame` (provider chosen from R5 research).
4. Geo presence sharding research (S2 cells) + safety/consent design for street encounters. **Explicit ADR before any build.**

## 6. Decision records this plan requires

| ADR | Decides | Input |
|---|---|---|
| 0003 (proposed now) | Multiplayer-first Phase 1; supersedes 1v1 scope constraints | This document |
| 0004 | Realtime plane: authority + transport defaults | Backend research + KIL-19/20/21 measurements |
| 0005 | Personal-time semantics + activation economy | Phase 2 prototypes |
| 0006 | Spatial provider for street scale | R5 research + Phase 3 spike |

## 7. Risks and honest unknowns

- **Peer transport at 4 players outdoors is unproven here.** Mesh pose exchange at 20–30Hz × 4 phones must be measured (KIL-20/21 generalized), not assumed.
- **N-player markerless association is genuinely hard.** Spatial proxies make it tractable; anything beyond 4 players in Phase 1 is scope creep — resist it.
- **Convex verdict-latency risk** is contained by design (provisional local verdicts, durable confirmation) but must be measured before ADR 0004.
- **Open-world safety** (strangers, streets, pointing phones at people) is a product-safety design problem before it is a technical one. Phase 3 gate includes it explicitly.
- **Rewrite gravity.** The re-founding is layered precisely so the current game keeps working while L1/L3 grow beside it. If a slice can't ship without breaking the playable build, it's sliced wrong.
