# Victoria Kill Zone

Victoria Kill Zone is a markerless 1v1 AR laser-tag prototype for two physical iPhones. Apple Vision identifies body regions, ARKit supplies the shot direction, Convex owns match state, and a browser spectator shows the same duel in realtime.

Phase 0 is intentionally narrow: native Swift/SwiftUI, ARKit + Vision, hitscan combat, anonymous match-scoped identity, Convex authority, and a React/Vite spectator. The goal is a repeatable two-phone demonstration, not a production anti-cheat system or general multiplayer platform.

## Source of truth

- [Technical specification](victoria-kill-zone-technical-spec.md) — product, architecture, interfaces, acceptance tests, and degradation order.
- [Build orchestration prompt](victoria-kill-zone-build-prompt.md) — implementation sequence and bounded workstreams.
- [Phase 0 stack decision](docs/decisions/0001-phase-zero-stack.md) — why the current stack supersedes archived prototypes.
- [Delivery pipeline](docs/delivery-pipeline.md) — parallel design/build, PR gates, deployment, and Mac Outpost promotion.
- [Build log](docs/build-log.md) — current evidence, blockers, and next integration step.

The `archive /` directory contains earlier experiments and planning material. It is preserved for reference only and is not active application source.

## Repository shape

```text
ios/          Native iOS app
convex/       Authoritative game backend
spectator/    Read-only realtime browser dashboard
design/       Slice-level states, tokens, copy, and acceptance evidence
docs/         Decisions, contracts, runbook, and delivery evidence
archive /     Preserved reference-only experiments
```

## Working agreement

Design stays one accepted slice ahead while backend, spectator, and iOS targeting work in exclusive paths. Every change moves through a short-lived draft PR, the automated repository gate, a green-main deployment, and—when device behavior is affected—a Mac Outpost promotion against the exact merged commit.

Read [AGENTS.md](AGENTS.md) before editing. The canonical local and CI gate is:

```sh
pnpm verify
```

Repository and production setup are documented in [.github/PIPELINE.md](.github/PIPELINE.md). Mac worker security, startup, diagnostics, canary, and handoff are documented in [docs/outpost-operations.md](docs/outpost-operations.md); the common read-only entry points are `pnpm outpost:preflight`, `pnpm outpost:diagnose`, `pnpm outpost:canary`, and `pnpm handoff:preflight`.

Do not push directly to `main`, commit credentials, or report device-dependent behavior complete from simulator evidence.

## First shippable milestone

The first vertical slice is create → join → start → debug fire → synchronized health on Phone A, Phone B, and the spectator. Before feature work, the hardware gate must prove a signed shell, camera/location permissions, Convex mutation/subscription, spectator subscription, and a mirroring route on two physical iPhones.
