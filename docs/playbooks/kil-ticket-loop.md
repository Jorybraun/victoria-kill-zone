# Playbook: work one KIL ticket on the Mac Outpost

Status: Draft for review — 2026-08-24
Owner: Integration
Audience: a Devin session executing exactly one Linear ticket. Paste this playbook (or reference this file) in the session prompt together with the ticket ID. One ticket per session; one session per write boundary at a time.

## Session preconditions (operator sets these up once)

- Session runs on the **`pew-pew-macos` Mac Outpost** (Namespace devbox blueprint), selected under Configuration → Virtual environment when creating the session.
- Repository: canonical GitHub remote, branch from green `main`.
- The Outpost machine provides: Xcode (version pinned in `docs/build-log.md`), iOS Simulators, Node 22 + pnpm 10, `gh` authenticated with least privilege, Convex dev deployment credentials via the secret mechanism (never echoed).
- Read before any edit: `AGENTS.md`, `docs/testing-strategy.md`, the Linear ticket, and any contract/ADR the ticket names.

## The loop

### 0. Claim and scope
1. Read the ticket (Linear). Restate in the session: outcome, exclusive write boundary, tier map row from `docs/testing-strategy.md`.
2. Move the ticket to In Progress. If the write boundary collides with another in-flight ticket, STOP and report a blocker instead of editing.

### 1. Environment proof (fail fast)
```sh
bash scripts/outpost/preflight.sh      # worker/repo hygiene
pnpm install --frozen-lockfile
pnpm verify                            # must be green BEFORE changes
xcodebuild -version                    # record in the session log
```
If any step fails, stop and report; do not "fix the environment" opportunistically.

### 2. Write the failing test first
- Add the ticket's Tier 0 scenario fixtures / unit tests (and Tier 1 suite if the ticket's tier map requires it) so they FAIL for the right reason. A ticket with no failing test first must justify why in the PR.

### 3. Implement inside the write boundary
- Small commits; follow existing conventions; no opportunistic edits or reformatting outside the declared paths.

### 4. Verify by tier (from docs/testing-strategy.md)
```sh
pnpm verify                            # Tier 0 (scenario suite included)
pnpm verify:ios                        # unsigned simulator build + Swift tests
# Tier 1 as required by the ticket, e.g.:
#   two-simulator convergence match script
#   transport loopback fault-injection suite
#   voice corpus regression
```
- Record suite names + results. Label any simulator-measured latency numbers `SIMULATOR`.

### 5. Evidence
- Append the ticket's evidence to the PR description; physical-device items are either attached (Tier 2 artifacts from a human-run TestFlight build) or explicitly deferred with owner + date. Never present simulator output as device evidence.

### 6. Deliver
```sh
git checkout -b <ticket-branch>        # e.g. kil-34-simulation-core-v0
# commit, then:
gh pr create --draft ...               # PR body: outcome, write set, tier evidence, deferred items
```
- Update the Linear ticket: link PR, check completed acceptance boxes, note deferrals.
- If the ticket changes observable behavior, add a `docs/build-log.md` entry (integration format).

### 7. Stop conditions (report a blocker, do not improvise)
- Write-boundary collision; contract not frozen; secret required but absent; signing/device gate needed but unavailable; `main` red; flaky required check; anything requiring physical phones when none are attached.

## Ticket order (dependency-respecting)

Work strictly one at a time unless boundaries are disjoint:

1. **KIL-31** ADR 0003 acceptance (human decision — session only prepares the PR)
2. **KIL-36** game-loop autopsy (parallel-safe: `ios/**` + build-log)
3. **KIL-33** match.v2 contracts → 4. **KIL-34** simulation core → 5. **KIL-35** transport v0
6. **KIL-19/20/21** spatial proofs (device-heavy; harness prep on Outpost, evidence with human)
7. **KIL-32** ADR 0004 (after KIL-21 numbers) · **KIL-38** TestFlight lane (any time, Integration) · **KIL-37** voice spike (any time, `ios/**/Services`) · **KIL-39/40** design docs (human-led)

## Prompt template for dispatching a session

```
Work Linear ticket KIL-<N> in Jorybraun/victoria-kill-zone.
Environment: pew-pew-macos Mac Outpost. Branch from green main.
Follow docs/playbooks/kil-ticket-loop.md exactly: claim → env proof →
failing test first → implement inside the ticket's write boundary →
tier verification per docs/testing-strategy.md → evidence → draft PR →
update the ticket. Stop and report blockers instead of improvising.
```
