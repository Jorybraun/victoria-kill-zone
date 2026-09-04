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

## Transport integration (2026-09-04, KIL-35 follow-through)

Findings from reading the `CombatTransport` package, its tests and `TransportFieldHarness`, `docs/research/realtime-backend-options.md`, and Apple's Network.framework material (TN3213, `NWListener.Service` TXT records, `NWBrowser.Descriptor.bonjourWithTXTRecord`, `NWParameters.includePeerToPeer`, QUIC datagram options):

- **What already existed.** Slot-authenticated QUIC host/relay (`NetworkPeerLink`: one reliable-QUIC listener advertised over Bonjour `_vkz-combat._udp`, one datagram-QUIC listener, PSK slot claim → pairing offer/claim), the pure `PeerLinkStateMachine`, `LoopbackFabric`, a 512-byte reliable payload cap, and a chunked bulk stream (`BulkChunker`/`BulkTransferAssembler`, FNV-1a digest, 8 MiB cap, AR collaboration / world-map / handshake content kinds). The package was already linked into the app package manifest and Xcode project (`EngineLinkageTests`), but nothing in the app used it.
- **What this integration adds.** `MatchScope` (match id → hashed `scopeId`, Bonjour instance name `vkz-<scopeId>`, TXT record `match=<scopeId>`/`proto=vkz-combat-1`, PSK = SHA-256(match id, join code)); hosts advertise the TXT record, clients browse with `bonjourWithTXTRecord` and ignore services whose TXT does not match, the PSK slot claim rejects any peer that still gets through, and a first-frame `MatchHello` (control kind 0) is checked by the app adapter so a wrong-match peer fails the link before any game message is accepted. `CombatFireMessage` carries `shot(shotId, shooterPlayerId, origin, direction, firedAtMs)` and `retracted(shotId)` on the reliable `.fire` kind. `firedAtMs` is **monotonic milliseconds on the sender's clock** (`ProcessInfo.systemUptime`, the `ARFrame.timestamp` base): never wall-clock, never compared across phones; receivers order by reliable sequence and use it only for same-sender deltas. `CombatTransportArenaLink` implements the app's `ArenaPeerLinking` protocol over the package (host = slot 0, guest = slot 1, `playerCount: 2`), mapping small control messages to `.control` frames, shots/retractions to `.fire`, and `ARWorldMap`/`ARCollaborationData`/oversize control bodies to the bulk stream. The KIL-20 TCP link (`ArenaPeerLink`, `ArenaLinkCodec`) is deleted.

Deviations from decision 2, all intended to close in follow-ups (status stays **Proposed**):

1. **Poses still ride the reliable channel.** The harness `poseSample` is a full rigid transform; mapping it onto the 512-byte `PoseFrame` datagram (position + quaternion) is not done here, so QUIC datagrams are wired but unused by the app. The duel does not send poses yet.
2. **No `NWMultiplexGroup`.** The package uses two QUIC connections per peer (reliable stream + datagram flow) rather than multiplexing streams on one connection; ADR 0004 did not require the group API, but folding both flows into one connection would remove the pairing-offer round trip.
3. **QUIC identity is not provisioned by the app.** Network.framework QUIC needs a TLS server identity and the package pins the host's public key on clients (`TransportIdentityProvider`); the app passes `nil`, so the handshake cannot complete on device until an ephemeral per-match identity is minted at match start and its public key is published (TXT `pk` entry or the Convex match record). This is the first item for the two-phone run.
4. **Retraction is not yet wired in `LobbyStore`.** The message exists end to end; sending `shotRetracted` when `shots:fire` rejects a shot belongs to the LobbyStore refactor in flight (handoff noted in the build log).
5. **Match scoping is defence in depth, not authentication.** The PSK derives from the match id plus join code, both known to every legitimate player; it keeps matches apart on a shared LAN and rejects stray peers, it does not defend against a hostile player.

Two-phone run (what compile, `swift test` and loopback cannot show): Bonjour discovery over peer-to-peer Wi-Fi/AWDL between two iPhones, QUIC handshake with a real identity, fire → peer tracer visible **p95 ≤ 50 ms**, fire → Convex confirmation **p95 ≤ 500 ms**, world-map bulk transfer completing within the 8 MiB cap, and wrong-match rejection with a third phone in another match.
