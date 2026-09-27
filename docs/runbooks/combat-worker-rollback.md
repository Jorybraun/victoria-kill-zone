# Combat Worker rollback

Roll back **only** the `vkz-combat` Cloudflare Worker to an earlier deployed version. Convex, the spectator, and the iOS build are not part of this procedure. Use it when a deployed Worker version misbehaves but its Durable Object schema is compatible with the version being restored.

A rollback is **not** a re-run of `combat-deploy.mjs --deploy` from an older checkout: the script's `verifyRelease` guard requires the candidate SHA to equal the *current* `main` SHA (`fetchCurrentMainSha`), so it refuses an older revision outright. The rollback procedure below restores a previously deployed **version** with `wrangler versions deploy`, then produces fresh verification evidence with `combat-deploy.mjs --verify`. A scripted `--rollback <versionId>` mode that binds the guard rails to a version restore is a follow-up and needs Jory's sign-off — do not hand-roll it ad hoc.

## Preconditions

The operator checks these manually — **the tooling does not refuse a cross-migration rollback**, so this list is the only guard:

- The target version is identifiable: `wrangler versions list` inside `services/combat-worker/`, or the previous guarded deploy's evidence file — `worker.versionId` and `deployment.migrationTags` (recorded per deploy, plus `deployment.servingVersionId` for the version confirmed serving).
- The target version was itself deployed by a guarded `--deploy`, so a prior evidence file already exists proving it passed the admission probe for its own SHA.
- The target version's `release-manifest.json` (at its own SHA) has the **same** `doMigrationTag` and `doClass` as the currently deployed Worker's `/health.manifest.doMigrationTag`. Read the live tag with a bounded `/health` request or `node scripts/release/check-worker-health.mjs` (it reports `doMigrationTag` on success and fails with `mismatch:doMigrationTag,…` on drift; it also fails on `projection` if `/health.projection.configured` is not `true`).
- **Do not roll back across a Durable Object class-lifecycle change** — a new, renamed, or deleted class, a new migration tag, or a sqlite↔kv change. Room state created under the new migration is not readable by the old Worker. Roll **forward** instead with a plain guarded `--deploy` of a fixed SHA (which is `main`-fresh and therefore passes `verifyRelease`). Nothing in the tooling detects this mistake — the check is on the operator.
- The operator acknowledges active-match disruption **manually**: `wrangler versions deploy` bypasses the script, so `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED` has no effect here. The acknowledgement is recorded as a note in `docs/build-log.md` instead. Semantics: restoring a version resets live Durable Object rooms only when the DO actually restarts — on restart an existing room restores its checkpoint with `authorityEpoch + 1` and the **same** `frameEpoch` (not a fresh pair), and closes hibernated sockets with code `1012` (`"authority-restarted"`) so clients reconnect and re-admit; only a brand-new room starts at `(1, 1)`. In-flight matches are disrupted either way.

## Procedure

1. Confirm the preconditions above. Pick the target `versionId` (UUID) from `wrangler versions list` or prior evidence.

2. Restore traffic to it:

   ```sh
   cd services/combat-worker
   pnpm exec wrangler versions deploy --version-id <version-uuid> --yes
   ```

   This is the same primitive the scripted `versions` strategy uses, but invoked directly it produces **no** guarded evidence: no canonical-checkout check, no CI/Deploy verification for that SHA, no identity re-validation, no admission probe, no sanitized receipt record. Step 3 exists to close that evidence gap immediately.

3. Immediately re-run the admission probe to produce fresh acceptance evidence for the version now serving:

   ```sh
   VKZ_COMBAT_WORKER_URL=... VKZ_CONVEX_URL=... \
     node scripts/release/combat-deploy.mjs --verify
   ```

4. Record the rollback in `docs/build-log.md` — the restored `versionId`, the reason, the manual disruption acknowledgement — and update the repository variable `VKZ_COMBAT_WORKER_VERIFIED_SHA` to the SHA the Worker now runs (or unset it) so the TestFlight promotion gate keeps failing closed (`combatNotVerifiedForSha`) for any revision lacking verified admission evidence.

## Convex and iOS are not rolled back

The release manifest pins a compatibility envelope rather than an exact pair: `convexMinProtocol` bounds what Convex must accept, `iosMinProtocol`/`iosMaxProtocol` bound the app. Protocol additions are additive-optional — Convex's `publishProjection` already accepts projections with or without the optional `worker` key, and iOS decodes snapshots with or without `release` — so an older Worker remains compatible whenever the ranges overlap. After rollback, run `node scripts/release/check-worker-health.mjs` with `VKZ_COMBAT_WORKER_URL` set: it compares the live `/health` manifest against the checkout's `release-manifest.json` and exits non-zero naming each drift (`service`, `projection`, `manifest`, `protocolVersion`, `convexMinProtocol`, `iosProtocolRange`, `doMigrationTag`, `rulesSchemaHash`). A TestFlight build already promoted keeps working against the old Worker only while the app's `iosMin/MaxProtocol` range still covers the Worker's protocol version — the runbook cannot promise that across a protocol bump; verify before relying on it.

## Re-run the admission probe

```sh
VKZ_COMBAT_WORKER_URL=... VKZ_CONVEX_URL=... \
  node scripts/release/combat-deploy.mjs --verify
```

`--verify` needs no Worker secrets and rejects secret arguments. `VKZ_COMBAT_EVIDENCE_PATH` is optional; when set, a mode-0600 evidence file is written. A green run returns acceptance `{ ticketKeyParity: "passed", authenticatedWebSocket: "passed", projectionReceipt: "passed", physicalCalibration: "not-tested" }` plus a `probe` record (match created, snapshot protocol version, worker identity, durations) — confirm `probe.worker.versionId` equals the version restored in step 2; on a `--deploy` run the script itself enforces that binding (`deployed-version-not-serving`). Interpreting failures: `ticketKeyParity: "failed"` means the WebSocket handshake was rejected (`websocket-rejected-<status>`) — the Convex and Worker `COMBAT_TICKET_SECRET` values differ (the known F1 key-parity failure); a failed `combat:ticket` mutation is recorded as a classified probe error, **not** key parity; `projectionReceipt: "failed"` means the snapshot was admitted but the projection never landed in Convex — check the projection secret and `CONVEX_URL` binding on that Worker version; `endpointMismatch` means the ticket endpoint's origin is not the configured `VKZ_COMBAT_WORKER_URL`. Evidence stores only classified error codes (`convex-http-<status>`, `websocket-rejected-<status>`, `timeout`, `probe-session-invalid`, `endpointMismatch`, `snapshot-invalid`, `network`, `unknown`) — never raw error text.

## Evidence

`--verify` writes the admission-probe evidence file (`acceptance`, `probe` with worker identity). Because `wrangler versions deploy` writes no deploy receipt, the evidence trail for the rollback is the probe evidence plus the `combat-worker-rollback` note in `docs/build-log.md` naming the restored version, the prior deploy evidence that originally admitted it, and the reason. Update/unset `VKZ_COMBAT_WORKER_VERIFIED_SHA` as described in step 4.

## Not covered

No automated check covers physical calibration: `physicalCalibration` stays `not-tested` in every evidence file. Two-phone Align Arena, camera targeting, latency, and on-device authority behavior require a fresh device gate on the restored version and are outside this runbook.
