# Combat simulation

Pure deterministic TypeScript combat authority for a frozen roster of 2–4 players. It contains no network, storage, wall-clock, ARKit, or Convex calls. The Durable Object adapter is one host; another host must use this same core and authority epoch contract, never run a second damage authority for the same match.

```ts
const simulation = CombatSimulation.create({matchId, authorityEpoch, frameEpoch, players, rules});
simulation.setConnected(playerId, true);
const candidate = simulation.fork();
const events = candidate.advance(authenticatedCommands); // exactly one 50 ms tick
await commit(candidate.checkpoint({includeTracking: false}), events, commandResults);
// Only after durable commit: replace the live simulation and broadcast events.
```

The adapter owns authentication, roster admission, command sequence enforcement, bounded retries, event numbering, durable ordering, tick scheduling, and clock synchronization. Every admitted command receives one `commandResult`; fire refusals also emit `fireRefused`. Sequence/idempotency is intentionally not duplicated inside the core. A retry must retain its complete original envelope. A new sequence is a new gameplay action. `shotId` correlates prediction; projectile identity additionally includes the authority epoch and command sequence so terminal IDs are never reused by a later shot.

## Clock and collision contract

- `advance` increments logical match time by exactly 50 ms. Commands and camera samples use this synchronized room clock. No method reads wall time. Frame readiness requires reported position residual ≤10 cm, angular residual ≤0.5°, and clock uncertainty ≤25 ms.
- The only combat geometry is `sighting` (ADR 0013): each phone keeps its own AR frame and a `fire` command carries the shooter's own `BodyObservation` of the single opponent. The verdict resolves instantly at admission in the shooter's camera space — no shared frame, no rewind, no traveling projectile. Missing, stale (>1 s), or low-quality observations refuse the shot; a roster that does not resolve to exactly one opponent refuses as ambiguous.
- Input older than 250 ms or future input is refused. A referenced firing phone pose must be no more than 100 ms old; the origin must be within 0.5 m of that pose and aim within 15° of its camera direction. Health, protection, ammunition, and abilities use admission-time state.
- Connected players are the only spatial coverage; losing a connection pauses combat. Slow fields stay on the wire but are refused as invalid input on the fire path today.
- Position motion is bounded to 15 m/s plus 0.1 m sample slack; phone orientation is bounded to four turns/second plus angular slack. Capsule length is capped at 3 m and radius changes at 5 cm/sample. These reject implausible data; they do not prove camera truth, honest association, or correct alignment.
- A sighting shot resolves nearest contact on the ray through the observed colliders, shield before body. This makes death and shield-energy results deterministic at admission. The adapter must not promise fairness finer than the 50 ms admission tick.

## Abilities and bounded state

The phone shield is a front-facing thin disc offset along the rear camera direction. Its center and normal interpolate across phone samples. Only a front-to-back center-plane crossing blocks; its rim includes bullet radius. This is an explicit virtual shield model, not an exact sphere-versus-moving-solid collision. A successful block spends torso damage from shield energy, absorbs the complete shot, and disables the shield at zero energy. Shield activation has a fixed duration and cooldown; lowering it does not reset cooldown. An active shield prohibits shooting and reloading.

Slow fields are static spheres centered at the activating phone pose. Flight splits continuously at entry, exit, and field expiration. Overlaps use the minimum scale, never multiplication. Reload, respawn, protection, input, and ability cooldowns remain on the ordinary shared clock. The fixed roster and ability cooldown bound fields to four; projectile count is capped at 128, each path has a 256-subdivision guard, and lifetime/range always terminate flight. Expired fields publish their original end time. Pause/recovery cancels live fields and shields while retaining cooldowns.

Match time continues across ordinary pause ticks. Reload and respawn complete on this clock; a respawn receives protection. Match duration is measured from `snapshot.roundStartedAtMs`, which is null until the first accepted host start and remains unchanged across pauses and recovery. A host cannot reset duration by starting again. A paused match resumes only after complete spatial coverage returns. A storage or process outage does not advance this logical clock by wall-clock downtime.

## Recovery and public state

`checkpoint()` is JSON-safe and includes bounded private phone histories. Storage adapters should use `checkpoint({includeTracking: false})`: it omits private histories and public latest poses, which recovery always invalidates, while preserving every score, ammo count, cooldown and lifecycle timer. `parseCheckpoint(unknown)` validates persisted structure, numeric ranges, roster references, monotonic histories, and agreement between public latest poses and private phone history. `fork()` preserves all state for speculative durable staging, sharing immutable historical sample values while copying their containers and mutable gameplay state.

`restore(unknown, {authorityEpoch, frameEpoch})` requires a newer authority epoch and a nondecreasing frame epoch. It preserves score and logical time, cancels live projectiles, removes fields/shields, clears all camera histories and public poses, marks players disconnected and unready, and pauses unfinished matches. `takeRecoveryEvents()` returns the cancellation/state events once. The adapter must require reconnect, clock sync, and frame readiness before combat resumes.

`snapshot().phonePoses` and `poseChanged` expose only accepted latest phone samples for association and oriented shield presentation. Consumers must still honor player readiness, pose age, authority epoch, and frame epoch. Snapshots and returned checkpoints are detached copies; renderer mutation cannot alter authority state.

## Evidence and remaining release gates

Run `pnpm --filter @vkz/combat-simulation test` and `pnpm --filter @vkz/combat-simulation typecheck`. Fixtures cover 2 players, input validation, cadence, sighting hits/misses, shield front/back/energy, reload/death/respawn/protection, tracking loss, bounded state, deterministic delivery, staging isolation, and corrupt/recovered checkpoints.

These are deterministic software fixtures. No physical-device alignment residual, network latency, camera association accuracy, sustained cloud tick CPU, thermal behavior, or real human dodge window has been measured by this package. Those remain release gates in the architecture review. In particular, self-reported frame residual and self-reported sightings are not a competitive anti-cheat system.
