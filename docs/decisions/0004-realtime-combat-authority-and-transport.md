# ADR 0004: Realtime combat plane — host-phone authority over peer transport, Convex as durable ledger

- **Status:** Proposed (2026-09-02). Acceptance requires the KIL-21 physical-device measurements named in "Acceptance evidence" below; product owner confirms via KIL-32.
- **Date:** 2026-09-02
- **Decision owners:** Product and integration

## Context

ADR 0003 split the architecture into a realtime combat plane (L1) and Convex as durable authority (L2), and deferred the concrete authority and transport choice to this record. Since then the L1 pieces exist as tested, unlinked packages — `shared/simulation` (deterministic 20 Hz core, bounded rewind, canonical same-tick ordering; KIL-34) and `ios/VictoriaKillZone/Transport/CombatTransport` (host/relay Network.framework peer plane; KIL-35) — while the shipping game still adjudicates shots in `convex/domain/fire.ts` from a client-supplied target, zone, and confidence. The 2026-09-02 mechanics review (build log) confirmed the consequence: neither the simulation core nor the transport is reachable from the app or from Convex, so no fair, multiplayer, or accountable verdict exists in the product today.

[docs/research/realtime-backend-options.md](../research/realtime-backend-options.md) evaluated the authority models with primary sources and recommends, for the co-located Phase 1 product, host-phone authority with provisional local verdicts and Convex durable confirmation, with cloud authority (Nakama or a Durable Object per match) as the scale path behind the same simulation core. The research explicitly asks that the decision be frozen only on measured numbers.

## Decision

1. **Authority.** One `MatchSimulation` instance per match is the sole source of shot verdicts. In Phase 1 it runs on the **host phone** (`CombatTransport` slot 0) behind an `AuthorityHost` interface. Clients never adjudicate; they predict presentation (`SHOT PREDICTED`, incoming tracers) and wait for the host verdict. Host migration is out of scope for Phase 1: if the host leaves, the match ends and Convex records it.
2. **Transport.** The `CombatTransport` package is the peer plane: QUIC reliable stream for fire and control events, QUIC datagrams for latest-state poses at 20–30 Hz, Bonjour discovery with peer-to-peer Wi-Fi enabled. The transport gains a **chunked bulk stream** so `ARWorldMap` and `ARCollaborationData` ride the same plane; the KIL-20 harness's private TCP link is retired when that lands.
3. **Convex's role narrows to the ledger.** `shots:fire` stops adjudicating markerless claims. The host posts terminal `ShotVerdictRecord`s (shot identity, shooter, resolved target, zone, applied damage, rewind ms, verdict or rejection reason) to a new `shots:recordVerdict` mutation. Convex owns lifecycle, health/score/respawn projection, the shot ledger, and spectator projections, and is the tie-breaker of record if a host and a client ever disagree. `shots:debugFire` survives until spatial hitscan has device evidence (AGENTS.md).
4. **Verdict rules live only in the simulation core.** `ArenaHitEvaluator` (KIL-19 prototype) is retired; the KIL-20 shared-arena frame feeds `MatchSimulation` instead of re-implementing its rules. Hit zones are **capsule zones anchored to the phone pose** (head sphere above the phone, torso core, limbs shell) — the phone is the anchor that locates the body, not the target. This supersedes the 0.35 m sphere in `spatial-hit.v1`; integration updates the contract.
5. **Single weapon for Phase 1.** The Standard Sidearm (hitscan; 75/34/20; 350 ms; 8 rounds; 1250 ms reload) is the only weapon until the simple mechanics are proven on four phones. The weapon registry (KIL-39) stays the design of record for Phase 2; projectiles and bullet time are not built before it.
6. **Simple mechanics are core rules, not client behaviour.** Always-fire (a no-candidate shot is an authoritative miss and spends ammo), reload, respawn with 2 s spawn protection and no fire while protected, and zone damage are all implemented and tested in `shared/simulation`, then surfaced by clients.

## Acceptance evidence (turns Proposed into Accepted)

Measured on two, then four, physical iPhones outdoors, recorded in `docs/build-log.md` with device models and iOS versions:

- fire → host verdict **p95 ≤ 50 ms**;
- fire → Convex durable confirmation **p95 ≤ 500 ms**;
- pose update interval at 20 Hz target with **p99 ≤ 100 ms** (the frozen maximum pose age);
- five consecutive clean kill/respawn cycles where all phones and the spectator agree on every verdict.

If host-verdict latency or peer transport misses these budgets, the same simulation core moves behind a cloud room (research Option C finalists: Nakama, Durable Object per match) with phones on LTE/5G, and this record is revised rather than the clients.

## Consequences

- Fairness and 4-player play become properties of one tested module instead of a per-phone heuristic; the client hit claim (`targetId`, `zone`, `poseConfidence`) leaves the wire.
- The app links two local packages and the Xcode project changes accordingly (integration write set).
- `match.v2` player sets replace `maxPlayers: 2` and the `host`/`guest` binary in Convex and iOS; `resolveFire` is replaced by verdict recording.
- Cost: a host phone is a trust boundary and a single point of failure for the match; accepted for a co-located friends game, revisited at the scale trigger named in the research.

## Reconsider when

Remote play, more than four players, or host trust become product requirements; or the acceptance evidence above is not met on devices. ADR 0005 (bullet time) and the weapon registry depend on this record being accepted first.
