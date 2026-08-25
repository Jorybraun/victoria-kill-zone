# Convex as a Durable Authority Backend for a Real-Time Multiplayer AR Mobile Game

## Research questions
1. How does Convex's realtime model (WebSocket subscriptions, reactive queries, mutations) fit a low-frequency, event-driven multiplayer game?
2. Is there published evidence of Convex used for games / real-time multiplayer, and what is Convex's own guidance on high-frequency updates?
3. What is the scheduler's minimum granularity and suitability for sub-second vs multi-second game logic?
4. What does Convex cost at prototype scale and at 1000s of matches/day?
5. What are the known limitations (OCC conflicts, single-region behavior, mutation ordering) for this use case?
6. What is the maturity of the `convex-swift` iOS client?

---

## Evidence Table

| # | Claim | Source | Read directly / Inferred |
|---|-------|--------|--------------------------|
| 1 | Convex is "automatically realtime": query dependencies are tracked and subscriptions are triggered when underlying data changes. | https://docs.convex.dev/realtime | read-directly |
| 2 | Queries are cached, reactive, and consistent; all reads in a single query run at the same logical timestamp. | https://docs.convex.dev/functions/query-functions | read-directly |
| 3 | Mutations run transactionally (atomic, all-or-nothing); all database reads in a mutation get a consistent view; the runtime retries deterministic mutations on optimistic-concurrency conflicts. | https://docs.convex.dev/functions/mutation-functions | read-directly |
| 4 | Convex provides true serializability, not merely snapshot isolation, and will retry conflicting transactions automatically. | https://docs.convex.dev/database/advanced/occ | read-directly |
| 5 | A mutation function queues all writes and commits them as a single database transaction; the whole mutation is one transaction. | https://docs.convex.dev/database/writing-data | read-directly |
| 6 | `ctx.scheduler.runAfter` / `runAt` take millisecond timestamps; scheduling from a mutation is atomic with the transaction. | https://docs.convex.dev/scheduling/scheduled-functions | read-directly |
| 7 | Cron `crons.interval()` supports `seconds`, `minutes`, or `hours` granularity; only one run of a given cron can execute at a time. | https://docs.convex.dev/scheduling/cron-jobs | read-directly |
| 8 | Function-call billing includes explicit client calls, scheduled executions, **subscription updates**, and file accesses. Free/Starter includes 1M calls/mo; Professional includes 25M calls/mo. | https://docs.convex.dev/production/state/limits | read-directly |
| 9 | Free/Starter and Professional pricing: per-million function calls, DB I/O, storage, data egress, etc. | https://convex.dev/pricing | read-directly |
| 10 | Convex deployments are single-region (US East or EU West); you cannot change a deployment's region after creation. | https://docs.convex.dev/production/regions | read-directly |
| 11 | Official iOS/macOS Swift client uses a persistent WebSocket, Combine `Publisher` for subscriptions, `async` mutations, and is built on the Rust client with a Tokio runtime. | https://docs.convex.dev/client/swift/overview | read-directly |
| 12 | Swift requires `@ConvexInt`/`@ConvexFloat` wrappers and field-name conversion for keywords; `BigInt`/number interop has gotchas. | https://docs.convex.dev/client/swift/data-types | read-directly |
| 13 | `convex-swift` repo: created Sep 2024, 49 stars, 24 forks, 14 open issues, latest release 0.8.1 (Feb 2026); open issues include FFI/safety, retain cycles, missing optimistic updates. | https://api.github.com/repos/get-convex/convex-swift, https://api.github.com/repos/get-convex/convex-swift/releases, https://api.github.com/repos/get-convex/convex-swift/issues | read-directly |
| 14 | Convex Stack publishes a "Building a Multiplayer Game" walkthrough using reactive queries, transactional mutations, and scheduled functions. | https://stack.convex.dev/building-a-multiplayer-game | read-directly |
| 15 | A real-time RPG community post uses Convex for live player coordinates and chat. | https://stack.convex.dev/matrix-building-a-real-time-rpg-game-with-convex | read-directly |
| 16 | Convex Stack "Throttling Requests by Single-Flighting" says the Convex client executes mutations serially and recommends single-flighting for inputs that can arrive faster than they can be processed. | https://stack.convex.dev/throttling-requests-by-single-flighting | read-directly |
| 17 | Convex Stack "Rate Limiting at the Application Layer" describes token-bucket and fixed-window rate limiting using Convex transactions and a rate-limiter component. | https://stack.convex.dev/rate-limiting | read-directly |
| 18 | Real-time database guide explicitly lists "Gaming and interactive media" as a use case and states that real-time architectures scale on actual data changes, not polling. | https://stack.convex.dev/real-time-database | read-directly |
| 19 | Convex log-stream `function_execution` events include `execution_time_ms` and `network_egress_bytes`; there is no published latency or round-trip SLA. | https://docs.convex.dev/platform-apis/track-usage | read-directly |

---

## Findings

### 1. Realtime model and suitability for discrete-event AR game

Convex's realtime model is a **reactive query + WebSocket push** model [1][2]. The Swift client keeps a persistent WebSocket connection and re-establishes it if dropped [11]. When a query is subscribed, Convex tracks the query's dependencies (e.g. the documents it reads); when those documents change, Convex re-runs the query and pushes the new result to the client [1][2]. This fits a game where the authoritative match state is in a document and each player subscribes to the match state.

**Mutation execution model**: mutations run as **ACID transactions** [3][4]. All reads in the transaction see a consistent snapshot, and all writes commit together or roll back together [3]. If an optimistic-concurrency conflict occurs, Convex automatically retries the deterministic mutation function [4].

**Mutation ordering**: when called from the React or Rust clients, mutations are executed **one at a time in a single ordered queue** [3]; the throttling post notes that the Convex client generally executes mutations serially, which is why single-flighting is recommended for high-frequency inputs [16]. The iOS Swift client is built on the same Rust client/protocol [11], but the docs do not explicitly promise the same ordered queue on Swift (so treat as likely but not guaranteed for ordering-sensitive events).

**Latency / round-trip guarantees**: Convex does **not publish a mutation round-trip or end-to-end latency SLA**. The docs describe real-time as using "persistent, low-latency connections" and "instant via WebSockets" [15], but no p50/p99 or typical ms numbers are given. The only concrete timing limits are:

- User code in a query/mutation is limited to **1 second** (database time is excluded) [8].
- Log streams expose `execution_time_ms` per function execution, so you can measure your own tail latency [19].

Therefore for a **discrete-event game** (shots, health, score) rather than a 60Hz physics loop, the model is a good conceptual fit, but tail latency under contention is a practical unknown that you would need to load-test.

### 2. Evidence of Convex for games and multiplayer

Convex has published and community evidence for multiplayer games:

- **"Building a Multiplayer Game"** (Stack) explicitly builds a complex game on "reactive-by-default queries, transactional mutations, backend storage, and scheduled functions" [14].
- **"Matrix: Building a real-time RPG game with Convex"** uses Convex for real-time player coordinates and chat [15].
- **"A Guide to Real-Time Databases"** lists gaming/interactive media as a key use case and notes that lag breaks the illusion for multiplayer games [18].

For **high-frequency updates**, Convex's own guidance is to throttle and not fire mutations blindly:

- The **single-flighting** post recommends throttling/debouncing/single-flighting for inputs that can be created faster than the server can process them, and notes that the Convex client already executes mutations serially [16].
- The **rate limiting** post shows how to implement token-bucket or fixed-window rate limiting inside Convex using a small amount of state and transactions, and points to an official rate-limiter component [17].

**For a non-60Hz game**, this guidance aligns well: you can treat each shot verdict, health change, or score change as a mutation rather than streaming 60 frames per second of world state.

### 3. Scheduler granularity for game logic

Convex has two scheduling mechanisms:

- **Scheduled functions** (`ctx.scheduler.runAfter` / `runAt`): measured in **milliseconds**; scheduled from a mutation are atomic with the transaction [6]. A single function can schedule up to 1000 functions with up to 8MB of total args, and outstanding scheduled functions are limited to 1,000,000 per deployment [8].
- **Cron jobs** (`crons.interval`): supports `seconds`, `minutes`, or `hours` [7]. Only one instance of a cron can run at a time; if it is slow, subsequent runs may be skipped [7].

**Suitability for sub-second game logic**: there is no documented support for sub-second tick rates as a recommended pattern. Millisecond scheduling exists for future/durable work, but a game tick loop would hammer the mutation path and hit client-side serial mutation ordering and OCC contention. **Multi-second timers** (match timers, round timers, cooldowns, scoring windows) are a natural fit [6][7].

### 4. Pricing and cost estimates

The relevant pricing axes from the published page [9] and limits page [8]:

| Resource | Free / Starter | Professional |
|----------|----------------|--------------|
| Function calls | 1M/mo included; $2.20 / add'l 1M | 25M/mo included; $2 / add'l 1M |
| DB I/O | 1 GB/mo included; $0.22 / add'l GB | 50 GB/mo included; $0.20 / add'l GB |
| DB storage | 0.5 GB included; $0.22 / GB | 50 GB included; $0.20 / GB |
| Data egress | 1 GB included; $0.132 / GB | 50 GB included; $0.12 / GB |
| Base price | $0/mo | $25 / developer / mo |

**What counts as a function call**: explicit client calls, scheduled executions, **subscription updates**, and file accesses [8]. Each reactive push to a subscriber is a billed function call.

**Cost model for a match** (inference, not a published benchmark):
- Assume a 4-player match with `E` discrete events.
- Each event: 1 client mutation call.
- Each event triggers a subscription update to the other 3 players (or all 4 if each player subscribes to the same match query). Using 4 fan-outs per event is conservative.
- Total function calls per match ≈ `E * 5` (1 mutation + 4 query updates).
- For `E = 100` events/match: ~500 function calls / match.

**Prototype: 10 matches / day**
- Calls: `10 * 500 = 5,000 / day` → ~150,000 / month.
- That is well under the **1M free** function-call allowance [9].
- DB I/O and storage are also tiny for small match documents.
- **Estimated cost: $0/month on Free/Starter**.

**Scale: 1,000 matches / day** (same 100 events/match, 4 players)
- Calls: `1,000 * 500 = 500,000 / day` → ~15M / month.
- **Free/Starter**: 1M included. 14M additional at $2.20/M = **~$30.80/mo** for function calls. DB I/O for 15M small reads/writes is likely a few to low tens of GB; after the 1GB included allowance, each extra GB is $0.22. Storage is negligible unless you keep full match history.
- **Professional**: 25M included, so 15M/mo is within the included allowance. You pay the **$25/developer/mo** base fee (e.g. $50/mo for 2 developers) and likely little/no overage.
- Note: data-egress pricing is documented for file downloads / outgoing fetches / backups [9][8], not for WebSocket fan-out of query results. Convex's real-time fan-out is not separately priced in the public table, so the dominant cost is function calls and DB I/O.

**Caveat**: these are back-of-the-envelope estimates. Actual cost depends on event frequency, payload size, number of subscribers, and whether you fan out through one shared match query or per-player queries.

### 5. Known limitations and risks

**OCC conflicts under contention**: Convex uses optimistic concurrency control with true serializability and automatic retry [4]. For a match document that is updated by many players in quick succession, conflicts and retries will happen and can create tail latency. The docs say the "obvious way" to write mutations will work [4], but the stack guidance to throttle and rate-limit shows that uncoordinated high-frequency writes need to be managed [16][17]. In practice, design your data model to avoid all players hammering the exact same document (e.g. per-player sub-documents or per-event append-only tables) to reduce contention.

**Single-region behavior**: a Convex deployment lives entirely in one selected region, currently only **US East (N. Virginia)** or **EU West (Ireland)** [10]. You cannot change a deployment's region after creation [10]. For an AR mobile game with global players, all players connect to the single region, so RTT varies by player location. Convex does not currently publish multi-region/replicated deployments.

**Mutation ordering**: React and Rust clients are explicitly ordered [3]; for the Swift client this is strongly implied by the shared Rust/protocol foundation [11] but not explicitly documented. If strict ordering is critical, use the server-side timestamps or sequence numbers inside your match document rather than relying on client ordering.

**Concurrency limits**: the default Free/Starter deployment class **S16** supports 1,000 concurrent sessions but only 16 concurrent queries and 16 concurrent mutations at a time [8]. For 2-4 players this is irrelevant; for thousands of concurrent matches you will need **S256** (Professional) or dedicated (Business/Enterprise) classes [8][9].

### 6. `convex-swift` iOS client maturity

The Swift client is **official and open-source** (`get-convex/convex-swift`) [11][13].

**Capabilities** [11][12]:
- Persistent WebSocket, Combine `Publisher` subscriptions, `async` mutations and actions.
- Auth0, Clerk, and custom OpenID Connect auth providers.
- Built on the official Rust client (`convex-mobile`) with a Tokio async runtime; safe to call from the main actor.
- Has debugging helpers (`initConvexLogging`, `watchWebSocketState`).
- Type conversion requires `@ConvexInt`, `@ConvexFloat`, and `CodingKeys` for keyword field names.

**Maturity signals** [13]:
- Created September 2024, 49 stars, 24 forks, 14 open issues.
- 5 releases, latest `0.8.1` (February 2026); the mobile Rust core `convex-mobile` is also actively maintained.
- Recent commits include bug fixes, version bumps, and Rust client integration.

**Documented and observed limitations**:
- Numeric and keyword interop gotchas are explicitly called out in the data-types docs [12].
- Open issues include an `AuthTokenProviderBridge use-after-free` crash, an FFI retain cycle, missing optimistic-update support, and a request for an offline/local-cache layer [13].
- No optimistic updates in the Swift client yet (open feature request); for low-latency UI feedback you may need to implement local optimistic state yourself.

For a small-team iOS AR game, the Swift client is usable but you should budget time to handle type wrappers, WebSocket reconnection, and the open FFI/safety issues if you use auth.

---

## Coverage Status

### Directly checked
- Convex docs: Realtime, Queries, Mutations, Writing Data, OCC/Atomicity, Scheduled Functions, Cron Jobs, State Limits, Pricing, Regions, Swift client overview and data types, Track Usage.
- Stack: building a multiplayer game, real-time RPG, throttling/single-flighting, rate limiting, real-time database guide.
- GitHub: `get-convex/convex-swift` repo metadata, releases, and issues; `get-convex/convex-mobile` repo metadata.

### Not checked / remaining uncertainty
- No published end-to-end mutation round-trip or subscription latency benchmarks for the iOS client; only execution-time limits and log-stream metrics exist.
- The exact billing treatment of WebSocket fan-out bandwidth is not spelled out as a per-GB egress line item for queries; published egress pricing is for files/fetches/backups.
- The Swift client's mutation ordering guarantee relative to React/Rust is not explicitly documented; inferred from the shared Rust implementation.
- Real-world OCC retry latency under 2-4 players firing events near-simultaneously at the same match document has not been load-tested; would need a prototype benchmark.

### Tasks I could not complete
- I did not locate any official Convex benchmark or whitepaper with p50/p99 round-trip times.
- I did not find a documented "sub-second tick rate" pattern; scheduler docs support seconds-level crons and millisecond `runAfter` but do not recommend them as game loops.
