# Continuous delivery pipeline

## Outcome and invariants

Ship the smallest observable 1v1 slice continuously while design stays one accepted slice ahead of implementation.

The invariants are:

1. `main` is green and deployable.
2. One owner writes a path at a time.
3. Shared interfaces freeze before parallel implementation.
4. Every merge is tied to automated evidence; device claims require physical-device evidence.
5. Secrets never enter Git, logs, prompts, command-line arguments, screenshots, or PR text.

## Lanes and handoffs

| Lane | Owns | Delivers |
|---|---|---|
| Integration | root/shared contracts/Xcode project, merges, releases | frozen interface, integrated green commit, evidence record |
| Backend | `convex/**` | schema, authoritative mutations/queries, backend tests |
| Spectator | `spectator/**` | read-only realtime UI and browser tests |
| iOS targeting | `ios/**/Targeting/**` | ARKit/Vision targeting engine and deterministic tests |
| Design | `design/**` | next-slice states, tokens, copy, interactions, acceptance evidence |

An owner declares its exact write set in the draft PR. A needed edit outside that set becomes a handoff to the owning lane. Integration owns cross-lane DTO/enumeration changes and is the only lane that resolves contract conflicts.

Independent PRs are the default. Stack PRs only when the child cannot pass or be reviewed without the parent; each child names its parent, target branch, and merge order. A stack does not permit overlapping writes.

## One-slice-ahead design

Design freezes only the next slice, not the whole product. A slice packet in `design/**` is **Ready** when it names:

- entry, loading, empty, success, degraded, error, and recovery states that apply;
- tokens and reusable component choices;
- final user-facing copy;
- interaction and accessibility behavior;
- acceptance evidence, including the device/browser surface on which it will be observed;
- contract fields it consumes without redefining them.

Integration accepts the packet before implementation fans out. After acceptance, visual refinements can continue, but shared fields, behavior, or acceptance criteria change only through an explicit integration handoff.

## Per-change delivery loop

### 1. Slice contract gate

Evidence:

- one user-observable outcome and its acceptance scenario;
- exclusive path owner and declared write set;
- frozen shared interface or an explicit statement that no shared interface changes;
- relevant slice packet accepted;
- dependency and rollback identified.

Failure to name any item keeps the work in design; it does not enter implementation.

### 2. Draft PR gate

Agents branch from the latest green `main`, open a draft PR early, and keep it small enough to review as one outcome. The PR must identify the slice, write boundary, risk, verification commands, and evidence still missing.

No direct pushes to `main`, shared dirty workspaces, bundled unrelated cleanup, or secret-bearing fixtures are allowed.

### 3. Automated PR gate

The PR becomes reviewable only when all of the following are true:

- `pnpm verify` passes on the PR head SHA;
- affected target-specific tests pass;
- the ownership/write-set check has no collision;
- secret scanning and generated-file checks pass;
- shared-contract changes have integration approval;
- the PR includes observable acceptance evidence appropriate to the surface;
- all required branch-protection checks are green.

The reported evidence must include the PR head SHA and links or sanitized logs for each check. Rerun the gate after any code change. A simulator screenshot may support UI review but cannot satisfy a physical-device requirement.

### 4. Merge and green-main deploy gate

Merge only reviewed PRs whose required checks pass. The merge commit is the release identity.

On every merge, automation must:

1. run `pnpm verify` against the exact `main` SHA;
2. build all affected deployable targets;
3. deploy Convex and/or spectator artifacts for that same SHA to the configured demo environment;
4. run a smoke check proving the spectator loads and the deployed Convex endpoint answers a sanitized query when those targets changed;
5. record SHA, environment, artifact/deployment identifier, smoke result, and time without secrets.

If verification, build, deploy, or smoke fails, `main` is red: stop subsequent promotions, fix forward or revert the offending PR, and restore the last known-green deployment. Do not conceal a failed deployment with a manual unrecorded deploy.

### 5. Mac Outpost device-promotion gate

Use Cloud agents for parallel backend/spectator work and the Mac Outpost for Xcode, simulator, signing, and physical-device evidence. A promotion is dispatched only after the same SHA passes the green-main gate. Promotion tasks are read-only; any required source change returns through a new branch and draft PR.

For an iOS-affecting slice, the Outpost report must record:

- promoted Git SHA, Xcode version, build configuration, and sanitized build/test result;
- iPhone model and iOS version for each test device, without unique device identifiers;
- signed launch on both phones;
- camera and foreground precise-location permission result when relevant;
- one Convex mutation and live subscription from each phone when networking is relevant;
- observed acceptance scenario and consistent state on both phones and spectator;
- mirroring route for each phone when presentation behavior is relevant;
- failure logs sanitized of tokens, signing material, session secrets, and device IDs.

A feature is **device-promoted** only when every applicable item passes on the promoted SHA. A compile, simulator run, or unversioned local build is insufficient.

## Product evidence gates

These gates sequence the prototype; the per-change loop above applies inside each one.

| Gate | Exact exit evidence |
|---|---|
| G0 Hardware | Signed shell launches on two phones; camera/location permissions pass; each phone proves a Convex mutation and subscription; spectator proves a subscription; each phone has a tested mirror route. |
| G1 Contracts and shells | iOS, Convex, and spectator targets build; shared enums/DTOs/constants are frozen; exclusive owners are recorded. |
| G2 Network vertical slice | Host creates, guest joins, host starts, debug fire changes target health; duplicate shot ID is idempotent; health agrees on two phones and spectator. |
| G3 Markerless targeting | Debug region aligns to a real opponent at 3–8 m; torso aim solution repeats on a physical phone; no visible marker is used. |
| G4 Gameplay loop | Acquire/fire/damage/kill/respawn succeeds five consecutive times with authoritative ammo, health, and K/D. |
| G5 Arena | Outdoor boundary lock passes, or the explicitly labelled indoor demo override and limitation are recorded. |
| G6 Spectator/presentation | A third party can follow the match from two mirrored phone POVs plus spectator health, K/D, timer, radar, and events. |
| G7 Demo candidate | Ten three-shot sequences per phone complete without crash/duplicate damage/state divergence; Vision reacquires; thermal and mirroring checks pass; backup recording exists. |

Never remove the G2 debug-fire path until G3/G4 physical evidence proves its replacement.

## Stop-the-line blockers

Do not dispatch write work or promote a build while any applicable blocker remains:

- no canonical remote or agents cannot authenticate with least privilege;
- Outpost credential is exposed, stored in a command line, or not rotated after exposure;
- dirty/unversioned Outpost checkout or promoted SHA cannot be identified;
- unavailable Apple signing team, invalid signing identity, or fewer than two usable test phones for a two-phone gate;
- missing Convex/demo deployment secret or target environment;
- required interface is unfrozen or two tasks claim the same path;
- required check is absent, bypassed, flaky without disposition, or red;
- physical evidence is required but only simulator/browser evidence exists.

Record the blocker and owner in [build-log.md](build-log.md). Resume at the failed gate after evidence is available; do not silently weaken the gate.

## Continuous-shipping rhythm

- Prefer one vertical outcome per PR and merge as soon as its current gate passes.
- Keep incomplete behavior behind a non-production debug path or disabled entry point; never leave `main` broken between layers.
- Integration reviews diffs and evidence continuously rather than batching at the end of a phase.
- Append only observed evidence to the build log. “Implemented” and “compiled” are not substitutes for the named exit evidence.
