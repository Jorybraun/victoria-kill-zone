# Cloud Realtime Backend Research for Mobile AR Shooter

Research question: credible cloud realtime backend options for a small team building a 2–8 player native Swift iOS AR shooter that requires authoritative server logic and sub-100ms event delivery, scaling from ~10 concurrent players to ~1,000 concurrent players.

## Evidence Table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Cloudflare Durable Objects overview | https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/ | Durable Objects are single-threaded actors with durable storage, automatically provisioned near the first request; optional location hints | primary | high |
| 2 | Cloudflare Durable Objects WebSocket API | https://developers.cloudflare.com/durable-objects/api/websockets/ | DOs can coordinate thousands of WebSocket clients per instance; Hibernation API keeps clients connected while DO sleeps, avoiding duration billing | primary | high |
| 3 | Cloudflare Durable Objects pricing | https://developers.cloudflare.com/durable-objects/platform/pricing/ | Workers Paid min $5/mo; 1M requests/mo incl. then $0.15/M; 400,000 GB-s/mo incl. then $12.50/M; WebSocket messages billed at 20:1; hibernation example 100 DOs×100 clients at 1 msg/min = ~$20.65/mo | primary | high |
| 4 | Cloudflare Durable Objects limits | https://developers.cloudflare.com/durable-objects/platform/limits/ | Per DO soft limit ~1,000 req/s; 32 MiB WS msg size; 30s CPU (up to 5 min); storage 10 GB/DO (SQLite) | primary | high |
| 5 | Cloudflare Workers pricing | https://developers.cloudflare.com/workers/platform/pricing/ | Workers Paid = $5/mo min; includes no egress/bandwidth charges | primary | high |
| 6 | Cloudflare Durable Objects data location | https://developers.cloudflare.com/durable-objects/reference/data-location/ | DOs can be restricted to jurisdictions; Workers access them globally | primary | high |
| 7 | PartyKit homepage | https://www.partykit.io/ | PartyKit is an open-source deployment platform for realtime apps; individual/commercial free tiers; deploy to own Cloudflare account | primary | high |
| 8 | PartyKit GitHub + PartyServer | https://github.com/partykit/partykit and https://github.com/cloudflare/partykit | PartyKit joined Cloudflare (Apr 2024); current development is in `cloudflare/partykit` as PartyServer, a library for DO-based realtime apps | primary | high |
| 9 | Nakama authoritative multiplayer docs | https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/ | Authoritative matches run a custom match handler with a configurable fixed tick rate; tick rate of 10 = 100ms between loops | primary | high |
| 10 | Nakama Swift client SDK | https://github.com/heroiclabs/nakama-swift | Official Swift client, Nakama v3, iOS/macOS/iPadOS/tvOS/visionOS, Swift 5.10+, async/await | primary | high |
| 11 | GitHub API nakama-swift | https://api.github.com/repos/heroiclabs/nakama-swift | Pushed 2026-08-06, not archived, 30 stars, 8 open issues | primary | high |
| 12 | Nakama Docker install | https://heroiclabs.com/docs/nakama/getting-started/install/docker/ | Self-host with PostgreSQL or CockroachDB via Docker Compose | primary | high |
| 13 | Heroic Cloud pricing | https://heroiclabs.com/pricing/ | Nakama on Heroic Cloud starts at $600/mo with no DAU/MAU/CCU limits; support packages $2,000–$6,000/mo | primary | high |
| 14 | Colyseus Room docs | https://docs.colyseus.io/colyseus/server/room/ | `setSimulationInterval` default 16.6ms (60fps); `patchRate` default 50ms; rooms isolate game sessions and can run authoritative logic | primary | high |
| 15 | Colyseus Native SDK docs | https://docs.colyseus.io/getting-started/native-sdk | Native C SDK in beta; supports iOS/Android/desktop/web; can be used for native iOS with C/Obj-C/Swift bridging | primary | high |
| 16 | Colyseus Cloud pricing page | https://colyseus.io/pricing | Colyseus Cloud starts at $15/mo, no CCU/DAU/MAU limits, managed SSL | primary | high |
| 17 | Colyseus Cloud pricing & billing docs | https://docs.colyseus.io/cloud/pricing-billing | Subscription based on compute plan; upfront monthly provisioning, prorated credits on deletion | primary | high |
| 18 | Colyseus Cloud compute plans | https://docs.colyseus.io/cloud/compute-plans | Low Performance, High Frequency, High Performance, Dedicated (Enterprise); no public unit prices | primary | high |
| 19 | Photon Realtime product | https://www.photonengine.com/en-US/Realtime | Photon Cloud in all major regions for low latency; room-based realtime; C# .NET/Unity SDK is primary | primary | high |
| 20 | Photon Realtime pricing | https://www.photonengine.com/en-US/Realtime/Pricing | Free 20 CCU; 100 CCU one-time $95/12mo; 500 CCU $95/mo; 1,000 CCU $185/mo; 2,000 CCU $370/mo; overage $0.05–$0.10/GB | primary | high |
| 21 | Photon SDK downloads | https://www.photonengine.com/sdks | Photon iOS SDK exists with C++ and Objective-C sources; all client SDKs can cross-play | primary | high |
| 22 | Photon Enterprise Cloud / authoritative logic | https://www.photonengine.com/en-US/Realtime (SDKs section) / https://www.photonengine.com/sdks | Standard Photon Cloud does not run custom server logic; Enterprise Cloud with dedicated servers & custom-code plugins can run authoritative logic | primary | high |
| 23 | GameFabric / Hathora home | https://hathora.dev/ / https://gamefabric.com/ | GameFabric (formerly Hathora) is a multiplayer server orchestration platform; you provide a containerized Linux game server image; bare metal + cloud | primary | high |
| 24 | GameFabric docs | https://docs.gamefabric.com/ | Multiplayer servers, Armadas, Vessels, Formations, SteelShield DDoS, API-first | primary | high |
| 25 | GameFabric Cloud docs | https://docs.gamefabric.com/multiplayer-servers/getting-started/gamefabric-cloud | Self-service cloud capacity per Location; machine type (vCPU/GB), node count, GCP only; custom pricing terms | primary | high |
| 26 | GameFabric pricing | https://gamefabric.com/pricing | No public per-unit rates; “cost-efficiency” claims, custom/quote-based | primary | high |
| 27 | Ably home | https://ably.com/ | 6.5ms message delivery latency claim; 11+ regions / 700+ PoPs; Swift + Objective-C SDKs | primary | high |
| 28 | Ably pricing | https://ably.com/pricing | Free: 200 conn, 500 msg/s, 6M msg/mo; Standard $29/mo + $2.50/M messages + $1/M conn-minutes; Pro $399/mo | primary | high |
| 29 | PubNub home | https://www.pubnub.com/ | <30ms latency claim; global edge messaging; Swift + Objective-C SDKs | primary | high |
| 30 | PubNub pricing | https://www.pubnub.com/pricing | Free: 200 MAU or 1M transactions/mo; Starter $98/mo for 1,000 MAU; Pro formula starts $130 + $0.04/MAU (capped $550) | primary | high |
| 31 | PubNub messaging latency | https://www.pubnub.com/pricing | “deliver … in less than 100ms” | primary | high |

## Findings

### 1. Cloudflare Durable Objects + WebSockets

**Authoritative logic support:** A single Durable Object (DO) is a stateful, single-threaded actor that can keep in-memory state, accept WebSocket connections from multiple clients, and run custom JavaScript logic before broadcasting state [1][2]. It is a natural per-match “room” container: the DO id can encode the match id and each match gets its own DO [1]. The code can validate inputs and authoritatively update state in `webSocketMessage` handlers or with alarms for tick loops [2].

**Native Swift SDK:** None. You use the standard iOS `URLSessionWebSocketTask` or a WebSocket library, plus your own protocol. WebSockets are standard, but there is no Cloudflare-issued Swift client.

**Latency:** Cloudflare says DOs are “automatically provisioned geographically close to where they are first requested,” with optional jurisdiction/location hints [1][6]. There is no published average end-to-end latency number for WebSocket messages, but the placement model should keep the server close to the first connecting player. Sub-100ms is plausible for same-region clients, but DO placement is decided by the first request and cannot be moved per player after creation (inference).

**Tick / event cadence:** DOs do not have a built-in game loop, but you can use `state.storage` and `setAlarm` / `setWebSocketAutoResponse` to drive tick-like behaviour [2][3]. Because each DO is single-threaded and has a ~1,000 req/s soft limit, a 2–8 player shooter at 30–60 events/second is well within that [4].

**Cost (inferences, using pricing numbers from [3][5]):**

- *Prototype (~10 concurrent players):* On Workers Paid the minimum is $5/mo. If one DO hosts each match and hibernation is used, a low-traffic prototype usually stays within the 1M included requests and 400,000 GB-s included duration, so **~$5–$15/mo**.
- *1,000 concurrent players (≈125 matches of 8 players):* With active 60-tick traffic and 10 msg/s per player, usage scales into billable requests and duration. A rough model: ~500 billed requests/sec, ~30M–60M request units/month, and many GB-seconds for 125 always-active DOs. This can easily reach **a few hundred dollars per month** (e.g., $200–$600 depending on tick rate and hibernation efficiency). Cloudflare’s own hibernation example (100 DOs × 100 clients, 1 msg/min, 10ms processing) is ~$20.65/mo [3], but a fast-tick shooter will not hibernate between messages, so actual cost is higher.

**Ops burden:** Low for managed (Cloudflare handles scaling, no servers). Moderate for architecture (you must implement match state, message protocol, tick/alarms, and snapshots; Durable Object storage model only, no existing game framework).

**PartyKit/PartyServer status:** PartyKit is an open-source layer on top of Durable Objects. The original `partykit/partykit` repo now notes that “Current development of this project is in cloudflare/partykit” [8]. That repo is branded as PartyServer and is explicitly a Work in Progress library that makes DOs easier to use for realtime apps [8]. It is not yet a GA game backend, but it is the evolution path.

---

### 2. Nakama (Heroic Labs)

**Authoritative logic support:** Strong. Nakama’s “Authoritative Multiplayer” runs custom match handlers in TypeScript, Go, or Lua. A `MatchLoop` is called at a fixed configurable tick rate (e.g., tickRate = 10 means one loop every 100ms) [9]. Input is batched, validated, state broadcast via the dispatcher. This is a purpose-built game-server model.

**Native Swift SDK:** Official and maintained. `heroiclabs/nakama-swift` supports Nakama v3, iOS, macOS, iPadOS, tvOS and visionOS, uses Swift concurrency, and the repo was pushed in August 2026 [10][11].

**Latency:** Heroic Labs does not publish a single global latency SLA. Latency is a function of the chosen region(s) for the server/cluster, client proximity, and tick rate (inference). Self-hosting or Heroic Cloud in a region close to players can hit sub-100ms with a tick rate of 10–20, but no hard claim is made.

**Tick / event cadence:** Configurable per match. Docs say tick rates range from 1/s for turn-based to dozens/s for fast-paced games; the server tries to keep loop spacing even (e.g., 10 ticks/s = 100ms between starts) [9].

**Cost:**

- *Self-host:* Open-source; you pay for the VM + database (PostgreSQL/CockroachDB) and ops time. A small prototype can run on a $10–$50/mo VPS or small cloud instance (inference).
- *Heroic Cloud:* Managed Nakama starts at **$600/mo** with no DAU/MAU/CCU limits, dedicated hardware and managed DB [13]. Support add-ons are $2,000–$6,000/mo [13].
- *1,000 concurrent:* Self-host: likely one or a few $50–$500/mo nodes plus DB, depending on tick rate. Heroic Cloud: the $600/mo entry plan is the public starting point; larger workloads require a custom quote (inference).

**Ops burden:** Managed Heroic Cloud = low. Self-host = moderate/high (you run Nakama, Postgres/CockroachDB, backups, scaling, monitoring) [12].

---

### 3. Colyseus

**Authoritative logic support:** Yes. The `Room` class is an isolated session with its own state, lifecycle events, and a game loop driven by `setSimulationInterval` (default 16.6ms) [14]. You can implement authoritative rules in the TypeScript server and use `patchRate` (default 50ms, 20fps) to broadcast state diffs [14].

**Native Swift SDK:** No official Swift client. The supported clients are TypeScript, Unity/C#, Defold (Lua), Haxe and the Native C SDK. The Native C SDK is in beta and supports iOS (via static/shared C libraries), so a native Swift app can bridge to it using C/Objective-C bindings [15]. This is extra integration work.

**Latency:** Colyseus docs do not cite a numeric latency. Latency is determined by the region of the Colyseus Cloud instance or self-hosted server, the WebSocket transport, and the patch rate (inference). With a 50ms default patch interval, server-to-client state delivery is at most 50ms behind the server tick, plus network RTT.

**Tick / event cadence:** `setSimulationInterval` defaults to 60fps (16.6ms) and is the server-side physics/game loop; `patchRate` is the state-sync broadcast interval (default 50ms) [14]. `maxMessagesPerSecond` can be capped per client.

**Cost:**

- *Self-host:* Open-source; pay for the Node.js host + DB. A small prototype can run on a $10–$30/mo VPS.
- *Colyseus Cloud:* Starts at **$15/mo** and claims no CCU/DAU/MAU limits [16]. Billing is subscription-based on the chosen compute plan (Low, High Frequency, High Performance, Dedicated) [17][18].
- *1,000 concurrent:* Requires a larger compute plan; no public price list is published, only the simulator on the pricing page [16][17]. Likely **$100+/mo** and possibly much more for High Frequency/Dedicated (inference).

**Ops burden:** Managed Colyseus Cloud = low (deploy from CLI, managed SSL, zero-downtime deployments) [16]. Self-host = moderate (Node.js, Redis/Mongo optional, scaling config).

---

### 4. Photon Realtime / Fusion

**Authoritative logic support:** Photon Realtime public cloud is a client-server relay and room-matching service; it does **not** run custom game rules [19][22]. Authoritative server logic requires either (a) self-hosted Photon Server, or (b) Photon Enterprise Cloud with dedicated servers and custom-code plugins [22]. Fusion is a state-sync netcode SDK for Unity/Unreal/Godot, not a native Swift target [19].

**Native iOS (non-Unity) SDK:** Photon offers a native iOS SDK with C++ and Objective-C sources (`LoadBalancing-objc`, `Photon-objc`, etc.) [21]. It is not a pure Swift package, but it can be used in a Swift app via Objective-C bridging (inference).

**Latency:** Photon states that “Photon Cloud is hosted in all major world regions to provide your players with a minimum latency” [19]. No exact ms SLA is published for Realtime.

**Tick / event cadence:** Realtime is message/event driven, not a fixed tick engine. The server forwards `RaiseEvent` calls to room peers. You can build a tick loop on the client or via Enterprise plugins/Photon Server.

**Cost:**

- *Prototype (~10 concurrent):* Free plan is capped at **20 CCU** [20]. The 100-CCU plan is a one-time **$95** for 12 months. So a 10-player prototype can be free or $95 for 12 months.
- *1,000 concurrent:* **$185/mo** for 1,000 CCU; $370/mo for 2,000 CCU [20]. Includes 3 TB traffic for the 1,000-CCU plan; overage is $0.05–$0.10/GB depending on region [20].

**Ops burden:** Managed Photon Cloud = very low. But to get authoritative logic you must operate Photon Server yourself or buy Enterprise Cloud (high cost/contract).

---

### 5. Hathora / GameFabric

**What it provides:** GameFabric (the current brand; `hathora.dev` now redirects to it) is a game-server orchestration platform. You provide a containerized Linux game-server image; GameFabric deploys “Vessels” (game server instances) across bare metal and/or GCP, handles allocation, DDoS (SteelShield), monitoring, and global locations [23][24]. It is **not** a turnkey game backend with built-in match logic — you write the authoritative server in the container.

**Native Swift SDK:** None; you implement the client in Swift and talk to your own containerized server protocol (UDP/TCP/WebSocket) over GameFabric’s allocator.

**Latency:** Depends on where you provision Locations and the server container performance. GameFabric offers global datacenters and the option to place capacity near players [23][25]. No public latency SLA.

**Cost:** No public per-CCU or per-hour price list. GameFabric Cloud uses custom pricing terms accepted per cloud Location; the platform is aimed at studios with launch-scale titles and is generally contract/quote-based [25][26]. It is likely **not the cheapest prototype option** and may require a minimum monthly commitment (inference).

**Ops burden:** Low for infrastructure (managed orchestration, DDoS, scaling), but high for game server authoring and container management. A small 10-player prototype is overkill unless you already have a dedicated server binary.

---

### 6. Managed Realtime Messaging Baseline — Ably and PubNub

Both are pub/sub message buses, **not** game backends. They relay messages; they do not run match state, validate game rules, or provide a tick loop. They can be a baseline for low-latency messaging only.

#### Ably

- **Authoritative logic:** No. You can attach serverless functions (AWS Lambda, Cloudflare Workers, etc.) to process messages, but there is no built-in per-match authoritative state/loop.
- **Swift SDK:** Yes, listed as a crafted SDK [27].
- **Latency:** Claims **6.5 ms message delivery latency** and a global edge network [27][28].
- **Cost:** Free plan = 200 concurrent connections, 500 msg/s, 6M messages/mo. Standard = **$29/mo** + $2.50/M messages + $1/M connection-minutes + $0.25/GB. Pro = **$399/mo** [28].
- *Prototype:* Free tier can cover 10 connections if message volume is <6M/mo.
- *1,000 concurrent:* Standard or Pro depending on message rate. At high event rates (e.g., 1,000 players × 20–60 msg/s) message costs dominate; a fixed-tick shooter can generate billions of messages/month, making this **prohibitively expensive** compared with a dedicated game server (inference).

#### PubNub

- **Authoritative logic:** No. Pub/Sub messaging with presence, persistence, and serverless integrations.
- **Swift / Objective-C SDK:** Yes [29][30].
- **Latency:** Claims **<30 ms** on its home page and “less than 100ms” for global publish/subscribe [29][31].
- **Cost:** Free = 200 MAU or 1M transactions/mo. Starter = **$98/mo** for 1,000 MAU. Pro = formula: $130 base + $0.04/MAU, capped at $550 for up to 10k MAU; above that, $500 base + $0.035/additional MAU (× 1.1 multiplier) [30].
- *Prototype:* 10 concurrent players could fit the Free plan if total MAU is ≤200.
- *1,000 concurrent:* If those 1,000 CCU map to ~10k–20k MAU, Pro runs ~$550–$1,130/mo [30]. Transaction volume is bundled under MAU; high-frequency per-player events do not add per-message charges, but PubNub is still a relay, not an authoritative game loop.

---

## Summary / Recommendation for a Native Swift AR Shooter

| Criterion | Best fits | Notes |
|-----------|-----------|-------|
| Authoritative + Swift SDK out of the box | Nakama | Official Swift SDK, purpose-built match loop, managed Heroic Cloud from $600/mo |
| Edge scale + lowest ops, can write own DO logic | Cloudflare Durable Objects + WebSockets | Per-match DO pattern, no Swift SDK, very cheap prototype, cost scales with tick rate |
| Open-source + fully managed cheap path | Colyseus Cloud ($15/mo) | No Swift SDK; use Native C SDK bridge or switch to supported engine |
| Managed, room-based, but no server rules | Photon Realtime | Native iOS SDK exists, cheap at low CCU; authoritative only with Enterprise/self-host |
| Bare-metal game-server orchestration | GameFabric/Hathora | You build the server; pricing is custom/enterprise |
| Pure message relay baseline | Ably / PubNub | Good for chat/lobby, not game rules; message costs explode for high tick rates |

For a small team targeting a native Swift iOS AR shooter, **Nakama** is the most credible turnkey authoritative backend because it has an official Swift SDK and a match loop. **Cloudflare Durable Objects** is the most serverless/edge-native option and cheapest at small scale, but requires building the entire authoritative loop and has no Swift SDK. **Colyseus** and **Photon** trade off language/tooling constraints. **GameFabric/Hathora** is viable only if the team already plans to containerise a dedicated server. **Ably/PubNub** should be treated as a messaging/lobby layer, not the authoritative game backend.

## Coverage Status

- Checked directly: Cloudflare Durable Objects docs, pricing, and limits; PartyKit/PartyServer status; Nakama authoritative docs, Swift SDK, Docker install, and Heroic Cloud pricing; Colyseus room/tick/patch docs, Native SDK, and Cloud pricing; Photon Realtime pricing, iOS SDK availability, and authoritative logic limits; GameFabric/Hathora product scope and pricing model; Ably and PubNub latency claims, pricing, and SDK availability.
- Remaining uncertainty: exact Cloudflare DO cost for a 60-tick active shooter (depends on hibernation efficiency); exact Colyseus Cloud plan prices above the $15/mo entry; exact GameFabric/Hathora unit prices (not public); no vendor publishes a hard end-to-end latency SLA for a native Swift AR use-case.
- All cost numbers at 1,000 concurrent players are inferences/models, not vendor quotes.

## Sources

1. Cloudflare Durable Objects overview — https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/
2. Cloudflare Durable Objects WebSocket API — https://developers.cloudflare.com/durable-objects/api/websockets/
3. Cloudflare Durable Objects pricing — https://developers.cloudflare.com/durable-objects/platform/pricing/
4. Cloudflare Durable Objects limits — https://developers.cloudflare.com/durable-objects/platform/limits/
5. Cloudflare Workers pricing — https://developers.cloudflare.com/workers/platform/pricing/
6. Cloudflare Durable Objects data location — https://developers.cloudflare.com/durable-objects/reference/data-location/
7. PartyKit — https://www.partykit.io/
8. PartyKit GitHub / PartyServer — https://github.com/partykit/partykit and https://github.com/cloudflare/partykit
9. Nakama Authoritative Multiplayer — https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/
10. Nakama Swift SDK — https://github.com/heroiclabs/nakama-swift
11. GitHub API nakama-swift — https://api.github.com/repos/heroiclabs/nakama-swift
12. Nakama Docker install — https://heroiclabs.com/docs/nakama/getting-started/install/docker/
13. Heroic Cloud pricing — https://heroiclabs.com/pricing/
14. Colyseus Rooms — https://docs.colyseus.io/colyseus/server/room/
15. Colyseus Native SDK — https://docs.colyseus.io/getting-started/native-sdk
16. Colyseus Cloud pricing — https://colyseus.io/pricing
17. Colyseus Cloud pricing & billing — https://docs.colyseus.io/cloud/pricing-billing
18. Colyseus compute plans — https://docs.colyseus.io/cloud/compute-plans
19. Photon Realtime — https://www.photonengine.com/en-US/Realtime
20. Photon Realtime pricing — https://www.photonengine.com/en-US/Realtime/Pricing
21. Photon SDK downloads — https://www.photonengine.com/sdks
22. Photon Enterprise Cloud / authoritative logic — https://www.photonengine.com/en-US/Realtime and https://www.photonengine.com/sdks
23. GameFabric home — https://gamefabric.com/ (also https://hathora.dev/)
24. GameFabric docs — https://docs.gamefabric.com/
25. GameFabric Cloud — https://docs.gamefabric.com/multiplayer-servers/getting-started/gamefabric-cloud
26. GameFabric pricing — https://gamefabric.com/pricing
27. Ably home — https://ably.com/
28. Ably pricing — https://ably.com/pricing
29. PubNub home — https://www.pubnub.com/
30. PubNub pricing — https://www.pubnub.com/pricing
