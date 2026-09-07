# Arena spectator browser evidence

Eight captures use the actual React application and deterministic, visibly labeled demo snapshots. Chromium version, viewport widths, text scales, headings, roster names and overflow checks are recorded in `manifest.json`. These are local browser layout evidence, not a production service connection, authority freshness measurement, screen-reader trial or physical iPhone result.

- `arena-desktop.png`: all four members, health and scores at 1280px.
- `arena-phone.png`: four members at 375px, including a long display name.
- `aligning-phone.png`, `paused-phone.png`: truthful non-live combat phases.
- `results-desktop.png`: authoritative third-player winner; no countdown promising a respawn after finish.
- `interrupted-phone.png`, `restored-phone.png`: retained roster and bounded connection recovery announcement.
- `arena-phone-text-200.png`: 375px viewport with 200% root text size. No page/card/life-label/event-panel/status-panel horizontal overflow.

Browser review found and corrected the original rem-based page minimum width, nonwrapping event heading, enlarged life-state label, and cramped desktop connection label. Independent accessibility review also removed dashboard-wide stale opacity so retained text keeps its normal contrast. The final screenshots reflect those fixes.

Reproduce from the repository root, with a local Playwright installation (or pass its absolute module path as the script's first argument):

```sh
VITE_CONVEX_URL='' pnpm --filter @vkz/spectator dev --host 127.0.0.1 --port 4179
node spectator/scripts/render-review.mjs
```

The script accepts `VKZ_CHROME_PATH` for an existing Chrome binary. It uses a fresh headless browser; it does not control a signed-in browser profile. Fixture selection never overrides a configured production Convex endpoint; the script requires the DEMO FIXTURE label before capturing.

Automated verification: spectator tests (49), lint, TypeScript and production build. This includes reconnect countdown, terminal accessible label and actual App-under-StrictMode socket-ownership regressions. Root integration also verifies the backend expiry behavior (125 backend tests) and canonical `pnpm verify`; review/merge remains a separate gate.

Remaining acceptance: real Convex socket disconnect/reconnect exercise, keyboard and screen-reader trial in supported browsers, and any later projection-freshness or projectile-ledger contract. A connected socket alone does not prove fresh authority state.
