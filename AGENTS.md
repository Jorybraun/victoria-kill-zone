# Victoria Kill Zone agent contract

This file applies to the entire repository. Read it before editing.

## Product authority

- The current product is the native iOS, markerless multiplayer game (Phase 1 cap: 4 players) defined by [victoria-kill-zone-technical-spec.md](victoria-kill-zone-technical-spec.md), orchestrated by [victoria-kill-zone-build-prompt.md](victoria-kill-zone-build-prompt.md), and re-founded per [docs/decisions/0003-multiplayer-first-refounding.md](docs/decisions/0003-multiplayer-first-refounding.md) and [docs/roadmap.md](docs/roadmap.md). If they conflict, the technical spec wins unless a newer accepted decision record says otherwise; ADR 0003 supersedes the spec's 1v1-only scope.
- The committed Phase 0 stack is Swift/SwiftUI + ARKit + Vision + Core Location on iOS, Convex as authoritative game state, and React + TypeScript + Vite for the read-only spectator. See [docs/decisions/0001-phase-zero-stack.md](docs/decisions/0001-phase-zero-stack.md).
- Everything under `archive /` is preserved, reference-only history. Do not build on, modernize, move, delete, or copy archived Unity, custom-server, or LAN code into the active product without an accepted decision record.
- Do not add Unity, Unreal, React Native, Expo, Firebase, Supabase, visible target markers, WebRTC, or persistent accounts. Per ADR 0003, multiplayer targeting is allowed up to the Phase 1 cap of 4 players; more than 4 players requires a new accepted decision record.

## Write ownership

Only one active owner may write a path at a time.

| Workstream | Exclusive write boundary |
|---|---|
| Integration | repository-root configuration, shared contracts/models, Xcode project/workspace files, integration docs, merge and release wiring |
| Backend | `convex/**` and backend tests |
| Spectator | `spectator/**` and spectator tests |
| iOS targeting | `ios/**/Targeting/**` and targeting-specific tests |
| Design | `design/**` |

- Declare the intended write set in the task or draft PR before editing. Do not make opportunistic edits outside it.
- Root configuration, `docs/interface-contracts.md`, shared DTOs/enums, and Xcode project files require integration ownership even when another workstream needs the change.
- If work crosses a boundary, stop at the documented interface and request a handoff. Never resolve overlap by having two agents edit the same file.
- Preserve user changes. Do not reformat, rename, or delete unrelated work.

## Delivery rules

- `main` must remain green. Never push directly to `main`; use a short-lived branch and draft PR.
- Use independent PRs by default. Use a stack only when a later change cannot be reviewed or verified without an earlier one; state the parent PR and merge order.
- Keep the debug-fire network path until markerless targeting replaces it with physical-device evidence.
- The canonical repository verification command is:

  ```sh
  pnpm verify
  ```

  Targeted checks may run while developing, but they do not replace `pnpm verify` before review or merge.
- A compile or simulator run is not physical-device evidence. Camera targeting, networking, haptics, geofence behavior, signing, and mirroring must name the device and observed result.
- Follow [docs/delivery-pipeline.md](docs/delivery-pipeline.md) for PR, deploy, and Mac Outpost promotion gates. Integration records passed evidence and blockers in [docs/build-log.md](docs/build-log.md).

## Design/build parallelism

- Design works exactly one accepted slice ahead. For that slice, freeze user states, tokens, copy, interaction behavior, and acceptance evidence in `design/**`.
- Do not wait for a whole-product, high-fidelity Figma file. Backend and camera work proceed against frozen written contracts.
- A post-freeze change that alters a shared contract or acceptance condition requires integration approval and an explicit handoff to affected owners.

## Security and automation

- Never commit or print secrets: Outpost credentials, Convex deployment keys, Apple signing material, session secrets, device identifiers, or private `.env` values.
- Never place a credential in a process command line, PR body, build log, screenshot, or test fixture. Use the CI/Outpost secret mechanism and sanitized evidence.
- Cloud agents and the Mac Outpost work from a canonical remote commit. Write-capable tasks use branches and PRs; promotion runs are read-only against the promoted SHA.
- Stop and report a blocker rather than bypassing branch protection, signing, required checks, secret controls, or physical-device gates.
