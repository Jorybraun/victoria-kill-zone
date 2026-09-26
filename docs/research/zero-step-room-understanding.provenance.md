# Provenance: zero-step-room-understanding.md

- Date: 2026-09-26 (UTC)
- Tracker: BIO-36
- Repository state read: `main` at `0750e9b` (ADR 0013 accepted). Working tree
  untouched; no branch, commit, push, PR or deploy was made.
- Author: Devin session ae55c10da1304a5faea7af99ad855573 (read-only research).

## Rounds

1. **Repository audit** — protocol types/limits/validators, simulation
   (`index`, `history`, `flight`, `state`), DO worker (`room`, `connection`,
   `maps`, `store`, `bullet-ledger`, `cadence`), Convex `combat.ts`, iOS
   targeting/fire/association/replay, deploy workflow and guarded operator
   script. Each of the five supplied "facts to verify" was checked against
   code (brief §2). One was only partly true: plane detection is enabled but
   plane anchors are never consumed.
2. **Primary documentation** — Apple ARKit/Vision and Cloudflare Durable
   Objects pages fetched on 2026-09-26 (list below).
3. **Design derivation** — candidate messages, ordering, freshness, bounds,
   replay/epoch behaviour and degradation ladder derived from rounds 1–2.
4. **Self-review** — checked that every numeric bound in §5–§9 is tagged
   inference, that source numbers in the text match §12, and that no
   device-behaviour claim appears untagged.

## Sources consulted

Accepted (cited): brief §12 items 1–12, all primary Apple or Cloudflare pages.

Accepted with caveat: item 8 (`ARFrame.WorldMappingStatus`) — the fetched
page body contained only the type declaration; the brief uses the enum only by
name and does not assert its cases.

Fetched but not cited: `ARCamera.TrackingState.Reason` (page returned no body
text; the `reason` enum in §5.2 is therefore an inference from the
`TrackingState` page's "possible causes" wording and is not source-backed),
`VNDetectHumanBodyPoseRequest` (redundant with item 9), Cloudflare storage API
overview (redundant with item 10 for the claims made).

Rejected: none. No practitioner blogs, forum posts or third-party benchmarks
were consulted; the brief states this.

Prior repo research relied on for context, not re-verified: 
`docs/research/shared-arena-frame-options.md` (its statement that collaborative
mapping/ARWorldMap are unvalidated for this game's outdoor conditions is
carried forward unchanged).

## Verification performed

- Every `[repo]` claim was read directly from the files listed in brief §12 at
  `0750e9b`; line references given where they aid lookup.
- `rg` searches for `ARPlaneAnchor`, `ARMeshAnchor`, `raycast`,
  `sceneReconstruction` across `ios/` returned only configuration lines and
  no consumers — the basis for the "enabled but unused" finding.
- `.github/workflows/deploy.yml` searched for `combat`/`wrangler`: no matches.
- No tests, builds or `pnpm verify` were run; nothing needed compiling for a
  read-only audit and the task forbade code changes.

## Known limits

- No physical-device evidence of any kind. Plane counts, update rates,
  polygon sizes, raycast accuracy, alignment success and bandwidth are all
  unknown; brief §10 lists the experiments.
- All thresholds (residuals, ages, confidence decay, message caps) are
  proposals sized against existing repo limits, not measured values.
- Apple documentation fetches returned abbreviated page bodies for two items;
  claims were restricted to what the fetched text supports.
- Whether alignment should run on-phone (via the existing opaque `collab`
  relay) or in the DO is left open and tagged speculation.
- Three/four-player sighting identity (ADR 0013 deferral) is out of scope and
  unaffected by this brief.
