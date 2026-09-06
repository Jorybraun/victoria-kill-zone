# ADR 0008 — Execute the complete production-combat review

Status: accepted implementation scope, 2026-09-05, from the owner's repeated instruction to complete everything in the review. Production authority selection and physical promotion remain evidence-gated.

The full [review](../research/production-combat-review.md) is the deliverable: M0 feedback, M1 shared frame, M2 one authority, M3 projectiles, M4 shield/slow fields, M5 host/DO comparison, M6 release evidence. No milestone is complete merely because its design or an unlinked package exists. All existing safety/device gates remain.

Implement a Cloudflare Durable Object per match as the cloud authority candidate alongside the existing Swift host candidate, with protocol parity and explicit selection per match. Preserve Convex lobby/session/durable projection surfaces during migration; never run competing combat writers for one match. New combat sessions use the separately versioned combat protocol, never mixed legacy `shots:fire` and cloud outcomes.

The integration-owned packages/combat-protocol defines versioned input/events, 2–4 member rosters, frame/authority epochs, absolute bounded match clock, explicit phone pose and observed body colliders. Runtime authenticates every player capability. Server receives fire intent, never desired damage. Initial pulse projectiles have zero acceleration, 8 m/s speed and swept collision; the hit-only skeleton is presentation of terminal authority events. The sidearm remains hitscan for compatibility/benchmarking.

Freeze shield tuning at 0.4 m front-facing disc, 2 s active, 8 s cooldown, 100 energy; no shooting while active. Freeze projectile slow-field trial at 2 m radius, 2 s duration, 10 s cooldown, 0.25 scale. Overlap chooses the smallest scale. Both consume normal match time; people/camera are never slowed. All tuning requires physical playtesting before promotion.

Write boundaries: integration owns protocol/root config/Convex capability bridge/native client/composition/docs/Xcode. Simulation owns packages/combat-simulation/**. Cloud runtime owns services/combat-worker/**. Targeting owns native Targeting/** and its new tests. No overlap or archive code reuse. New lanes branch from the published combat-quality commit a059bbd (PR #55); release-fix #53 precedes it.

Execution and evidence live in docs/roadmap.md and docs/build-log.md. Cloud deployment follows reviewed green-main gates. Calibrated gameplay remains unavailable until the same frame/clock is ready; compile/test results do not prove outdoor anatomical collision or latency.
