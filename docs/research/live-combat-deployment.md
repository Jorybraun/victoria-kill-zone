# Live combat deployment checkpoint

`combat:prepare` refuses Align Arena until the production Convex deployment has a valid `COMBAT_TICKET_SECRET` and `COMBAT_WORKER_URL`. Creating a lobby does not exercise that configuration. The Worker also needs the matching ticket key, an independent matching projection key, and the production Convex client origin. The existing Deploy workflow covers Convex and the spectator; it does not deploy this Worker.

This checkpoint supplies a guarded **Worker-only bootstrap**. It depends on PR #64's `scripts/release/deployment-gate.mjs`; merge that prerequisite first. Run the committed script from a clean checkout of the exact current main SHA after its canonical CI and Convex/spectator Deploy have completed successfully. It does not change Convex configuration, log in, create credentials, expand permissions, select a production authority, or establish physical acceptance.

## Configuration handoff

An authorized operator supplies two independent random secrets from the approved secret source. Each must contain 32–4096 UTF-8 bytes. Preserve existing keys when redeploying; this script never generates or rotates them. Install `COMBAT_TICKET_SECRET` and `COMBAT_PROJECTION_SECRET` on the **same production Convex deployment used by the app**, using secure dashboard input or an authorized CLI's stdin/file support. Set `COMBAT_WORKER_URL` to the intended `https://vkz-combat.<account-subdomain>.workers.dev` origin, without a path/query/fragment. Confirm those exact keys and origin were installed before declaring the handoff complete.

The current deployment key's missing `deployment:env:view` permission is a real blocker to using it for environment verification. Do not enlarge permissions automatically or infer configuration from a successful spectator smoke. An already authorized dashboard operator may complete the handoff instead. `convex env list --prod --names-only` is suitable for names-only inventory with sufficient authorization; ordinary `list` and `get` disclose values.

Supply the same two keys as a JSON object with exactly the properties `COMBAT_TICKET_SECRET` and `COMBAT_PROJECTION_SECRET`. Use a private regular file outside the repository, readable only by its owner, or pipe JSON directly from the approved secret manager. Never put key values in arguments, shell history, logs, examples, or screenshots. The script copies them to a temporary mode-0600 file in a private directory and removes that directory on completion. Abrupt process termination can leave temporary material requiring secure cleanup.

Provide these environment inputs through the approved local/CI secret mechanism:

| Name | Meaning |
| --- | --- |
| `VKZ_CANDIDATE_SHA` | Full lowercase 40-character current main commit |
| `VKZ_GITHUB_TOKEN` | Existing GitHub credential able to read main and Actions evidence |
| `CLOUDFLARE_ACCOUNT_ID` | Explicit authorized account; never emitted in evidence |
| `VKZ_CONVEX_URL` | Production `https://<deployment>.convex.cloud` client origin, not `.convex.site` |
| `VKZ_COMBAT_WORKER_URL` | Intended `https://vkz-combat.<account-subdomain>.workers.dev` origin |
| `VKZ_CONVEX_CONFIGURATION_CONFIRMED` | Set to `true` only after the above operator handoff; this is an attestation, not a live probe |
| `VKZ_COMBAT_EVIDENCE_PATH` | New absolute output filename outside the checkout; parent must already exist |
| `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED` | Set to `true` to run `--deploy`; a Worker deploy resets Durable Object rooms and disrupts in-flight matches. Not required for `--preflight` or `--verify` |
| `VKZ_CONVEX_STAGING_URL` / `VKZ_COMBAT_STAGING_WORKER_URL` | Replace the production URLs only when `--target staging` is given; the staging worker must be `vkz-combat-staging.<account-subdomain>.workers.dev` |

The bootstrap accepts the currently authorized Wrangler OAuth session, verifies selected account membership and a Workers write scope, and never starts login. API-token authentication is deliberately unsupported until its write permissions can be verified. Read access/account presence alone does not prove write permission. The checkpoint supports the checked-in `vkz-combat` configuration and its workers.dev origin; custom domains/environments require a separate reviewed extension.

## Preflight and deployment

The commands contain only paths, never key values:

```sh
node scripts/release/combat-deploy.mjs --preflight --secrets-file /private/path/combat-secrets.json
node scripts/release/combat-deploy.mjs --deploy --secrets-file /private/path/combat-secrets.json
node scripts/release/combat-deploy.mjs --verify
```

Append `--target staging` to run against the staging Worker (`vkz-combat-staging`) with the same guards. `--verify` takes no secrets: it needs only `VKZ_COMBAT_WORKER_URL` and `VKZ_CONVEX_URL` (or their staging equivalents), and runs the admission probe below without deploying. A Worker deploy resets live Durable Object rooms, so `--deploy` fails closed unless `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED=true` is present.

Use `--secrets-stdin` instead of `--secrets-file <path>` when piping from a secret manager. Inputs are bounded JSON; file input must not be a symlink and must have no group/other permissions. `--preflight` validates inputs, checks clean exact-SHA checkout, re-reads main/CI/deployment evidence, verifies Cloudflare identity, checks the evidence destination, and runs Wrangler's local dry-run. It performs no remote deployment. Local compilation is intentional; do not run it alongside the runtime benchmark.

`--deploy` repeats those checks, confirms Cloudflare identity again, and then revalidates checkout and release evidence immediately before its first deployment write. Before deploying it compares the local `wrangler.jsonc` Durable Object migration tag with the deployed Worker's `/health.manifest.doMigrationTag` (an unavailable or old-shape health response counts as unknown): equal tags take a versioned `wrangler versions upload` + `wrangler versions deploy --yes` rollout; a new or unknown tag keeps the plain `wrangler deploy` path. The final current-main lookup follows both the identity subprocess and CI/Deploy evidence lookups; advancement observed there stops deployment. This is a freshness check, not an atomic lock across GitHub and Cloudflare. It invokes the pinned Wrangler with `deploy --secrets-file` so both required secrets accompany the first Worker version atomically. It supplies `CONVEX_URL` explicitly on **every** deploy: the checked-in value is empty and must not replace production configuration. It does not print or forward raw Wrangler/GitHub output. Do not use an unguarded deployment command as a recovery shortcut.

After deployment, the script validates Wrangler's structured receipt against the expected Worker and version UUID (plus the target origin for plain deploys), then requests `/health` with a deadline and bounded response, then runs the same admission probe as `--verify`: it creates a match, joins a guest, mints a ticket, opens the ticketed WebSocket, checks the snapshot's release manifest protocol version, leaves, and polls `queries:matchSnapshot` until the projection receipt (`combatProjectionSequence` or `combatWorkerVersionTag`) lands. Any probe failure makes the run `verify-failed` and blocks evidence. It creates a new mode-0600 evidence file only after these checks succeed. Evidence contains commit, Worker version, prerequisite results, limited health facts, and untested acceptance items; it excludes origins, account identifiers and credentials. A deployment followed by a failed health/evidence check is **not rolled back automatically**. Inspect sanitized deployment status before retrying; never interpret failure as proof no remote write occurred.

## Remaining acceptance

`/health` returns 200 even when projection configuration is unusable. The script requires `projection.configured:true`, but that boolean only validates URL shape and projection-key length. It does not prove the two systems share keys, Convex reachability, ticket acceptance, Durable Object admission, or projection delivery. The operator handoff is explicitly recorded as unprobed.

After bootstrap, capture an authenticated native ticket → WebSocket admission → acknowledged Convex projection and the two-phone Align Arena result. Do not log tickets/session secrets or treat automated compilation as device evidence. Runtime load, physical calibration, latency, authority selection and other ADR 0008 acceptance remain separate. Root must add Worker deployment/readiness evidence to the canonical release workflow and promotion gate before calling this a complete repeatable app/backend release pipeline.

Focused verification: `node scripts/release/combat-deploy-self-test.mjs` uses ephemeral keys and injected local seams; it performs no cloud operations or compilation. Canonical `pnpm verify` remains required before review/merge.

## Diagnosing `Match access could not be verified` / HTTP 401 on admission

If `/health` returns `{"service":"vkz-combat",...}` but every WebSocket admission returns HTTP 401 for a freshly minted ticket, the Convex deployment and the Worker are signing/verifying with different `COMBAT_TICKET_SECRET` values (or the Worker value is shorter than 32 bytes). `/health` never exercises the ticket key. Fix: generate one new 32+ byte secret and install the same value in both places — `npx convex env set COMBAT_TICKET_SECRET <value> --prod` and `npx wrangler secret put COMBAT_TICKET_SECRET` (from `services/combat-worker/`) — then re-run the synthetic admission probe and expect 101. Never paste the value into chat, logs, or Git. Redeploying the Worker with `--secrets-file` or a fresh `wrangler secret put` rotates the Worker side only; Convex must be updated in the same operation.
