Implement KIL-34 (simulation core v0) for Jorybraun/victoria-kill-zone on a feature branch cut from main at 34ab5ca00b3898c9f9b1801d513639c2071df68f.

Read first: AGENTS.md, docs/roadmap.md section L1, docs/decisions/0003-multiplayer-first-refounding.md, the "# match.v2" section of docs/interface-contracts.md, docs/features/shared-spatial-hit-registration/requirements.md, and docs/research/backend-evidence/rbo-research-netcode.md.

One bounded outcome: a pure, deterministic Swift Package at shared/simulation/ (integration-assigned path) named PewPewSimulation.

Scope:
- Fixed-tick simulation state: player sets (2-4, match.v2 vocabulary), match clock, per-player pose-history ring buffers.
- Bounded-rewind hitscan verdicts: 250 ms rewind cap, 100 ms max pose age, 0.35 m sphere proxies, 3 m minimum separation, 15 m maximum range (frozen baselines in the requirements doc). Verdict vocabulary: hit, miss, rejected with the requirement doc's rejection reasons.
- Projectile worldline scaffolding: spawn parameters -> position as a pure function of time. No travel gameplay yet.
- N-player rules only: verdicts validate "a targetable player" per match.v2; nothing may assume two players.

Constraints:
- Zero platform imports: Foundation-only Swift, no ARKit, no network, no Convex, no UIKit. Must compile for iOS and macOS targets.
- Deterministic: identical input sequences produce identical outputs; no wall-clock reads, no unseeded randomness, no floating-point reduction across unordered collections.
- Allowed paths: shared/simulation/** only. Do not edit ios/**, convex/**, spectator/**, scripts/**, docs/**, or root configuration; CI wiring is integration-owned and handled separately.
- Never push to main. Do not touch signing, secrets, or deployment settings.

Acceptance (all must pass and be shown in the PR):
- swift test --package-path shared/simulation passes.
- Property-style determinism tests: replaying a recorded input log yields byte-identical verdict sequences (at least 3 scenarios).
- Hand-computed rewind fixtures: at least 4 cases where the expected verdict (including rejection reason) is computed in comments/docs and asserted, covering rewind-window acceptance, pose-too-old rejection, out-of-range rejection, and minimum-separation rejection.
- 4-player scenario tests: simultaneous fire by two shooters at distinct targets, fire at a dead target rejected, stale-pose target rejected, and a full kill accounting sequence.
- swift build succeeds for both an iOS and a macOS destination (document exact commands used).

Return: commit SHA, draft PR URL against Jorybraun/victoria-kill-zone main, full test output, and any remaining blocker. State explicitly that no file outside shared/simulation/** changed.
