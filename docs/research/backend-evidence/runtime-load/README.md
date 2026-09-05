# Four-player Durable Object runtime load

These measurements exercise the actual local workerd WebSocket, SQLite, simulation and durable bullet ledger. They do not select the production authority or establish edge, network or physical-device performance.

## Workload and results

Each scenario runs four synthetic clients at a requested 20 Hz pose rate. Every pose supplies observations of the other three players, with 32 capsules per observation. Clients fire, reload and activate slow fields. The opposing-combat scenario also exercises front-facing shields, body impacts, deaths and respawns. Miss lanes keep more projectiles alive but allow the collision broad phase to reject distant bodies; this is a maximum input-payload fixture, not worst-case collision coverage.

Both 30-second runs use a 500 ms warmup and a 4.5-second terminal drain with fresh poses. Setup and drain are excluded from measured traffic and offered-command counts. A command remains pending until both its durable acknowledgment and gameplay result arrive. The end barrier compares every client's exact ordered spawn/segment/terminal JSON with the persisted ledger; snapshot gap healing cannot make that check pass.

| Local 30-second measurement | Baseline miss lanes | Optimized miss lanes | Baseline opposing combat | Optimized opposing combat |
|---|---:|---:|---:|---:|
| Test outcome | **Failed** | Passed | Passed | Passed |
| Database allocation, bytes | 23,416,832 | 2,076,672 | 21,790,720 | 1,757,184 |
| Durable bullets | 352 | 352 | 136 | 136 |
| Cancelled bullets | 88 | 0 | 0 | 0 |
| Body hits / shield blocks | 0 / 0 | 0 / 0 | 50 / 14 | 50 / 14 |
| Accepted poses per player | 599 / 599 / 597 / 596 | 600 / 600 / 600 / 600 | 600 each | 600 each |
| Acknowledgment p95 range across players, ms | 80–86 | 59 | 42–44 | 41–42 |
| Exact client/ledger agreement | 4 / 4 | 4 / 4 | 4 / 4 | 4 / 4 |

Raw evidence is retained in [baseline-30s.json](baseline-30s.json) and [optimized-30s.json](optimized-30s.json), including refusals, traffic, latency distributions, event gaps, authority epoch, unresolved bullets and projection progress. The failed baseline is intentional evidence: brief tracking pauses cancelled 88 validly recorded in-flight bullets. Both 30-second drivers awaited clock replies inside their pose loop, which can contribute to freshness gaps; cancellation cannot be attributed exclusively to worker execution. The optimized run retained about 91% less allocated database space in the miss-lane scenario. This is one before/after local observation, not a statistical latency guarantee. Protected/dead-player refusals in opposing combat are reported and do not count as accepted fire.

## Changes under test

### Sustained run: acceptance failed

[optimized-180s.json](optimized-180s.json) records both complete three-minute scenarios with the final independent clock pump and per-shot identity assertions. Both failed the smooth-play acceptance gate. Preserve this failure when assessing readiness:

| Three-minute observation | Miss lanes | Opposing combat |
|---|---:|---:|
| Accepted shots / durable bullets | 2,048 / 2,048 | 652 / 652 |
| Matching spawn and terminal identities | All accepted shots | All accepted shots |
| Exact client/ledger agreement | 4 / 4 | 4 / 4 |
| Unresolved bullets / missing events | 0 / 0 | 0 / 0 |
| Cancelled bullets | **724** | **20** |
| Paused time observed by first client, ms | 2,475 | 52 |
| First-client pose send interval p99 / max, ms | 82 / 241 | 52 / 99 |
| Acknowledgment p95 across players, ms | 81–85 | 40 |
| Database allocation, bytes | 4,759,552 | 2,813,952 |
| Retained commands / queued projection rows | 2,048 / 32 | 2,048 / 11 |

The storage and convergence improvements do not establish sustained playable performance. The next profiling pass must separate driver scheduling/clock error, parsing/canonicalization, simulation/fork cost, SQL work and durable sync latency. The local fixture shares a machine with its authority and supplies synthetic clock uncertainty, so its pauses alone do not identify a production bottleneck. Freshness gates and cancellation assertions remain unchanged; no failed run is retried until a pass or relabeled as successful.

### Implemented optimizations

- Two unique-key command probes replace an OR query that scanned a player's retained history. Actual workerd cursor tests with 512 retained commands per player measure 513 rows read for the old missing-command query, zero for the new one, and two for an oldest-command replay. Conflicting ID/sequence keys preserve the previous highest-sequence selection.
- A partial index locates the unsent projection without scanning sealed retries. With 2,048 sealed rows, the negative control reads 2,048 rows and the indexed lookup reads one. The test verifies the query plan and unsent coalescing.
- Command fingerprints retain a 71-byte prefixed SHA-256 digest of the canonical envelope instead of the full pose payload. Exact retries of preexisting canonical-JSON rows remain supported. This is identity comparison, not ticket authentication.
- A broadcast is serialized and UTF-8 measured once for all four recipients. Each connection still owns its receipt watermark and byte budget. A multibyte regression proves one recipient's acknowledgment cannot release another's budget.

SQL transaction → durable storage sync → cache update → broadcast/acknowledgment ordering is unchanged. Pose freshness, authority validation and socket backpressure limits are unchanged.

## Reproduction and provenance

```sh
pnpm install --frozen-lockfile
pnpm verify
pnpm --dir services/combat-worker test:load
VKZ_LOAD_MS=180000 pnpm --dir services/combat-worker test:load
```

The last command runs two three-minute active windows. The runner accepts only 30,000 or 180,000 ms, runs the scenarios serially, and excludes ordinary tests from its workload. Avoid other builds or tests during timing. The Node reporter writes `services/combat-worker/reports/last-load.json` even when a post-measurement assertion fails; ordinary workerd console forwarding is not used to retain results. Reports are ignored until integration deliberately copies reviewed evidence here.

Baseline runtime was the unchanged PR #56 head `2c10a9ae33979246019543533d89504a30dc9845`; runtime owners waited for baseline completion before editing. The benchmark harness was uncommitted. The later reporter includes SHA-256 content hashes for the exact runtime, shared simulation/protocol, benchmark and configuration files in addition to the Git HEAD. The final harness additionally includes its imported test helper, which the 30-second manifest omitted. These hashes identify the modified working tree; the HEAD alone does not identify optimized source. No environment or credential files are collected.

The original baseline's `activeSimulatedMs` field was an estimate extrapolated from the driver's clock, not independent simulation progress. The final harness explicitly labels that diagnostic `estimatedClockElapsedMs` and separately checks elapsed delivered authority ticks within three 50 ms ticks of the wall-time window. Delivery intervals remain client-observed scheduling/network intervals, not server CPU execution. The gameplay workload and cancellation/ledger assertions were not relaxed between runs.

Before the three-minute runs, independent review strengthened the driver: clock refresh runs independently of pose scheduling, and each accepted `(playerId, shotId)` must have exactly one durable spawn and one terminal. Equal client/server ledgers alone could conceal a shot omitted from both; the final harness rejects that case and separately reconciles durable bullet count to accepted fire count. The 30-second reports happen to reconcile those counts (352 and 136), but were captured before the explicit identity assertion. Do not treat the different-duration/driver runs as a controlled latency comparison.

### Diagnosing tracking pauses

`VKZ_PROFILE=1 pnpm --dir services/combat-worker test:load` additionally observes the actual room, storage and simulation methods through the local test harness. Installation runs a bounded clock-resolution probe before warmup. Fixed histograms retain every method duration without an unbounded sample buffer; up to 64 coverage-pause records retain tick/cadence, pending pose ages, and the latest admitted/accepted pose timestamps. No body geometry, ticket or credential payload is retained. Wrappers preserve original return values and promises, and are removed before terminal drain. Nested method durations overlap; they cannot be summed as independent CPU stages. The probe identifies whether this local runtime's clock advances during synchronous work. These elapsed timings are not deployed CPU billing or network measurements; Cloudflare documents the [local/deployed timer distinction](https://developers.cloudflare.com/workers/runtime-apis/performance/).

The driver also records bounded clock RTT/adjustment and phase histories, capture intervals, and authority-side pose age/refusal diagnostics. This first profiling pass deliberately preserves its existing receive-side clock anchor. That anchor differs from the native four-timestamp, uncertainty-gated estimator: a delayed pong can move the synthetic estimate backward. Pose rejection or loss of coverage can therefore reflect driver error as well as worker delay. A later driver correction must be identified separately from a runtime optimization, with the failed original evidence retained.

### Collision profiling and bounded geometry reuse

The next paired 30-second run reproduced cancellation with profiling enabled. Both clock probes advanced during synchronous work, at a measured 1 ms resolution. Driver clock adjustments stayed within ±1 ms in these runs; large clock resets were not the observed cause. The miss-lane pauses occurred after empty ticks with the latest accepted poses aged 114/119 ms. Simulation advance dominated measured tick work; synchronous command lookup, checkpoint and SQL commit times were materially smaller.

The collision resolver now reuses a target's interpolated body geometry for the exact same interval while collecting one batch of collision candidates. It retains at most 128 target/interval entries and computes excess intervals without retaining them. Shield poses remain lazy. Selection, freshness, sweep tolerances and global impact ordering are unchanged, and the cache is discarded before the next resolution. Independent regressions compare 128 simultaneous misses with separate resolutions, distinguish historical/current target geometry, reject reuse across later observations, and prove that an overflowing repeated interval is recomputed while preserving its hits.

| Profiled 30-second observation | Before, miss lanes | Cached, miss lanes | Before, opposing | Cached, opposing |
|---|---:|---:|---:|---:|
| Test outcome | **Failed** | Passed | **Failed** | Passed |
| Simulation advance mean / max, ms | 22.94 / 89 | 6.54 / 35 | 7.24 / 64 | 3.77 / 35 |
| Whole tick mean, ms | 24.71 | 8.96 | 9.30 | 5.75 |
| Cancelled bullets | 75 | 0 | 22 | 0 |
| Coverage pauses | 2 | 0 | 3 | 0 |
| Accepted shots / durable bullets | 352 / 352 | 352 / 352 | 140 / 140 | 137 / 137 |
| Acknowledgment p95 across players, ms | 64–74 | 50 | 37–39 | 23 |
| Exact client/ledger agreement | 4 / 4 | 4 / 4 | 4 / 4 | 4 / 4 |

Raw reports: [profile-before-30s.json](profile-before-30s.json) and [profile-cached-30s.json](profile-cached-30s.json). Their allowlisted source manifests differ only in `packages/combat-simulation/src/flight.ts`; driver, instrumentation and workload are identical. Mean advance time fell about 71% in the busiest fixture. This is one controlled local observation with inclusive, coarse wall timings, not a statistical or cloud performance guarantee. `commitCandidate` includes snapshot/checkpoint/event work and awaited synchronization; it is not a direct measurement of storage sync. If a future clock probe does not advance during synchronous work, synchronous stage attribution is unavailable rather than zero-cost.

### Sustained run after geometry reuse: one acceptance failure remains

[cached-180s.json](cached-180s.json) records a subsequent three-minute run with runtime profiling disabled and the same gameplay/freshness assertions. Opposing combat passes; miss lanes still fail the zero-cancellation gate. The original failed reports remain above.

| Three-minute observation after geometry reuse | Miss lanes | Opposing combat |
|---|---:|---:|
| Test outcome | **Failed** | Passed |
| Accepted shots / durable bullets | 2,096 / 2,096 | 584 / 584 |
| Cancelled bullets | **120** | 0 |
| First-client paused time, ms | 242 | 0 |
| Accepted poses per player | 3,600 / 3,600 / 3,598 / 3,597 | 3,600 each |
| Pose send interval p99, ms | 52 each | 52 each |
| Acknowledgment p95 across players, ms | 29–30 | 31 |
| Exact client/ledger agreement | 4 / 4 | 4 / 4 |
| Database allocation, bytes | 4,861,952 | 2,691,072 |

Every accepted shot still matches exactly one spawn and terminal; unresolved bullets, missing/duplicate/healed events and authority recoveries remain zero. The first two miss-lane clients had no pose refusals; the others had two/three stale-pose refusals. All miss-lane pose send intervals stayed below 85 ms, and that driver had no missed pump slots; opposing combat's maximum interval was 90 ms. Thus improving normal simulation time and input cadence has not eliminated occasional admission/coverage failures. The next measurement should use an independent client process and the native clock estimator, while measuring command arrival/queue residence and authority catch-up around each pause. Clock-quality loss must remain a failure, and no freshness or cancellation gate should be relaxed to hide it. This local result does not establish full-round production readiness.

## Rollout and remaining evidence

This candidate has not been deployed. New code reads both legacy and compact fingerprints; an older revision only reads legacy fingerprints. After compact rows are written, rollback must use a revision with digest-read compatibility or allow the affected match to finish. Do not silently roll an active room back to a legacy-only reader or rewrite its command history.

The projection endpoint is disabled in these fixtures, so queued outbox persistence is measured and delivery remains zero. This does not validate Convex projection latency, retry-drain throughput or production cost. A hard outbox/backlog policy, idle checkpoint cost, identical host-authority scenarios, actual Wi-Fi/LTE routes, device thermal/input/tracking tests and recovery/deployment evidence remain required. Local database allocation is not billed cloud storage or CPU time.

The implementation follows Cloudflare's [durable storage guidance](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/) and uses the existing `nodejs_compat` support for [Node crypto](https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/). Neither changes the application's authority or ticket contract.
