# Backend handoff — sustained combat reliability

Updated 2026-09-06. PR #62's scheduling/load-driver checkpoint is merged. The benchmark-only first-pause trace and its single 30-second pair are complete, with an arming-boundary limitation preserved below. The immediate live blocker is missing combat configuration. Sustained combat and physical-device acceptance remain incomplete.

## Checkout and ownership

The scheduling/load-driver checkpoint began from `b52aa5a`, whose tree exactly matches merged main `f772afe` (PR #58), and was published as PR #62 at `0dd5ae7` before merging to main `7a1a529`. The trace was measured in `/tmp/vkz-combat-coverage-trace`, branch `codex/combat-coverage-trace`, from `7a1a529`. Integration has since advanced this checkout to merged main `541c06e01d530ca36d60d620454a953616dff082` (PR #64). Preserve the report's original HEAD and source hashes; the later documentation/verification checkpoint does not relabel the measured source.

The trace write set is limited to `services/combat-worker/benchmarks/**`, its focused test and new runtime-load evidence/README. Integration also delegated this documentation checkpoint's `docs/roadmap.md`, `docs/research/backend-handoff.md` and `docs/build-log.md`; production runtime, shared packages, Convex, root configuration and Xcode remain outside it. The diagnostic agent performed no Git mutation, external write or deployment; root integration owns publication.

## Live configuration and release handoff

PR #60's incoming-laser and compact-HUD fixes are merged. PR #61 repaired the Convex module paths blocking arena creation; production Deploy run `34066724479` succeeded on main `77ce2e8`, including both smokes. The subsequent phone retry now reaches **Align Arena**, then reports that live combat is not configured. This is progress past the earlier creation failure, not successful combat or calibration acceptance.

The current production deploy key's environment query was denied for missing `deployment:env:view`. Separately, an authenticated Convex dashboard check confirmed that no environment variables are configured. The absence finding comes from the dashboard, not the denied query. Private keys have been prepared through the separate release handoff; user paste is still pending. Do not inspect, print or copy secret files as part of this diagnostic/documentation task.

PR #64 merged at main `541c06e01d530ca36d60d620454a953616dff082` and gates TestFlight on deployed-backend evidence. Draft [PR #65](https://github.com/Jorybraun/victoria-kill-zone/pull/65), head `9f74e8716cd2999e62792108154a78094921a5c5`, adds guarded Worker deployment. It has not deployed the Worker. Configuration, reviewed deployment and a new phone retry belong to that separate release handoff; neither the local trace nor PR #64 supplies them. Production authority selection and M5/M6 acceptance remain open.

## Completed PR #62 checkpoint

This checkpoint delivered startup cleanup, one demonstrated catch-up repair, regression controls, the canonical gate and one serial attempt at each 30-second/three-minute scenario pair. Unresolved sustained failures remain preserved; there were no repeated attempts to manufacture a pass.

The startup cleanup repair passes six focused lifecycle tests. A controlled queue hold with authenticated handler injection reproduced the catch-up defect: all 12 poses were consumed at logical time 150 ms, including eight captured at 170/220 ms that were rejected as future input. The room subsequently paused and cancelled its live projectile. This diagnostic excludes network transit and does not explain the earlier three-minute scenario interruptions.

Integration accepted a bounded scheduling repair on 2026-09-06: capture trusted monotonic time at WebSocket handler entry, before the serial queue; assign an input to `currentTick + max(1, ceil((receivedAtMs - cadence.anchor) / tickMs))`; consume only inputs eligible for the next tick and retain later arrivals. Client timestamps do not choose their execution tick. Sequence reservations, durable acknowledgements, validation and the existing large-stall recovery path remain in force. The initial after trace accepts all 12 poses at logical times 150/200/250 ms and keeps the room and projectile active. See `catch-up-before.json` and `catch-up-after.json` in the evidence directory.

Independent review found one reconnect edge: resetting cadence while deferred commands remain could execute a later sequence before its predecessor. The accepted fix preserves the active cadence while pending work exists and retains the original idle reset when no pending work remains. Its regression and forged-future/sequence/replay controls pass. Final canonical verification on the integrated delivery tree passes 314 tests, lint, types and builds, including the deterministic clock correction. The 12 focused cases also pass.

The unchanged serial load attempts still fail. Both complete 30-second scenarios preserve exact four-client ledgers and accepted/spawn/terminal identity, but coverage pauses cancel 32 of 352 miss-lane shots and 10 of 170 opposing shots. The requested three-minute scenarios stop early at 80,678 ms and 27,381 ms with clock-quality loss / authority recovery and 64 / 12 observed cancellations; both are explicitly unreconciled. Runtime and benchmark source manifests match across these attempts. No tuning or repeated attempts were used to manufacture a pass.

## Completed first-pause trace checkpoint

The benchmark-only entrypoint observes handler entry, queue residence, admission, assigned/consumed ticks, accepted poses and the exact failed coverage interval. It retains 64 inputs, eight ticks and one bounded 32,768-byte record. Its local arming RPC completes after warmup and before measurement; production routing, independent clocks and acceptance thresholds are unchanged. Five observer regressions plus the existing startup/scenario lifecycle tests pass: 20 focused tests, worker typecheck and lint.

The single [30-second trace pair](backend-evidence/runtime-load/node-first-pause-30s.json) passed unchanged acceptance: miss lanes had 352 accepted/durable shots, opposing combat 136, both with zero cancellation, all four exact ledgers and accepted/spawn/terminal identities matching, and zero unresolved bullets. Both observers were armed with no malformed records. Miss lanes had no trace. Opposing combat paused at the first post-arm tick, 47 (2,350 ms), before its first measured pose send, then restored at tick 48; about 51 ms paused was observed. A passing scenario therefore does not establish absence of pauses.

At that boundary, accepted poses were 119.7–120.3 ms old. Four new poses were pending for tick 48, so tick 47 had zero eligible inputs; queue residence was 0 ms at the available resolution and cadence lag was 55 ms. The approximately 117 ms capture gap may include shared-Node-loop interference from obtaining the harness environment/DO proxy at arming. No separate probe isolated that cost. This record does not explain earlier sustained cancellation or three-minute interruptions. Preserve the raw report and limitation; no caching change or additional benchmark is included in this checkpoint.

One canonical `pnpm verify` on the trace delivery tree, based on main `541c06e01d530ca36d60d620454a953616dff082`, passed 319 tests (12 protocol, 43 simulation, 125 Convex, 90 worker/driver, 49 spectator), both release self-test suites, lint, types, builds, repository checks and Worker dry run. Log: `/tmp/vkz-coverage-trace-verify.log`. All 45 source/configuration hashes in the saved measurement still match this checkout. This verifies the trace tree, not the separate draft PR #65. All diagnostic processes are terminal; paths are released to root integration for review/publication.

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
| Benchmark-only first-pause trace, one 30-second pair | `node-first-pause-30s.json`: both pass, 352/136 shots and zero cancellation; four exact ledgers and shot identities reconcile. Opposing combat records the arming-boundary pause described above; it is not a sustained-failure diagnosis. |

All four synthetic clients have separate sockets, clocks, pending pings and heartbeat schedules, but share one Node event loop and a common 20 Hz pose pump. The authority runs in a separate workerd process. These fixtures do not reproduce a camera, phone transport writer, physical Wi-Fi/LTE route or production cloud location. Per-run signing material stays in memory; the external projection endpoint is disabled.

## Verification and boundaries

```sh
pnpm verify
pnpm --dir services/combat-worker test:load:node
VKZ_LOAD_MS=180000 pnpm --dir services/combat-worker test:load:node
```

Run benchmarks without parallel local builds or tests. Record other observed load instead of assuming every stall is authority code. Preserve the native clock uncertainty/freshness limits, input age and epoch validation, fire/ammo/cooldown rules, zero-cancellation gate, bounded queues and exact durable event identity assertions. Do not turn a failed run into a pass by weakening them. A timed-out observation does not justify restarting a still-live process; check its actual handle first.

A later authorized runtime investigation must distinguish arming/probe overhead from sustained handler arrival, queue residence and coverage loss before proposing another repair. The new trace captures those boundaries, but its observed pause is confounded by initialization at the measurement boundary. Prior accepted poses without refusals still coincide with sustained coverage loss; no report yet separates driver, runtime, transport and competing machine delays sufficiently to explain it. No further benchmark is authorized by this documentation checkpoint.

The three-minute failures remain open. Later M5/M6 requirements include projection delivery/backlog policy, idle cost, identical host-authority comparison, physical two/four-phone Wi-Fi/LTE measurements, recovery/durability/cost evidence, thermal/battery/accessibility and an authority-selection ADR. Refer to [the complete production review](production-combat-review.md) and [roadmap](../roadmap.md); this checkpoint does not replace their M0–M6 scope.

## Delivery

Return the exact write set, regression results, raw reports and unresolved acceptance failures to integration. Integration reviews the diff, records evidence in the build log, runs the canonical gate and publishes a focused draft PR against current main. Keep the failed and provisional evidence, and distinguish implementation, local synthetic performance, cloud measurements and physical-device acceptance. Do not print environment values, signing material, private device identifiers or complete process command lines.
