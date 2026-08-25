# Realtime backend options for multiplayer PEW PEW

Status: Research complete — 2026-08-24. Feeds ADR 0004 (realtime plane authority + transport). Decision requires KIL-21 physical-device latency measurements on top of this document.
Method: Five parallel primary-source research passes (Convex, iOS peer transports, cloud game backends, established netcode architectures, street-scale geospatial AR). Every factual claim below carries a numbered source; full evidence tables with per-claim provenance live in the research working files (see provenance sidecar).

## 1. The question

The product requires: 4-player co-located matches now, scaling later; realtime accountable bullets (travel, dodge, bullet time); co-located play today with a path to remote/open-world play. What combination of backend and transport supports this without a future rewrite, and what does each option cost?

## 2. Non-negotiable architecture facts from the evidence

These findings constrain every option:

1. **Every serious shooter separates the simulation tick from durable state.** Source runs 15ms server ticks with ~20 snapshots/s and 100ms client interpolation [1]; Overwatch runs 16ms command frames [2]; Valorant runs a fixed 128Hz timestep on client and server [3]. Nobody runs combat through a database round-trip.
2. **Lag-compensated hitscan is a solved pattern with a known formula.** The server rewinds targets to `Current Server Time − Packet Latency − Client View Interpolation`, tests the shot, restores state [4][1]. Overwatch and Valorant both bound the rewind window so laggy shooters cannot kill players already in cover [2][3]. This matches the bounded-rewind design already in `docs/research/shared-ar-hit-registration.md`.
3. **Projectiles must be server-simulated, client-predicted.** Valve deliberately did not lag-compensate autonomous projectiles (temporal ambiguity) [4]; Overwatch isolates projectile simulation with instigator tagging and defers effects [2]. The established pattern: authority simulates the worldline; clients predict muzzle/tracer visuals and reconcile [2][4][5].
4. **Rollback (GGPO-style) is a poor default for the full AR simulation.** It requires bit-exact determinism [6]; ARKit tracking, device timing, and mobile floating point are not deterministic across heterogeneous phones (inference from [5][6]). It could still suit an isolated deterministic sub-system; server/host authority with client prediction is the correct family for the whole game.
5. **Multiplayer bullet time has an academic precedent: local perception filters (LPF).** Sharkey/Ryan/Roberts (1998) introduced LPFs [7]; Smed et al. explicitly realized *bullet time in multiplayer* with per-entity "temporal contours" — players render in real time, predictable passive entities (projectiles) may render in the past/future, distortion localized around the player [8]. This is the mechanism supporting the roadmap's "target-local dodge time" hypothesis. The shipped commercial precedent is Max Payne 3's online multiplayer "Burst": a *line-of-sight propagated time bubble* ("slows you down, slows down anyone you can see, anyone who can see you, and anyone who those affected people can see or be seen by") with an asymmetric advantage for the activator's side — closest to the "world-space time bubble" variant in this repo's prior research, and proof that bounded multiplayer slowdown ships and is fun [9]. SUPERHOT-style global slowdown remains single-player only [10].
6. **Convex must not be the frame loop — by its own design.** Convex is a reactive database with serializable transactions and WebSocket subscriptions [11]; it publishes no latency SLA [12], bills every subscription update as a function call [13], deploys to a single region (US East or EU West) [14], and its own guidance is to throttle/single-flight high-frequency mutations [15]. It is documented and exampled for multiplayer *state*, including published game walkthroughs [16].

## 3. Options evaluated

### Option A — Convex-only (status quo, harden it)

Convex mutations/subscriptions carry all gameplay, as today.

- **For:** zero new infrastructure; transactions, idempotency, reactivity already proven in this repo; cost at prototype scale is $0 (1M function calls/mo free; modeling a 4-player match at ~100 events ≈ 500 calls, 1,000 matches/day ≈ 15M calls/mo ≈ ~$30.80/mo in free-tier overage, or inside the 25M calls included with $25/dev Pro — a usage model, not a vendor quote) [13][17].
- **Against:** no latency SLA and single-region round trips for every verdict [12][14]; OCC contention when 4 players hammer one match document (mitigable with per-player docs, but the pattern fights the tool) [11][15]; default deployment class allows only 16 concurrent mutations [13]; no tick, no pose history, no rewind — all of §2's requirements would be built *inside* a database designed against that use.
- **Verdict:** rejected as the combat plane. Retained as durable authority (below). This confirms and evidences the prior internal research conclusion.

### Option B — Hybrid: local peer combat plane + Convex durable authority

A simulation core runs on a host phone; phones exchange 20–30Hz pose + fire events over local peer networking; Convex records spawns, terminal verdicts, health/score/lifecycle. (Apple documents no transport latency guarantee, so the 20–30Hz cadence is an implementation target that KIL-20/21 must validate on devices, not a platform property [18][19].)

- **Transport evidence:** Apple has deprecated MultipeerConnectivity and recommends Network.framework [18]. Network.framework provides opt-in peer-to-peer Wi-Fi (`includePeerToPeer`), Bonjour discovery, and QUIC with reliable streams *plus* a best-effort datagram channel — exactly the reliable-events + latest-state-pose split a shooter needs [19]. MultipeerConnectivity caps sessions at 8 peers including local [20]; ARKit collaborative sessions "work best with up to four participants" [21] — matching the 4-player Phase 1 target. AWDL (Apple's P2P Wi-Fi) has ~3ms link sync error and ≥8ms channel-switch cost [22]: the radio is not the bottleneck at 20–30Hz; serialization and policy are.
- **Precedent:** Apple's own SwiftShot (WWDC 2018) is this exact shape: host-authoritative physics, domain-compressed binary state (e.g. positions encoded in 48 bits), action queue over MultipeerConnectivity, world map shared once at join [23].
- **For:** lowest possible verdict latency (no internet hop) for the co-located product; offline-capable (park with no Wi-Fi — P2P Wi-Fi/Bluetooth need no infrastructure [19][20]); zero marginal infra cost; the host-authoritative model is a documented, legitimate authority model (listen server) [1].
- **Against:** host phone is a trust boundary and single point of failure (host migration needed) [1]; foreground-only — a locked phone drops out [18][20]; full mesh scales O(N²) so the host/relay topology is effectively mandatory beyond 4 [24]; peer transport does nothing for remote play.
- **Verdict:** correct *first implementation* of the combat plane for co-located 2–4 players — but only behind an authority/transport interface, because of the next option.

### Option C — Cloud realtime authority (the remote/scale implementation)

Same simulation core, hosted on a server. Evidence per candidate:

| Candidate | Authoritative logic | Native Swift | Cost @ prototype | Cost @ ~1,000 CCU | Ops |
|---|---|---|---|---|---|
| Cloudflare Durable Objects + WebSockets | Yes — write it yourself; per-match DO actor, hibernation API [25] | No SDK; plain `URLSessionWebSocketTask` | ~$5/mo [26] | est. $200–600/mo depending on tick/hibernation (model, not quote) [26] | Low infra, high authoring |
| Nakama (Heroic Labs) | Yes — purpose-built match handler with configurable tick rate (e.g. 10 ticks = 100ms) [27] | **Official Swift SDK**, active (v3, pushed 2026-08) [28] | self-host VPS ~$10–50/mo (inference) [29] | Heroic Cloud from $600/mo [30] | Managed = low; self-host = moderate/high (Postgres/CockroachDB) [29] |
| Colyseus | Yes — rooms, 60fps sim interval, 50ms patch rate [31] | No — native C SDK in beta, bridge required [32] | Cloud from $15/mo [33] | not public; likely $100+/mo (inference) | Low (managed) |
| Photon Realtime | **No custom server logic on public cloud** (Enterprise/self-host only) [34] | Obj-C/C++ SDK [35] | free ≤20 CCU; one-time $95 for 12 months @100 CCU [36] | $185/mo @1,000 CCU [36] | Very low, but relay-only |
| Ably / PubNub (relay baseline) | No — pub/sub only [37][38] | Yes (both) [37][38] | free tiers [37][38] | message costs explode at shooter tick rates (inference) [37] | Low |

- **Verdict:** if/when remote play or >4 players demands cloud authority, **Nakama** (only turnkey authoritative server with an official Swift SDK [27][28]) and **Durable Objects** (cheapest, edge-placed per-match actors [25][26], and Cloudflare skills already exist in this team's tooling) are the two finalists. Photon public cloud and pub/sub relays cannot run our verdict logic [34][37]. No commitment now — the simulation core makes this a deployment decision, not a rewrite.

### Option D — Dedicated game-server stacks / orchestration (GameFabric-Hathora)

Container orchestration for studio-scale dedicated servers; custom pricing, you author the whole server [39]. Overkill at this stage; becomes relevant only at event/city scale. Noted, not pursued.

## 4. Open-world reality check (constrains Phase 3, not Phase 1)

- **No turnkey street-scale shared AR space exists on iPhone.** Apple `ARGeoAnchor` needs A12+, works outdoors only in selected metro coverage, and offers no sharing or numeric accuracy guarantee [40]. ARCore Geospatial API works on iOS anywhere Street View coverage exists, free within quota (1,000 sessions/min per project) — sharing is app-level via your own backend [41][42]. Niantic's platform reorganized: consumer games went to Scopely; Niantic Spatial NSDK 4.x has a native Swift SDK and VPS2 with claimed centimeter-level precision at scanned Sites, credit-priced ($0–50+/mo tiers, 12 credits per localization query), and its built-in SharedAR was *removed* in 2026 [43][44][45].
- **Precedent for open world is server-side geo-indexed state, not shared AR frames.** Pokémon GO ran a "real-time shared world" on server-side location-indexed state (Google Cloud Datastore) [46]; room-scale shared AR (Buddy Adventure) was a separate, bounded feature [47].
- **Implication:** the open-world dream is served by the same layered architecture: cloud authority (Option C) + geo-indexed presence + a `SharedArenaFrame` provider that can be ARCore Geospatial / Niantic VPS / ARGeoAnchor per venue. Nothing in Phase 1 needs to change for this — but Phase 1 must not bake in "peer transport forever" or "one arena per match document" assumptions.

## 5. Recommendation (for ADR 0004 after KIL-21 measurements)

1. **Build the simulation core as a pure, deterministic, transport-agnostic module** (tick, pose ring buffers, bounded rewind — this repo's frozen internal baseline is a 250ms cap per [docs/features/shared-spatial-hit-registration/requirements.md](../features/shared-spatial-hit-registration/requirements.md), consistent with the bounded-rewind practice in [2][3] — and projectile worldlines). This is the Source/Overwatch/Valorant pattern [1][2][3] and the single highest-leverage artifact: it is the same code under host authority today and cloud authority later.
2. **Phase 1 (co-located 2–4):** host-phone authority over Network.framework P2P (QUIC streams + datagrams; Bonjour discovery) [19]; Convex remains durable authority for lifecycle/entitlements/terminal verdicts/spectator (Option B). Provisional local verdicts, durable confirmation — mirroring Overwatch's predicted-impacts-but-unconfirmed-health pattern [2].
3. **Scale trigger:** when remote play, >4 players, or host-trust becomes real, stand the same core up behind Nakama or a Durable Object per match (Option C finalists) — decide then with usage data; both are compatible with keeping Convex for durable state, and consolidation into the game server is also possible at that point without touching clients (the L1 interface is the contract).
4. **Bullet time:** implement per-entity time scaling inside the simulation core, never a global clock change. The LPF temporal-contour mechanism [7][8] supports the target-local dodge-time hypothesis; Max Payne 3's shipped line-of-sight bubble with asymmetric advantage [9] is the strongest commercial datapoint and maps to the world-bubble variant — ADR 0005 chooses between them (or prototypes both) after projectiles pass on devices.
5. **Measure before freezing (KIL-21):** fire→peer, fire→host verdict, fire→Convex confirmation, and subscription fan-out p50/p95/p99 on physical iPhones outdoors. As acceptance thresholds we *propose* (engineering targets set by this document, extending the ≤50ms host-verdict budget already in `docs/research/shared-ar-hit-registration.md` — not sourced from any vendor): hybrid stands if host-verdict p95 ≤ 50ms and Convex durable confirmation p95 ≤ 500ms. If peer transport underperforms, the same core moves to a cloud room (Option C) with co-located phones on LTE/5G — measure that too before deciding.

## 6. Cost picture (summary)

- **Phase 1 hybrid:** $0 infra beyond existing Convex free tier (prototype volumes fit free allowances comfortably) [13][17]; Apple Developer $99/yr already purchased.
- **Cloud authority later:** from ~$5/mo (DO, low volume) [26] or ~$15–50/mo (small VPS Nakama self-host, inference) [29] to $600/mo (managed Heroic Cloud) [30].
- **Open-world spatial (Phase 3 spike only):** ARCore Geospatial free-within-quota [42]; Niantic Spatial credit tiers $0–50+/mo [44].

## Sources

1. Valve Developer Community — Source Multiplayer Networking — https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking
2. Tim Ford (Blizzard), GDC 2017 — Overwatch Gameplay Architecture and Netcode — https://gdcvault.com/play/1024000/Overwatch-Gameplay-Architecture-and-Netcode (transcript via https://www.youtube.com/watch?v=8QHHVpBiG-I)
3. Riot Games — Peeking into VALORANT's Netcode — https://technology.riotgames.com/news/peeking-valorants-netcode
4. Yahn Bernier (Valve) — Latency Compensating Methods in Client/Server In-game Protocol Design and Optimization — https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization
5. Glenn Fiedler — State Synchronization — https://gafferongames.com/post/state_synchronization/ (with https://gafferongames.com/post/snapshot_interpolation/ and https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/)
6. GGPO Rollback Networking SDK — https://www.ggpo.net/
7. Sharkey, Ryan, Roberts — A local perception filter for distributed virtual environments (IEEE VRAIS 1998) — https://doi.org/10.1109/VRAIS.1998.658502 (not directly read; summarized via [8])
8. Smed, Niinisalo, Hakonen — Realizing Bullet Time in Multiplayer Games with Local Perception Filters — https://staff.cs.utu.fi/~jounsmed/papers/NG04_BulletTime-Slides.pdf (paper DOI https://doi.org/10.1145/1016540.1016551)
9. Stephen Totilo (Kotaku) — Max Payne 3 Multiplayer Is Good, Essential and Rockstar's Boldest Move In Years (full multiplayer bullet-time mechanic description) — https://kotaku.com/max-payne-3-multiplayer-is-good-essential-and-rockstar-5904303 (companion video piece: https://kotaku.com/how-multiplayer-bullet-time-works-in-max-payne-3-5907699; Steam categories: https://store.steampowered.com/app/204100/Max_Payne_3/)
10. Steam — SUPERHOT (Singleplayer + Bullet Time tags) — https://store.steampowered.com/app/322500/SUPERHOT/
11. Convex docs — Mutations and OCC — https://docs.convex.dev/functions/mutation-functions and https://docs.convex.dev/database/advanced/occ
12. Convex docs — Realtime — https://docs.convex.dev/realtime (no published latency SLA; execution metrics via https://docs.convex.dev/platform-apis/track-usage)
13. Convex docs — Limits and billing units — https://docs.convex.dev/production/state/limits
14. Convex docs — Regions — https://docs.convex.dev/production/regions
15. Convex Stack — Throttling by single-flighting — https://stack.convex.dev/throttling-requests-by-single-flighting (rate limiting: https://stack.convex.dev/rate-limiting)
16. Convex Stack — Building a Multiplayer Game — https://stack.convex.dev/building-a-multiplayer-game
17. Convex — Pricing — https://convex.dev/pricing
18. Apple — TN3151 Choosing the right networking API (MultipeerConnectivity deprecated; Network.framework recommended) — https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api (framework overview: https://developer.apple.com/documentation/multipeerconnectivity)
19. Apple — TN3213 Moving from Multipeer Connectivity to Network framework (QUIC streams + best-effort datagram channel, client-server vs mesh, P2P performance guidance) — https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework (P2P opt-in: https://developer.apple.com/documentation/network/nwparameters/includepeertopeer)
20. Apple — MCSession (8-peer limit incl. local; reliable/unreliable modes) — https://developer.apple.com/documentation/multipeerconnectivity/mcsession
21. Apple — isCollaborationEnabled ("works best with up to four participants") — https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/iscollaborationenabled
22. Stute, Kreitschmann, Hollick — One Billion Apples' Secret Sauce: Recipe for the Apple Wireless Direct Link Ad hoc Protocol (ACM MobiCom '18; 3ms sync error, ≥8ms channel switch, ~13% throughput penalty) — https://arxiv.org/abs/1808.03156
23. SwiftShot (Apple WWDC 2018 sample) — host-authoritative physics, compact binary state, world map shared at join — third-party mirror of the sample README, as the original Apple page is no longer online: https://github.com/GaoGuohao/SwiftShot/blob/master/README.md
24. Full-mesh directed streams N(N−1) — arithmetic inference from [20]; not an Apple claim
25. Cloudflare — Durable Objects WebSockets + hibernation — https://developers.cloudflare.com/durable-objects/api/websockets/ (concepts: https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/)
26. Cloudflare — Durable Objects pricing and limits — https://developers.cloudflare.com/durable-objects/platform/pricing/ and https://developers.cloudflare.com/durable-objects/platform/limits/
27. Heroic Labs — Nakama authoritative multiplayer (tick-rate match handlers) — https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/
28. Heroic Labs — nakama-swift (official Swift SDK; active 2026) — https://github.com/heroiclabs/nakama-swift
29. Heroic Labs — Nakama Docker self-hosting (Postgres/CockroachDB) — https://heroiclabs.com/docs/nakama/getting-started/install/docker/
30. Heroic Labs — Heroic Cloud pricing (from $600/mo) — https://heroiclabs.com/pricing/
31. Colyseus — Room, setSimulationInterval (16.6ms default), patchRate (50ms default) — https://docs.colyseus.io/colyseus/server/room/
32. Colyseus — Native SDK (C, beta) — https://docs.colyseus.io/getting-started/native-sdk
33. Colyseus Cloud — pricing (from $15/mo) — https://colyseus.io/pricing
34. Photon — Realtime (public cloud does not run custom server logic; Enterprise/self-host required) — https://www.photonengine.com/en-US/Realtime
35. Photon — SDKs (iOS C++/Obj-C) — https://www.photonengine.com/sdks
36. Photon — Realtime pricing (20 CCU free; $185/mo @1,000 CCU) — https://www.photonengine.com/en-US/Realtime/Pricing
37. Ably — homepage latency claim and pricing — https://ably.com/ and https://ably.com/pricing
38. PubNub — homepage latency claim and pricing — https://www.pubnub.com/ and https://www.pubnub.com/pricing
39. GameFabric (formerly Hathora) — https://gamefabric.com/ and https://docs.gamefabric.com/
40. Apple — ARGeoTrackingConfiguration / ARGeoAnchor (A12+, outdoors, selected coverage, runtime availability check) — https://developer.apple.com/documentation/arkit/argeotrackingconfiguration and https://developer.apple.com/documentation/arkit/argeoanchor
41. Google — ARCore Geospatial API (Street View coverage; WGS84/Terrain/Rooftop anchors; iOS quickstart) — https://developers.google.com/ar/develop/geospatial and https://developers.google.com/ar/develop/ios/geospatial/quickstart
42. Google — Geospatial API quota — https://developers.google.com/ar/develop/ios/geospatial/api-usage-quota (Cloud Anchors quotas/TTL: https://developers.google.com/ar/develop/ios/cloud-anchors/developer-guide)
43. Niantic Spatial — NSDK 4.x platforms (Unity, Swift, Kotlin) and migration (Lightship deprecated; SharedAR removed May 2026) — https://www.nianticspatial.com/docs/llms-nsdk/setup.txt and https://www.nianticspatial.com/docs/llms-nsdk/migration_guide.txt
44. Niantic Spatial — VPS and pricing (credit tiers; 12 credits/localization) — https://nianticspatial.com/vps and https://nianticspatial.com/pricing
45. Niantic Spatial — centimeter-level VPS claim — https://nianticspatial.com/blog/largegeospatialmodel (corporate status: https://nianticlabs.com, https://nianticspatial.com)
46. Niantic (archived) — Pokémon GO on Google Cloud ("real-time shared world", Datastore, >50× projections) — https://web.archive.org/web/2022/https://nianticlabs.com/blog/googlecloud
47. Niantic (archived) — Buddy Adventure shared AR — https://web.archive.org/web/2022/https://nianticlabs.com/blog/devinsights-buddyadventuresharedar
