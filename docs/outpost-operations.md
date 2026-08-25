# Devin Mac Outpost operations

This runbook makes the Mac Outpost a controlled iOS build-and-verification lane. Cloud Devin sessions still deliver work through feature branches and GitHub pull requests. GitHub Actions validate those pull requests; they never create Devin sessions.

The scripts here do not stop or restart the current worker, rotate credentials, create cloud sessions, or accept credential arguments. They never print process arguments, token values, or Git remote URLs.

## Operating model

- Use regular Cloud Devin capacity for backend, web, documentation, and other platform-neutral work.
- Select the Mac Outpost for Xcode, Swift, simulator, signing, and connected-device work.
- One Outpost worker claims one session at a time. Additional sessions assigned to that worker queue. Do not start duplicate workers against this Mac or shared worker root; scale only with separately isolated Macs and worker roots.
- Every write task gets a bounded feature branch and a pull request. Protect `main` and require CI plus human review.
- Keep design one accepted slice ahead of implementation. Give each implementation task its states, contracts, acceptance command, and required evidence.

The worker clones repositories under `<worker-root>/repos/<repository>`. The worker root must therefore be a dedicated directory, never this project checkout or one of its parent directories.

## One-time security reset

The existing worker was started with a token in its process arguments. Treat that token as exposed before doing any new work:

1. In Devin Cloud, revoke or rotate that Outposts credential.
2. In the terminal that owns the old worker, press **Ctrl-C** and wait for it to exit. Do not start or stop it through these repository scripts.
3. Confirm the old worker is gone with Activity Monitor or `pgrep -f '[d]evin worker start'`. Do not run a command that prints its full arguments.
4. Use a dedicated, unprivileged macOS account when practical. Do not run the worker with `sudo`.
5. Prefer Devin's saved CLI login. Run `devin auth login` interactively and complete the browser login. The fallback is an Outposts token supplied through `DEVIN_OUTPOSTS_TOKEN` by the worker's launch environment—never `--token`, a task prompt, a repository file, or shell history.
6. Review previous worker checkouts and logs for accidental credential exposure before trusting or sharing them.

These human credential steps are intentionally not automated.

## Prepare the dedicated worker directory

Run these commands as the unprivileged worker user, choosing a location outside every project checkout:

```bash
export VKZ_OUTPOST_ROOT="$HOME/DevinOutposts/vkz-worker"
mkdir -p "$VKZ_OUTPOST_ROOT/repos"
chmod 700 "$VKZ_OUTPOST_ROOT" "$VKZ_OUTPOST_ROOT/repos"
export VKZ_OUTPOST_AUTH_MODE=saved
```

Optional operator settings are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `VKZ_OUTPOST_ROOT` | required | Absolute dedicated worker directory. |
| `VKZ_OUTPOST_AUTH_MODE` | `saved` | `saved` uses Devin's saved worker/CLI login; `env` only checks that `DEVIN_OUTPOSTS_TOKEN` is inherited. |
| `VKZ_OUTPOST_NAME` | unset | If set, passes the non-secret Outpost name/ID to `--outpost` so the worker only claims that queue. |
| `VKZ_OUTPOST_ONCE` | `0` | Set to `1` to exit after serving one session. |
| `VKZ_GIT_REMOTE` | `origin` | Canonical Git remote used by canary and handoff checks. |

Do not place exports containing credentials in a checked-in file. `DEVIN_OUTPOSTS_TOKEN` is never a supported script argument. The scripts fix `DEVELOPER_DIR` to `/Applications/Xcode.app/Contents/Developer` so a shell's Command Line Tools selection cannot silently choose the wrong toolchain.

## Preflight and start

From this repository checkout:

```bash
bash scripts/outpost/preflight.sh
bash scripts/outpost/start-worker.sh --dry-run
bash scripts/outpost/start-worker.sh
```

The wrapper runs the worker in the foreground from `VKZ_OUTPOST_ROOT`, without `sudo`. It refuses to start when another `devin worker start` process is detected. Leave that terminal open; press **Ctrl-C** there for a graceful stop.

For read-only local diagnostics:

```bash
bash scripts/outpost/diagnose.sh
```

Diagnostics show the worker count and working directory but deliberately hide process arguments. Repository remotes are reported only as configured or missing; their URLs are redacted.

## First read-only canary

Commit and push these scripts before assigning the canary so they exist in the Outpost checkout. Then:

1. Open **Devin Cloud** and create a new session/task.
2. Open **Configuration → Virtual environment** and explicitly select the intended Mac Outpost.
3. Select the canonical GitHub repository and the pushed branch containing these scripts.
4. Locally run `bash scripts/outpost/canary-prompt.sh` and paste its complete output as the task.
5. Submit only this session to the Outpost and watch the foreground worker claim it. Other Outpost sessions will remain queued.
6. Require the returned output to end with `PASS`, show the expected Xcode and Swift toolchains, redact the remote URL, and state that the checkout remained unchanged.
7. Confirm the canary created no branch, commit, pull request, deployment, or repository change.

The canary does not build, fetch, install, sign, access a phone, or call an external service. Those become separate, explicitly authorized tasks after it passes.

## Hand off a write task

For a Mac Outpost task, use Devin Cloud's session configuration and explicitly select the Outpost. Devin MCP may be used when its session-creation tool exposes an explicit Outpost or virtual-environment selector. Never infer Outpost routing from task text alone, and never trigger either flow from GitHub Actions.

Before handoff, fetch and prepare a clean pushed branch manually:

```bash
git fetch origin --prune
git status --short --branch
bash scripts/outpost/handoff-preflight.sh
```

The preflight requires:

- a credential-free `github.com` canonical remote (the URL is never printed);
- a named branch with an upstream on that remote;
- no staged, unstaged, or untracked files;
- no locally known ahead/behind commits; and
- a valid stored `gh` login. It rejects `GH_TOKEN` and `GITHUB_TOKEN` instead of reading API keys.

The interactive CLI handoff is useful for general Devin Cloud work:

```text
devin
/handoff <task>
```

The documented CLI handoff packages the local repository, branch, context, and uncommitted diff for a fresh Cloud VM. Do not assume that naming the Outpost in the prompt routes the session there. Use it for a Mac task only if the installed CLI presents an explicit, verified Outpost selector.

For an explicitly routed Mac Outpost session, the task must include allowed paths, forbidden actions, acceptance commands, required evidence, feature-branch requirement, and PR destination. A good task envelope is:

```text
This session is explicitly configured for the Mac Outpost. Implement <one bounded outcome> on a feature branch.
Allowed paths: <paths>. Do not edit anything else, signing identities, secrets, or deployment settings.
Acceptance: <exact commands and expected result>.
Return: commit SHA, GitHub PR URL, validation output, and any remaining blocker. Never push directly to main.
```

After handoff, let Devin/Outpost create its branch and pull request on GitHub. CI validates the PR; it does not dispatch Devin.

## TestFlight delivery lane (KIL-38)

The lane turns a merged commit into an over-the-air install on enrolled phones with no cable. It was first rehearsed on 2026-08-24.

Prerequisites, done once per operator machine:

- An App Store Connect API key with the **Admin** role. Cloud signing (automatic Distribution certificate and App Store profile management) fails with an App Manager key.
- The `.p8` key file at `~/.appstoreconnect/private_keys/AuthKey_<key id>.p8` with `700`/`600` permissions. The key file never enters the repository, chat, logs, or process arguments.
- The app record and an **Internal Testing** group with automatic distribution in App Store Connect; testers must be team members who accepted their invite.

Run from the repository root:

```bash
VKZ_ASC_KEY_ID=<key id> VKZ_ASC_ISSUER_ID=<issuer id> \
  bash scripts/release/testflight-upload.sh
```

The script archives the `VictoriaKillZone` scheme for `generic/platform=iOS`, exports with `method: app-store-connect` and `destination: upload`, lets App Store Connect manage the build number (`manageAppVersionAndBuildNumber`), and prints sanitized evidence (commit SHA, marketing version, scheme). The key id and issuer id are identifiers, not credentials; the private key is read only from the key directory.

Known gates the lane already clears:

- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `false` in the app Info.plist, so uploads do not stall on the encryption question.
- **App icon:** App Store Connect rejects icon-less packages (errors 90022/90713); the asset catalog satisfies this.

After upload, App Store Connect processes the build for a few minutes, then automatic distribution delivers it to the internal group; phones update through the TestFlight app. Record the observed install (device model and iOS version only, no identifiers) in [build-log.md](build-log.md).

## Permissions and connected devices

Grant only what the worker task requires:

- repository-scoped GitHub access with protected branches and pull-request review;
- Xcode and simulator access under the unprivileged worker account;
- Apple signing access only when a signed-device task explicitly needs it;
- USB/device trust only for named test phones; and
- no administrator privileges, production deployment secrets, or direct access to protected branches.

Use a non-signing simulator build before a signed physical-device task. Keep its DerivedData outside the repository checkout. A physical-device task should name the target scheme/device, forbid signing-setting changes unless specifically requested, and return the exact build/install evidence.

## Recovery

- **Duplicate worker detected:** return to the terminal running the existing worker and stop it with **Ctrl-C**. If its terminal is lost, use Activity Monitor to send **Quit** to that specific Devin worker process. Do not use broad `pkill` commands.
- **Worker running from the project checkout:** stop that specific worker, set `VKZ_OUTPOST_ROOT` to the dedicated directory, rerun `preflight.sh`, then start through the wrapper.
- **Authentication fails:** keep credentials out of command arguments. Run `devin auth login` interactively again or replace the launch environment's `DEVIN_OUTPOSTS_TOKEN`, then rerun preflight. Never paste the token into logs or tasks.
- **Session is queued:** this is expected while this worker is busy. Let the active session finish or cancel it deliberately in Devin Cloud. Add capacity only by provisioning another isolated Mac and worker root, never by duplicating the worker against this checkout.
- **Canary dirties the checkout:** stop and inspect the checkout manually. Do not auto-reset it; preserve evidence and use a fresh clone if necessary.
- **Xcode preflight fails:** open Xcode as the worker user, finish first-launch/license steps, verify `/Applications/Xcode.app`, and rerun preflight.
- **PR cannot be created:** keep the worker branch intact. Repair `gh`/GitHub repository permissions interactively, then retry the handoff or PR step; never fall back to pushing `main`.

Run `bash -n scripts/outpost/*.sh` after editing any operator script.
