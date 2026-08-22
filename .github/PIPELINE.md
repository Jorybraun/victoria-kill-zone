# Continuous shipping pipeline

GitHub and Devin have deliberately separate responsibilities:

- Devin Cloud or a Mac Outpost creates an isolated branch and pull request.
- GitHub Actions validates every pull request and push.
- A successful `CI` run on trusted `main` may deploy Convex and the public spectator site.
- GitHub Actions does not call the Devin API, start sessions, or store Devin credentials.

## Required repository settings

Protect `main` and require pull requests, Code Owner review, and these checks:

- `Fast gate`
- `iOS gate`

The iOS gate reports success without consuming dependency-install/build time until it finds `ios/Package.swift`, an `.xcodeproj`, or an `.xcworkspace`. Once one exists, `pnpm verify:ios` is mandatory and build or test failures block merging.

Review `.github/CODEOWNERS` after publishing the canonical repository. Its initial owner is `@Jorybraun`, inferred from the configured GitHub CLI account; replace it if the repository is owned elsewhere.

## Opting into production deployment

GitHub Pages is publicly reachable. Leave deployment disabled until public hosting is intentional and the spectator app contains no private data or secrets.

1. In **Settings → Pages**, select **GitHub Actions** as the source.
2. Create the `github-pages` environment and restrict it to `main`. Add reviewers if production needs an approval gate.
3. Add the Actions secret `CONVEX_DEPLOY_KEY`, using a production deploy key scoped to this Convex deployment.
4. Add the Actions variable `VKZ_DEPLOY_ENABLED` with value `true`.

After `CI` succeeds on trusted `main`, `Deploy` confirms that the green revision is still the tip of `main`, checks out that exact commit, and re-runs both validation gates. It then uses Convex's production deploy command to build the spectator with `VITE_CONVEX_URL`, uploads `spectator/dist`, and deploys that artifact through the protected `github-pages` environment.

The workflow can also be started manually from `main`; it still requires the opt-in variable and re-runs both gates. Set `VKZ_DEPLOY_ENABLED` to `false` or remove it to disable all deployment jobs.

## Secrets and permissions

Only the release-build step receives `CONVEX_DEPLOY_KEY`. Pull-request workflows never receive or reference production credentials. Workflow-level access is read-only; only the Pages build/deploy jobs receive `pages: write` and `id-token: write`.
