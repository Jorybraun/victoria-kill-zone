# Production combat architecture review

Date: 2026-09-04. Owner: Integration. Status: review and proposed next-slice contracts; this document does not select a new backend or accept an ADR.

The product owner's current direction is faster shooting, a skeleton visible only on a hit, a clear target indicator, shared visible bullets, possible phone shields and dodgeable slow projectiles. This review covers the active native iOS, simulation, transport, Convex and spectator architecture. Nothing under `archive /` was used. Integration handed off exclusive ownership of this report; implementation changes belong to their named owners.

**Recommendation: finish one shared-frame, authoritative combat path before attempting a backend replacement.** Keep the current game playable while improving input, hit feedback and reconciliation. The next substantial slice should prove that two phones see the same line in the same physical space, then connect that frame to the existing simulation and transport. A Durable Object per match is a credible cloud authority candidate for a measured comparison, not an established performance improvement for this game.

**Evidence status:** no physical-device measurements were collected for this review. The current build log has no accepted outdoor shared-frame, combat-latency, anatomical dodge or shield measurements. Proposed budgets below are acceptance targets, never measured results. A simulator build, fixture pass or signed TestFlight upload cannot close those gates.

## 1. What exists, and what still prevents the requested experience

Source references use file paths and symbols because this review accompanies concurrent implementation. The initial findings describe the starting checkout; the immediate hardening slice below explicitly addresses some of them. The integrated PR and build log must record final implementation and test results.

| Area | Starting evidence | Production consequence |
|---|---|---|
| Playable combat | [`DuelSession.defaultPeerLink`, `performMarkerlessFire`](../../ios/VictoriaKillZone/VictoriaKillZone/Features/Game/DuelSession.swift) construct `ArenaPeerLink` and call the Convex fire API. [`Package.swift`](../../ios/VictoriaKillZone/Package.swift) links the simulation/transport packages, but the playable duel does not instantiate the simulation authority. | Linked packages and tested fixtures do not establish an end-to-end authority path. |
| Fire cadence | `DuelSession` initially held one pending markerless request, used a 350 ms cooldown and stamped the cooldown when confirmation arrived. It required a locked hit zone and a living opponent. | Network delay makes the weapon slower, and the player cannot freely fire misses. Lowering a constant alone does not remove response-dependent pacing. |
| Incoming shots | Initial `updateIncomingShot` marked all unseen events as consumed but selected only the newest for presentation. Peer suppression used a two-second window for the shooter. | Several events in one subscription update lose visuals; an unrelated miss can be suppressed. Every shot needs its own identity and presentation transition. |
| Hit geometry | [`BodyTargetingGeometry.aimZone`](../../ios/VictoriaKillZone/VictoriaKillZone/Targeting/BodyTargetingGeometry.swift) estimates head/torso intersections locally; [`shots:fire`](../../convex/functions/shots.ts) receives the shooter's target, zone and confidence. | The backend controls damage and state, but does not independently establish that a body was intersected. This remains a client claim, not proven spatial authority. |
| Spatial frame | [`TargetingSession`](../../ios/VictoriaKillZone/VictoriaKillZone/Targeting/TargetingSession.swift) starts body tracking directly; the playable path does not implement ADR 0006's map-seeding procedure. | Equal coordinate numbers on two phones do not denote the same physical point. A cloud backend cannot fix unrelated AR origins. |
| Tracers | Initial [`LaserFXEngine`](../../ios/VictoriaKillZone/VictoriaKillZone/Features/Game/LaserFX.swift) drew a 25 m beam and moved a visual sphere for 0.4 seconds. Incoming beams were reconstructed from an observed body or camera-relative fallback toward the receiver. | These are presentation effects. They do not represent an authoritative moving bullet that can be dodged. |
| Simulation | [`MatchSimulation`](../../shared/simulation/Sources/PewPewSimulation/MatchSimulation.swift) is a deterministic 20 Hz hitscan core with rewind; [`ProjectileWorldline`](../../shared/simulation/Sources/PewPewSimulation/ProjectileWorldline.swift) calculates position but explicitly lacks collision, damage and expiry. | Projectile gameplay still needs a complete lifecycle and collision rules, not just animation. |
| Body representation | [`PoseSample`](../../shared/simulation/Sources/PewPewSimulation/PoseHistory.swift) contains position and tracking state; [`ProxyGeometry`](../../shared/simulation/Sources/PewPewSimulation/HitZoneGeometry.swift) uses fixed offsets around the phone. | This cannot establish actual head/torso motion during a duck. A phone held out from the body moves the proxy without moving the person. Position-only data cannot orient a phone shield. |
| Multiplayer | The simulation supports 2–4 members, while the duel selects the first opponent and targeting selects the first body anchor. | Increasing the lobby cap would not produce correct four-player body identification or targeting. |
| Peer trust | [`ArenaPeerLink.parameters`](../../ios/VictoriaKillZone/VictoriaKillZone/Targeting/SharedArena/ArenaPeerLink.swift) creates plain TCP parameters. `DuelSession` checks a payload's claimed player ID. | Matching an identifier in an unauthenticated packet is not proof of peer identity. Keep this provisional visual path out of health and ability authority. |
| Durability | [`shots:recordVerdict`](../../convex/functions/shots.ts) and [`verdict-ledger.v1`](../interface-contracts.md) exist, but the native host does not post simulation verdicts to them. | A server ledger endpoint alone does not complete simulation reconciliation or reliable delivery. |
| Subscriptions | [`ConvexGameSessionClient`](../../ios/VictoriaKillZone/VictoriaKillZone/Services/ConvexGameSessionClient.swift) already subscribes to match state. [`queries.ts`](../../convex/functions/queries.ts) returns a bounded recent-event window. | There is no polling interval to remove. At higher shot rates, recent snapshot events also cannot substitute for acknowledged, replayable combat events. |

The simulation also needs ingress hardening before exposure to an untrusted network. Its current evaluator validates finite ray values, membership, life state, rewind and tracking, but does not bind a claimed muzzle to a fresh shooter pose, carry a frame epoch or maintain a terminal shot-ID replay cache. An authority adapter must establish these invariants rather than assuming a pure simulation package is complete anti-cheat.

## 2. Immediate improvement slice

The implementation accompanying this review is scoped to a 150 ms configured cadence, firing valid misses, heartbeat/reload plumbing, hit-only skeleton feedback, a clearer combat HUD and narrower backend reads/idempotency. See the accepted implementation packet and actual diff; this report does not certify that any of those changes have shipped.

Acceptance of that slice should mean:

- Input produces immediate muzzle/audio/haptic presentation. A speculative shot never produces a confirmed hit marker or damage announcement.
- Cadence is measured from dispatch, independently of acknowledgement. Pending requests and locally reserved ammunition are bounded; snapshot reconciliation cannot grant extra ammunition or make old confirmations replace newer state.
- A held trigger stops on release, loss of app focus, reconnect lock, reload, death and match end. Slow or failed networking cannot create an unbounded task backlog.
- Firing away from a target sends a miss claim that consumes ammunition under server rules. Invalid tracking and transport state have explicit behavior.
- The full skeleton remains hidden during ordinary aim. A fresh, correctly associated target can have a small bracket; a confirmed hit briefly reveals the skeleton and impact marker. A delayed result must not flash a newly tracked, different person.
- Every incoming shot in a batch is processed; predicted visuals, acceptance and confirmed impacts reconcile by shot identity. Exact wire additions remain integration-owned.
- Server rules remain authoritative for cooldown, reload, life, ammunition, idempotency and permitted membership. Backend performance changes should reduce unnecessary reads without dropping validation.

This produces better feedback and responsiveness. It does not establish shared projectile trajectories, physical dodging, shield blocking, four-player targeting or a new authority runtime.

## 3. Authority and Durable Objects decision

The accepted [ADR 0003](../decisions/0003-multiplayer-first-refounding.md) separates combat from durable records. [ADR 0004](../decisions/0004-realtime-combat-authority-and-transport.md) proposes host-phone authority; [ADR 0006](../decisions/0006-duel-shared-frame.md) proposes map-seeded body tracking. Both still require their device evidence. The user's renewed feature direction permits investigating projectiles, shields and slowdown, but has not chosen a replacement backend.

| Option | Concrete strengths | Work and limits | Recommendation |
|---|---|---|---|
| Current Convex claim path | Existing sessions, transactions, subscriptions, durable records and spectator. | Geometry is a client claim; durable mutation completion remains on the combat path. It has no projectile simulation. | Retain as the playable migration path while the next slice is proven. |
| Host phone + `CombatTransport` + Convex ledger | Reuses the Swift simulation and native QUIC transport; co-located packets can avoid a WAN round trip. | Requires calibration, authentication, clock sync, host adapter, ordered ledger delivery and reconciliation. Host can cheat or leave; latency advantage must be measured. | First implementation candidate for the current co-located product. End the match on host loss in Phase 1. |
| One Durable Object per match + Convex projections | A single room can serialize combat decisions, maintain WebSocket clients and colocate durable state. Removes host-phone outcome authority. | Requires a deployable simulation implementation, room authentication, client transport, recovery, telemetry and measured WAN budgets. Cloud authority still trusts phone sensing. | Build a bounded comparison after the simulation contract is fixed; select through an ADR based on evidence. |
| Replace all Convex services with DOs now | Potentially one provider for combat and records. | Also recreates matchmaking, sessions, queries, spectator projections and operations before demonstrating better combat. | No evidence justifies this scope today. |

Convex already provides reactive query subscriptions and serializable atomic mutations. Those properties are useful for durable projections and are not evidence that it should run the rendering/simulation loop. [Convex realtime](https://docs.convex.dev/realtime), [transaction guarantees](https://docs.convex.dev/database/advanced/occ).

Cloudflare supports one stateful coordination object per game, SQLite-backed storage and WebSockets. Each object runs in one location; it is not simultaneously a room at every edge. Creation location and optional hints influence latency, but hints are not guarantees. Measure from actual play sites and networks. [DO design rules](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/), [data location](https://developers.cloudflare.com/durable-objects/reference/data-location/).

An active tick loop prevents hibernation. Hibernatable WebSockets help idle lobbies, but critical state must be restored after memory loss. Alarms provide at-least-once scheduled execution and one alarm per object; their API precision is not a real-time tick-delivery guarantee. Use them for durable deadlines and cleanup, not an assumed precise 20/60 Hz clock. [WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/), [alarms](https://developers.cloudflare.com/durable-objects/api/alarms/).

A DO prototype should use an authenticated Worker entry point, one SQLite-backed object per match, bounded WebSocket inputs, monotonic sequence numbers, checkpoint/replay recovery and a durable outbox for Convex. Persist confirmed events before publishing them as durable. Persisting every ephemeral pose is not automatically necessary, but crash recovery must explicitly pause and rebuild fresh pose history before resuming collision. An active match pays active-runtime costs; benchmark the chosen policy rather than assuming hibernation makes an active shooter cheap.

Workers run JavaScript/WASM; the existing Swift package is not directly reusable as Worker application code. Choose either a deployable shared core or a TypeScript implementation checked against identical authoritative fixtures. Do not quietly maintain diverging damage/collision implementations. [DO runtime](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/).

## 4. Proposed combat contracts

These are proposed next-slice contracts, not current public APIs. Integration must freeze their precise encodings, constants and ownership in `docs/interface-contracts.md` before parallel implementation. Player sets support 2–4 members. No persistent accounts, markers, video transport or physical accessories are required.

### Common envelope and authority ownership

All accepted combat events contain `protocolVersion`, `matchID`, `authorityEpoch`, monotonic `eventSequence`, `frameEpoch`, `simulationTick` and `matchTimeMs`. Client commands add authenticated `playerID`, monotonic `clientSequence` and a stable `commandID`; fire commands add a stable `shotID`. A payload cannot assert its own authentication.

The authority deduplicates commands and replays their original result. Reusing an ID with changed payload is rejected. Envelopes have fixed size/rate bounds; future timestamps, expired sessions, unknown members, stale epochs and invalid numbers are rejected before simulation.

One authority owns combat health, ammo, cooldowns, reload, protection, shield energy and projectile verdicts for an active match. Convex records the resulting ordered projection; it must not independently advance competing combat state. The current ledger's re-derived damage and lifecycle checks therefore need an explicit reconciliation contract before the host is wired. A projection disagreement pauses/flags the match for repair; it never silently picks a second live verdict.

Authority mode is frozen at match start. Changing authority requires a new epoch and explicit resume protocol; silent host/cloud fallback is out of scope. For the first host slice, host loss ends the match. Resume data cannot include reusable private session secrets in public events.

### Shared clock and shared frame

`MatchClockEstimate` contains authority-relative monotonic time, round-trip estimate, offset and uncertainty. Synchronize through timestamped exchanges and periodically refresh; reject outliers. Device wall-clock time and another phone's uptime are not interchangeable. Use wall time only for durable external timestamps.

`SharedFrameState` contains frame epoch, calibration method, ready/degraded state, residual translation/rotation, observation time and relocalization generation. Accept spatial fire only when all required participants have acknowledged the same usable epoch. Calibration reset invalidates old poses and projectiles according to an explicit pause/cancel policy; stale geometry never crosses epochs.

Proposed timing gates: 20 Hz pose publication, p99 sample interval at most 100 ms, clock uncertainty at most 25 ms before spatial fire. The 25 ms value is a proposed engineering budget requiring device validation; the existing spatial requirements supply the 100 ms pose-age ceiling and 250 ms maximum rewind. The hit envelope, speed and network budget must be evaluated together before approving either.

`PlayerPoseSample` contains player ID, frame epoch, sequence, capture time in match time, phone position, normalized phone orientation, tracking quality and association quality. A separate optional `BodyColliderSample` contains timestamped head sphere and torso/limb capsule endpoints, their uncertainty and the observation source. Phone pose is not renamed to body pose. Invalid or stale body observations cannot become a confirmed anatomical hit.

### Projectiles and collision

`FireIntent` contains shot ID, weapon-definition version, pose sequence, origin, normalized direction and intended match time. It does not nominate damage or a winning target. The authority validates a fresh shooter pose, plausible muzzle offset, match rules, cooldown/ammo and timestamp bounds, then emits `ProjectileSpawn` or a refusal.

`ProjectileSpawn` contains projectile/shot IDs, shooter ID, frame/authority epochs, spawn tick/time, origin, initial velocity, acceleration, radius, expiry time, range limit and weapon version. For the first dodgeable weapon, use zero gravity and a bounded speed. A candidate tuning value is 8 m/s, not a frozen production constant.

Every renderer evaluates the same worldline from spawn parameters and authoritative segment changes. It interpolates at display cadence independently of network publication cadence. Stream spawn, segment changes, corrections and terminal events; do not stream every rendered position.

Authority collision uses swept segments or continuous collision detection against time-varying target volumes. Testing only the projectile point once per 50 ms tick can skip a body. Test the earliest shield/body/world hit within an interval, with deterministic ties and bounded numerical tolerances. Scope environmental collision explicitly: the current body-tracking path does not provide a shared, authoritative scene mesh, so walls/cover cannot be advertised as reliable yet.

`ProjectileTerminal` contains the projectile ID, one terminal reason (`bodyHit`, `shieldBlocked`, `missExpired`, `worldImpact` when supported, or `cancelled`), impact time/position, resolved target/zone, applied damage, authority sequence and any uncertainty/rejection explanation. Exactly one terminal outcome affects gameplay. Misses also receive a terminal event. Duplicate delivery cannot spend another round or apply damage twice.

Hitscan can keep bounded historical rewind. A slow projectile must collide with target movement throughout its flight, not with the target pose at firing time. Freeze the late-input policy: delay authoritative presentation by a bounded reconciliation window or revise provisional outcomes before durability. Never rewind an already visible flight solely to award the shooter a hit after the defender moved clear. Track fairness corrections and rejected late inputs in tests and field evidence.

### Slow fields and bullet time

Start with an explicit projectile slow field rather than personal camera slow motion. `SlowFieldCommand` requests activation; the authority checks player life, cooldown and charges. `SlowFieldEvent` contains field ID, owner, frame epoch, sphere centre/radius, authoritative start/end ticks, projectile time scale and affected-projectile rule. The initial contract can affect all projectiles inside the sphere, with no team or shooter exceptions.

The authority applies one rule on every device. Proposed semantics: overlapping fields use the smallest time scale, never multiplication; scale is clamped to a frozen minimum; duration and ability cooldown use normal match time. Real body motion, camera capture, pose publication and reload/cooldown clocks remain at real time. The ability grants a physical opportunity to move, not a slower video of an already adjudicated hit.

At a boundary crossing or activation/expiry, authority emits a new projectile worldline segment anchored at the exact crossing time and position, preserving position continuity and recording the new velocity/time scale. Sequence every segment change. Renderer latency may produce a correction, but cannot change collision rules. Test entering/exiting, spawning inside, overlapping fields, expiry, simultaneous activation and replay after interruption.

The first experiment may simplify to a match-wide projectile slow interval, but that is a separately named ruleset, not equivalent to a local shield/field. No slider should imply working slow-field physics before its authority path exists.

### Phone shield

Treat the phone as the control/anchor for a visible virtual shield, not proof of a physical body posture. `ShieldCommand` contains activate/deactivate intent and a pose sequence. `ShieldState` contains active interval, energy, cooldown, disc radius, local centre offset, front-face normal and player/frame epochs. Shield dimensions are game tuning, not physical phone dimensions.

The authority derives the disc from validated phone position/orientation. It checks the incoming projectile's swept front-face intersection and nearest impact before body collision, then spends energy and emits `shieldBlocked`. Define back-face behavior, simultaneous damage ordering, startup delay, break event and fire-while-shielded behavior before implementation. Recommended first ruleset: front-facing only, no shooting while active, bounded duration/energy, normal-time recharge.

Stale phone pose cannot award a block. Loss of tracking pauses the player's spatial interaction under the same match policy used for body targeting; simply making an untracked player invulnerable is not a valid recovery rule.

## 5. Spatial feasibility and fairness limits

Apple documents `ARBodyTrackingConfiguration.initialWorldMap`. That makes ADR 0006's map-seeded body-tracking experiment technically grounded. It does not prove that two moving phones outdoors stay within the required hit-registration error budget. Apple distinguishes body tracking from collaboration and scene reconstruction, and advises enabling costly AR features selectively. [Body initial map](https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration/initialworldmap), [AR configuration guidance](https://developer.apple.com/documentation/arkit/configuration-objects).

The current native implementation uses one body observation and has no association between arbitrary detected people and match membership. Four-player combat needs a measured association provider. Project known phone poses into the camera image and associate observations only when unambiguous; preserve identity across occlusion and reject swaps. A skeleton near a phone is not automatically the phone owner's skeleton.

Skeleton motion is an estimate. Apple exposes which joints are actually tracked; some skeleton joints follow their parent rather than independent observations. Scale estimation is necessary because estimated physical body size affects inferred world position. Carry observed quality through to collision, rather than replacing it with a permanently high confidence number. [Apple motion capture explanation](https://developer.apple.com/videos/play/wwdc2019/607/), [body scale estimation](https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration/automaticskeletonscaleestimationenabled?language=objc).

The rear camera normally observes other people, not its holder's complete body. A defensible anatomical dodge needs a fresh observer-associated body collider or another proven measurement source. The phone proxy can support a clearly labelled phone-target experiment, but must not be presented as accurate head/torso duck detection. Moving only the phone is a required negative test.

For a speed of 8 m/s, flight time is 375 ms at 3 m, 1,000 ms at 8 m and 1,875 ms at 15 m. At 10 m it is 1,250 ms. These are `distance / speed` calculations. Available movement time is smaller by one-way delivery, clock uncertainty, render latency and perception delay. Realistic fast-bullet speeds at these distances do not create a useful dodge window. Tune intentionally slow virtual projectiles and measure the actual visible warning-to-impact interval.

## 6. Measurable delivery milestones

Existing ADR budgets are identified below. Additional targets are proposals to freeze in each slice, not statements of achieved performance. Each device run records model/iOS, tested commit, method, sample counts, p50/p95/p99 and observed failures without identifiers or credentials.

| Milestone | Observable deliverable | Acceptance and blocker |
|---|---|---|
| M0 — Current combat feedback/cadence | Hit-only skeleton, target indicator, responsive fire/miss/reload and stable reconnect state. | `pnpm verify` plus the repository iOS gate. Inject delayed/reordered replies and repeated snapshots. Demonstrate no extra ammo/damage, no speculative hit marker and no dropped burst events. On two phones, run a sustained magazine/reload sequence and record requested versus accepted shot intervals. No device run exists here. |
| M1 — Shared-frame proof, next critical slice | Two phones calibrate into one frame and display the same endpoints and tracer. | Execute ADR 0006 S0 with the named map-seeding procedure. Measure residual at 3/8/15 m, drift over a full three-minute duel, relocalization/reset and transfer time. Existing planning gates are 0.10 m / 0.5 degrees; fail closed beyond the approved budget. Mark readiness unavailable if this fails. |
| M2 — One authority reaches the playable app | `CombatTransport` sends validated input to `MatchSimulation`; verdicts reach both phones and ordered Convex projections. | Existing ADR 0004 targets: fire-to-host verdict p95 ≤50 ms; durable confirmation p95 ≤500 ms; pose interval p99 ≤100 ms; five agreeing kill/respawn cycles. Exercise host loss, reconnect, stale epochs and duplicate events. Repeat with four phones before claiming four-player play. |
| M3 — Authoritative projectiles | Shared spawn/segment/terminal events with swept moving-target collision. | Fixture matrix covers grazing, tunnelling, moving away, entering the path, simultaneous impacts, expiry and late inputs. Proposed field test: at least 30 deliberate dodge and 30 stationary-control shots per chosen distance; record ground-truth misses/hits and false verdicts. Approve thresholds with the product owner before the run; do not call a visual dodge successful solely because an animation passed. |
| M4 — Shield and slow-field trial | One frozen shield ruleset and one synchronized field ruleset. | Deterministic boundary/overlap/energy/cooldown tests. Two-phone filmed block versus back-face/body-control trials, plus phone-only movement tests. Both clients and ledger must agree on terminal reason; no invisible retroactive blocks or slowdown. |
| M5 — Authority comparison | Identical scenarios on host authority and one DO-per-match prototype. | Use two/four physical phones over the actual local Wi-Fi and LTE/5G routes; compare verdict p95/p99, pose age, corrections, reconnect time, durability and cost per active match. Select or reject DO in an ADR from these measurements. No backend migration is approved by this report. |
| M6 — Release evidence | Sustained playable match, clear failure states and repeatable installation. | Device thermal/frame pacing and battery measurements over repeated matches; memory/queue ceilings; camera/network permission recovery, accessibility, background/foreground and disconnect checks. Record signed/TestFlight install evidence separately from gameplay evidence. Promote only the verified canonical SHA through the delivery pipeline. |

For rendering, propose a 60 fps target on the supported device tier, measured with frame-time percentiles during sustained play. Budget pooled projectile/hit nodes, material reuse and retained haptic/audio resources. A bounded lower-quality mode may preserve play when thermal state degrades; it must not change authoritative collision geometry. Device support and final frame-time thresholds belong to the release contract.

## 7. Next task and boundaries

**Next task: implement and run ADR 0006 S0, then deliver one shared-frame tracer in the playable duel.** Do not simultaneously rewrite lobby storage, replace the renderer and deploy a new backend. The shared-frame result decides whether the intended physical game is credible and supplies the missing input to every later authority choice.

Integration owns the frame/clock/event contract, Xcode wiring and accepted decision. Targeting owns calibration, pose quality and body association. The game owner consumes those contracts for presentation and input. Backend owns ordered idempotent projections. Design freezes only the next accepted slice. A future Cloudflare runtime requires an explicit write-boundary handoff; it is not implicitly part of `convex/**`.

Keep `shots:debugFire` and the current migration path until physical markerless evidence permits retirement. Keep Convex credentials, session capabilities, signing material and private device data out of logs, reports and screenshots. Follow [`docs/delivery-pipeline.md`](../delivery-pipeline.md): short-lived branch, draft PR, canonical verification, then promotion gates. Record passed evidence and remaining blockers in [`docs/build-log.md`](../build-log.md).

This report itself changes no runtime behavior and contains no completed device, cloud deployment or latency benchmark.
