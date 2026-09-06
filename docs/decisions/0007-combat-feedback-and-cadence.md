# ADR 0007: Impact-only feedback and faster sidearm

- Status: Accepted product/implementation direction, 2026-09-04, from the owner's current request. Not device-promoted.
- Owner: Integration.
- Supersedes: ADR 0005 skeleton-on-lock presentation; spec and weapon-registry sidearm cooldown only. ADRs 0004–0006 physical acceptance requirements remain in force.

The sidearm fires at a minimum 150 ms interval (400 RPM ceiling), retains 8 rounds and a 1250 ms reload, and keeps 75/34/20 damage. A three-torso-hit elimination therefore takes 300 ms before delivery/presentation latency. This is provisional balance for device playtesting, not a measured production throughput claim.

The client starts cadence at dispatch and bounds cloud fire to one unresolved request. It renders a cosmetic tracer immediately, confirms hits separately, and preserves the exact request identity after an uncertain response. No new round is inferred from a retry. Holding the trigger repeats; release/background/death/reload stops repeat. Reload and presence are wired to existing frozen backend interfaces; all health/ammo/refill state remains authoritative.

A fresh camera ray without a valid target fires a miss. Production input never routes a failed targeting attempt into debug damage. Debug fire remains an explicit gated control until the existing physical evidence requirement is met.

The reticle stays at the camera viewport center. Skeleton joints and bones are visible only in a short accepted-hit flash, and vanish on stale tracking. Damage taken uses a separate vignette/haptic. Rendering uses fixed-capacity pools; cosmetic tracer motion does not determine hit timing.

No backend vendor migration is accepted by this record. [The architecture review](../research/production-combat-review.md) recommends proving the shared frame and connecting one deterministic authority before comparing a Durable Object per match with host-phone authority. Real projectiles, projectile slowdown and oriented phone shields have proposed contracts there; they are not live abilities in this slice.

Validation: canonical `pnpm verify`, simulation and native Swift tests, Debug and Release simulator builds. Promotion additionally requires two physical phones showing accurate hit-only feedback, safe hold/reload/reconnect behavior and measured frame times/latency, followed by four-phone identity/authority evidence before advertising four-player combat. Device evidence is recorded in the build log, never inferred from compilation.
