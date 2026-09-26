# Combat Worker rollback

Roll back **only** the `vkz-combat` Cloudflare Worker to an earlier deployed version. Convex, the spectator, and the iOS build are not part of this procedure. Use it when a deployed Worker version misbehaves but its Durable Object schema is compatible with the version being restored.

A rollback is deliberately just a guarded deployment of an older SHA: `scripts/release/combat-deploy.mjs --deploy` run from a clean checkout of the SHA being rolled back **to**. Because that SHA's `wrangler.jsonc` migration tag matches the one currently deployed, the script selects its `versions` strategy (`wrangler versions upload` + `wrangler versions deploy --yes`), which restores the prior Worker version's traffic without a disruptive plain deploy.

## Preconditions

- The target version is identifiable: `wrangler versions list` inside `services/combat-worker/`, or the previous guarded deploy's evidence file — `worker.versionId` and `deployment.migrationTags` (recorded per deploy).
- The SHA being rolled back **to** has the same `doMigrationTag` and `doClass` in its `release-manifest.json` as the currently deployed Worker's `/health.manifest.doMigrationTag`. Read the live tag with a bounded `/health` request or `node scripts/release/check-worker-health.mjs` (it reports `doMigrationTag` on success and fails with `mismatch:doMigrationTag` on drift).
- **Refused**: rollback across a Durable Object class-lifecycle change — a new, renamed, or deleted class, a new migration tag, or a sqlite↔kv change. Room state created under the new migration is not readable by the old Worker. Roll **forward** instead with a plain guarded `--deploy` of a fixed SHA.
- Clean canonical checkout of the rollback target SHA with green CI and a successful Deploy run for that exact SHA — the same `verifyRelease` guard as any deploy. The script refuses otherwise (`release-not-verified`, `checkout-not-clean-candidate`).
- `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED=true` is present. Any Worker deploy resets live Durable Object rooms: in-flight matches lose their authority, and clients re-admit with fresh `authorityEpoch`/`frameEpoch` values (both restart at 1), which shows up as a new pair in each client's authority-epoch history. Without the variable the script exits before any write with `active-match-disruption-not-acknowledged`.

## Procedure

1. From the clean rollback-target checkout, run the normal guarded deploy:

   ```sh
   node scripts/release/combat-deploy.mjs --deploy --secrets-file /private/path/combat-secrets.json
   ```

   Supply the same environment inputs as a normal deployment (`VKZ_CANDIDATE_SHA`, `VKZ_GITHUB_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `VKZ_CONVEX_URL`, `VKZ_COMBAT_WORKER_URL`, `VKZ_CONVEX_CONFIGURATION_CONFIRMED`, `VKZ_COMBAT_EVIDENCE_PATH`, `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED`). The script compares the local migration tag with the deployed Worker's `/health.manifest.doMigrationTag` and records `deployment.deployStrategy: "versions"` in evidence when they match.

2. Emergency path only: `wrangler versions deploy --version-id <old-version-uuid>` inside `services/combat-worker/` restores traffic to a known version immediately. It produces **no** guarded evidence: no admission probe, no sanitized receipt record, no `acceptance` fields, and it skips every gate (checkout, CI/Deploy, identity, disruption acknowledgement). Prefer the scripted path whenever the gate can pass.

3. The script then re-checks `/health` and runs its admission probe automatically; a probe failure makes the run `verify-failed` and blocks evidence — the rollback may still have landed, so treat that as deploy-then-failed-verification, not as a clean abort.

## Convex and iOS are not rolled back

The release manifest pins a compatibility envelope rather than an exact pair: `convexMinProtocol` bounds what Convex must accept, `iosMinProtocol`/`iosMaxProtocol` bound the app. Protocol additions are additive-optional — Convex's `publishProjection` already accepts projections with or without the optional `worker` key, and iOS decodes snapshots with or without `release` — so an older Worker remains compatible whenever the ranges overlap. After rollback, run `node scripts/release/check-worker-health.mjs` with `VKZ_COMBAT_WORKER_URL` set: it compares the live `/health` manifest against the checkout's `release-manifest.json` and exits non-zero naming each drift (`protocolVersion`, `convexMinProtocol`, `iosProtocolRange`, `doMigrationTag`, `rulesSchemaHash`). A TestFlight build already promoted keeps working against the old Worker only while the app's `iosMin/MaxProtocol` range still covers the Worker's protocol version — the runbook cannot promise that across a protocol bump; verify before relying on it.

## Re-run the admission probe

```sh
VKZ_COMBAT_WORKER_URL=... VKZ_CONVEX_URL=... \
  node scripts/release/combat-deploy.mjs --verify
```

`--verify` needs no Worker secrets and rejects secret arguments. `VKZ_COMBAT_EVIDENCE_PATH` is optional; when set, a mode-0600 evidence file is written. A green run returns acceptance `{ ticketKeyParity: "passed", authenticatedWebSocket: "passed", projectionReceipt: "passed", physicalCalibration: "not-tested" }` plus a `probe` record (match created, snapshot protocol version, worker identity, durations). Interpreting failures: `ticketKeyParity: "failed"` means the ticket could not be minted or the WebSocket was rejected (`websocket-rejected-401`) — the Convex and Worker `COMBAT_TICKET_SECRET` values differ (the known F1 key-parity failure); `projectionReceipt: "failed"` means the snapshot was admitted but the projection never landed in Convex — check the projection secret and `CONVEX_URL` binding on that Worker version; `endpointMismatch` means the ticket endpoint's origin is not the configured `VKZ_COMBAT_WORKER_URL`.

## Evidence

The deploy writes the standard evidence file (`worker.versionId`, `deployment` block with `target`, `deployStrategy`, `migrationTags`, `acceptance`, `probe`). Record the rollback as an additional `combat-worker-rollback` note in `docs/build-log.md` naming the restored version and the reason. Finally, update the repository variable `VKZ_COMBAT_WORKER_VERIFIED_SHA` to the SHA the Worker now runs — or unset it — so the TestFlight promotion gate keeps failing closed (`combatNotVerifiedForSha`) for any revision lacking verified admission evidence.

## Not covered

No automated check covers physical calibration: `physicalCalibration` stays `not-tested` in every evidence file. Two-phone Align Arena, camera targeting, latency, and on-device authority behavior require a fresh device gate on the restored version and are outside this runbook.
