# Backend handoff — sustained combat reliability

Recorded 2026-09-06. The backend runtime agent completed this bounded checkpoint and released its write ownership to integration. Sustained combat acceptance remains incomplete.

## Checkout and ownership

Work in the primary checkout on `codex/native-load-driver`. The checkpoint began from `b52aa5a`, whose tree exactly matches merged main `f772afe` (PR #58). Integration rebases this focused change onto current main for publication; preserve the report source hashes and original failed observations.

The backend write set is `services/combat-worker/**` and `docs/research/backend-evidence/runtime-load/**`; integration owns this handoff and the build-log entry. Shared simulation/protocol packages, Convex, root configuration and Xcode need an explicit handoff. PR #60's incoming-laser and compact-HUD fixes are already merged. PR #61 independently repairs the production Convex deployment that blocks arena creation. No merge, deployment, signing or authority selection is part of this backend checkpoint.

## Immediate checkpoint

1. Finish startup cancellation and cleanup in the independent Node load driver. `createNodeRuntime()` must close its harness if startup is cancelled, `listen()` completes late, or initialization after listening fails. The calling test must pass its cancellation signal. Add focused failure/cleanup regressions.
2. Reproduce the remaining sustained-fire failure with evidence of command arrival, queue residence and the authority tick that consumes input. Investigate whether catch-up drains newly received commands into an older tick before changing scheduling. A clock-quality failure or authority recovery is a failed scenario, even if a short run passed.
3. For a proven runtime defect, add a deterministic regression, preserve before/after reports and repeat the unchanged acceptance scenarios. If a repair changes a shared timing/fairness invariant, freeze that decision with integration first.

The delivery checkpoint is this one demonstrated repair, its regression controls, the canonical gate and one serial attempt at each 30-second/three-minute scenario pair. Report unresolved sustained failures at that checkpoint; do not broaden into the rest of M5/M6 or repeatedly rerun until a pass appears.

The startup cleanup repair passes six focused lifecycle tests. A controlled queue hold with authenticated handler injection reproduced the catch-up defect: all 12 poses were consumed at logical time 150 ms, including eight captured at 170/220 ms that were rejected as future input. The room subsequently paused and cancelled its live projectile. This diagnostic excludes network transit and does not explain the earlier three-minute scenario interruptions.

Integration accepted a bounded scheduling repair on 2026-09-06: capture trusted monotonic time at WebSocket handler entry, before the serial queue; assign an input to `currentTick + max(1, ceil((receivedAtMs - cadence.anchor) / tickMs))`; consume only inputs eligible for the next tick and retain later arrivals. Client timestamps do not choose their execution tick. Sequence reservations, durable acknowledgements, validation and the existing large-stall recovery path remain in force. The initial after trace accepts all 12 poses at logical times 150/200/250 ms and keeps the room and projectile active. See `catch-up-before.json` and `catch-up-after.json` in the evidence directory.

Independent review found one reconnect edge: resetting cadence while deferred commands remain could execute a later sequence before its predecessor. The accepted fix preserves the active cadence while pending work exists and retains the original idle reset when no pending work remains. Its regression and forged-future/sequence/replay controls pass. Final canonical verification on the integrated delivery tree passes 314 tests, lint, types and builds, including the deterministic clock correction. The 12 focused cases also pass.

The unchanged serial load attempts still fail. Both complete 30-second scenarios preserve exact four-client ledgers and accepted/spawn/terminal identity, but coverage pauses cancel 32 of 352 miss-lane shots and 10 of 170 opposing shots. The requested three-minute scenarios stop early at 80,678 ms and 27,381 ms with clock-quality loss / authority recovery and 64 / 12 observed cancellations; both are explicitly unreconciled. Runtime and benchmark source manifests match across these attempts. No tuning or repeated attempts were used to manufacture a pass.

## Evidence already available

See [the runtime load report](backend-evidence/runtime-load/README.md) and its source-hash manifests.

| Evidence | Observed result |
|---|---|
| Canonical verification before the startup repair | `pnpm verify` passed 304 tests: 12 protocol, 43 shared simulation, 125 Convex, 75 worker/driver and 49 spectator, plus lint/types/build/repository checks. Re-run after changes. |
| Corrected 30-second independent-client scenarios | `node-heartbeat-30s.json`: miss lanes passed with 352 accepted shots; opposing combat passed with 136. Both had zero cancellation, four exact ledgers and matching accepted/spawn/terminal identities. |
| Corrected requested three-minute scenarios | `node-heartbeat-180s.json`: both failed before completion. Miss lanes stopped after about 12.52 seconds following authority recovery/epoch changes, with 40 cancelled bullets. Opposing combat stopped after about 93.07 seconds on clock-quality loss, with 24 cancelled bullets. Both are explicitly partial and unreconciled. |
| Earlier sustained scenario | `cached-180s.json`: opposing combat passed with 584 shots; miss lanes failed with 120 cancelled out of 2,096 accepted shots. Preserve it and the profiling/setup/provisional failures. |
| Previously interrupted backpressure test | A focused rerun passed unchanged in six seconds. The earlier long timeout is not evidence of a proven runtime defect. |
| After arrival scheduling, 30-second scenarios | `node-arrival-30s.json`: both complete and reconcile all shot identities and four ledgers, but fail the unchanged zero-cancellation gate (32 miss-lane / 10 opposing cancellations). All four players have 600 accepted poses with no pose refusals. |
| After arrival scheduling, requested three-minute scenarios | `node-arrival-180s.json`: partial failures at 80,678 / 27,381 ms, with 64 / 12 observed cancellations. No final ledger reconciliation is claimed. |

All four synthetic clients have separate sockets, clocks, pending pings and heartbeat schedules, but share one Node event loop and a common 20 Hz pose pump. The authority runs in a separate workerd process. These fixtures do not reproduce a camera, phone transport writer, physical Wi-Fi/LTE route or production cloud location. Per-run signing material stays in memory; the external projection endpoint is disabled.

## Verification and boundaries

```sh
pnpm verify
pnpm --dir services/combat-worker test:load:node
VKZ_LOAD_MS=180000 pnpm --dir services/combat-worker test:load:node
```

Run benchmarks without parallel local builds or tests. Record other observed load instead of assuming every stall is authority code. Preserve the native clock uncertainty/freshness limits, input age and epoch validation, fire/ammo/cooldown rules, zero-cancellation gate, bounded queues and exact durable event identity assertions. Do not turn a failed run into a pass by weakening them. A timed-out observation does not justify restarting a still-live process; check its actual handle first.

The next runtime investigation should capture server arrival, queue residence, processed tick and coverage age around a live scenario's first pause, with the existing native clock and acceptance rules. Accepted poses without refusals still coincide with coverage loss; the present reports do not isolate driver, runtime, transport and competing machine delays sufficiently to explain that failure. Do not describe this repair as a completed performance fix.

The three-minute failures remain open. Later M5/M6 requirements include projection delivery/backlog policy, idle cost, identical host-authority comparison, physical two/four-phone Wi-Fi/LTE measurements, recovery/durability/cost evidence, thermal/battery/accessibility and an authority-selection ADR. Refer to [the complete production review](production-combat-review.md) and [roadmap](../roadmap.md); this checkpoint does not replace their M0–M6 scope.

## Delivery

Return the exact write set, regression results, raw reports and unresolved acceptance failures to integration. Integration reviews the diff, records evidence in the build log, runs the canonical gate and publishes a focused draft PR against current main. Keep the failed and provisional evidence, and distinguish implementation, local synthetic performance, cloud measurements and physical-device acceptance. Do not print environment values, signing material, private device identifiers or complete process command lines.
