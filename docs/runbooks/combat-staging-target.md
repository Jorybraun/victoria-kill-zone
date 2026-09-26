# Combat Worker staging target

`scripts/release/combat-deploy.mjs --target staging` deploys or verifies the staging Worker `vkz-combat-staging` instead of the production `vkz-combat`. This document records what exists today and what remains an operator follow-up.

## What exists

- `services/combat-worker/wrangler.jsonc` declares `env.staging`: `name: "vkz-combat-staging"` with the Durable Object binding, `version_metadata`, migrations, `vars`, and `secrets.required` declared explicitly — Wrangler does not inherit DO bindings or migrations into a named environment.
- `combat-deploy.mjs` accepts `--target production|staging` (default `production`) on `--preflight`, `--deploy`, and `--verify`. Staging resolves `VKZ_CONVEX_STAGING_URL` and `VKZ_COMBAT_STAGING_WORKER_URL`, requiring the worker origin to match `https://vkz-combat-staging.<account-subdomain>.workers.dev` (`unexpected-deployment-origin` otherwise). Wrangler is invoked with `--env staging`; `readLocalMigrationTag` reads the `env.staging.migrations` block, so the versions/deploy strategy decision uses the staging tag.
- Every guard is identical to production: exact-SHA clean checkout, green CI **and** Deploy for the SHA, OAuth identity re-check, stdin/0600 secrets, bounded receipts, `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED` for `--deploy`, the post-deploy admission probe, and sanitized evidence (`deployment.target: "staging"`). Staging relaxes nothing.
- `--verify --target staging` runs the same admission probe against the staging origins with no secrets.

## What is deliberately not provisioned

This slice adds the mechanism only. Still missing, by design, because each requires new secrets and operator decisions outside code:

- A **staging Convex deployment** (`VKZ_CONVEX_STAGING_URL`) configured with its own `COMBAT_TICKET_SECRET`, `COMBAT_PROJECTION_SECRET`, and `COMBAT_WORKER_URL=https://vkz-combat-staging.<account-subdomain>.workers.dev` origin. Using the production Convex deployment as the staging URL would mint tickets the staging Worker cannot verify — the same key-parity failure the admission probe exists to catch.
- The **staging Worker's own secret pair**. It must hold `COMBAT_TICKET_SECRET` and `COMBAT_PROJECTION_SECRET` values matching the staging Convex deployment, supplied via `--secrets-file`/`--secrets-stdin` on the first `--deploy` (the checked-in `secrets.required` contract applies per environment). Do not copy the production pair.
- **Repository variables** `VKZ_CONVEX_STAGING_URL` and `VKZ_COMBAT_STAGING_WORKER_URL`, set where operators keep deployment origins.

## Bring-up sequence

1. Create the staging Convex deployment and install its two combat secrets plus `COMBAT_WORKER_URL` (operator handoff, same confidentiality rules as production).
2. Set the two repository variables so the deploy script can resolve origins.
3. `node scripts/release/combat-deploy.mjs --preflight --target staging --secrets-file <staging-secrets>` to validate inputs and the dry-run bundle.
4. `VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED=true node scripts/release/combat-deploy.mjs --deploy --target staging --secrets-file <staging-secrets>`; expect `deployStrategy: "deploy"` on first deploy (no prior `/health` answers, so the deployed tag is unknown).
5. `node scripts/release/combat-deploy.mjs --verify --target staging` on subsequent checks; `VKZ_COMBAT_WORKER_VERIFIED_SHA` and the TestFlight gate remain production-only — staging evidence does not promote anything.
