// Guarded Worker bootstrap. Convex configuration is a separate operator step.
import { execFile } from "node:child_process";
import { constants, readFileSync } from "node:fs";
import { access, lstat, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { fetchCurrentMainSha, hasSuccessfulCiPushRun } from "./github-api.mjs";

const execute = promisify(execFile);
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const REPOSITORY = "Jorybraun/victoria-kill-zone";
const KEYS = ["COMBAT_TICKET_SECRET", "COMBAT_PROJECTION_SECRET"];
const TARGETS = ["production", "staging"];
const RELEASE_MANIFEST = JSON.parse(readFileSync(join(ROOT, "release-manifest.json"), "utf8"));
class CombatDeployError extends Error {}
const fail = (code) => { throw new CombatDeployError(code); };
const VERSION_ID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;

export function httpsOrigin(value) {
  if (typeof value !== "string" || value.length > 256) fail("invalid-origin");
  let url;
  try { url = new URL(value); } catch { fail("invalid-origin"); }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") fail("invalid-origin");
  return url.origin;
}

// The verify probe needs only the two origins; the full deploy config adds the
// SHA, GitHub token, Cloudflare account, operator handoff, and evidence path.
export function probeConfig(env, target = "production") {
  if (!TARGETS.includes(target)) fail("invalid-arguments");
  const staging = target === "staging";
  const convexUrl = httpsOrigin(staging ? env.VKZ_CONVEX_STAGING_URL : env.VKZ_CONVEX_URL);
  const workerUrl = httpsOrigin(staging ? env.VKZ_COMBAT_STAGING_WORKER_URL : env.VKZ_COMBAT_WORKER_URL);
  const workerPattern = staging ? /^https:\/\/vkz-combat-staging\.[a-z0-9-]+\.workers\.dev$/
    : /^https:\/\/vkz-combat\.[a-z0-9-]+\.workers\.dev$/;
  if (!/^https:\/\/[a-z0-9-]+\.convex\.cloud$/.test(convexUrl) ||
      !workerPattern.test(workerUrl)) fail("unexpected-deployment-origin");
  let evidencePath = null;
  if (env.VKZ_COMBAT_EVIDENCE_PATH !== undefined) {
    if (!isAbsolute(env.VKZ_COMBAT_EVIDENCE_PATH)) fail("evidence-path-required");
    evidencePath = resolve(env.VKZ_COMBAT_EVIDENCE_PATH);
    if (!relative(ROOT, evidencePath).startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) fail("evidence-must-be-outside-checkout");
  }
  return { target, workerName: staging ? "vkz-combat-staging" : "vkz-combat",
    wranglerEnv: staging ? "staging" : undefined, convexUrl, workerUrl, evidencePath };
}

export function deploymentConfig(env, target = "production") {
  const probe = probeConfig(env, target);
  if (!/^[a-f0-9]{40}$/.test(env.VKZ_CANDIDATE_SHA ?? "")) fail("invalid-sha");
  if (!env.VKZ_GITHUB_TOKEN || !/^[a-f0-9]{32}$/.test(env.CLOUDFLARE_ACCOUNT_ID ?? "")) fail("missing-auth-input");
  if (env.VKZ_CONVEX_CONFIGURATION_CONFIRMED !== "true") fail("convex-operator-handoff-required");
  if (probe.evidencePath === null) fail("evidence-path-required");
  return { sha: env.VKZ_CANDIDATE_SHA, repository: REPOSITORY, token: env.VKZ_GITHUB_TOKEN,
    accountId: env.CLOUDFLARE_ACCOUNT_ID, ...probe };
}

export function parseSecrets(raw) {
  if (typeof raw !== "string" || Buffer.byteLength(raw) > 16384) fail("invalid-secret-input");
  let value;
  try { value = JSON.parse(raw); } catch { fail("invalid-secret-input"); }
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).length !== KEYS.length || KEYS.some(key => typeof value[key] !== "string" ||
        Buffer.byteLength(value[key]) < 32 || Buffer.byteLength(value[key]) > 4096) ||
      value[KEYS[0]] === value[KEYS[1]]) fail("invalid-secret-input");
  return Object.fromEntries(KEYS.map(key => [key, value[key]]));
}

export function validateIdentity(identity, accountId) {
  // This bounded bootstrap supports the existing OAuth session. API-token
  // permission discovery is deliberately not inferred from account access.
  if (identity?.loggedIn !== true || identity.authType !== "OAuth Token" ||
      !Array.isArray(identity.accounts) || !identity.accounts.some(account => account.id === accountId) ||
      !Array.isArray(identity.tokenPermissions) ||
      !identity.tokenPermissions.some(scope => ["workers:write", "workers_scripts:write"].includes(scope))) fail("cloudflare-auth-not-verified");
}

export function deploymentResult(raw, workerUrl, workerName = "vkz-combat", strategy = "deploy") {
  let entries;
  try { entries = raw.trim().split("\n").filter(Boolean).map(line => JSON.parse(line)); }
  catch { fail("deployment-receipt-invalid"); }
  if (strategy === "versions") {
    // wrangler-dist writeOutput record shapes: version-upload carries version_id;
    // version-deploy carries deployment_id plus a version_traffic map.
    const uploads = entries.filter(entry => entry.type === "version-upload");
    const deploys = entries.filter(entry => entry.type === "version-deploy");
    if (uploads.length !== 1 || deploys.length !== 1) fail("deployment-receipt-invalid");
    const upload = uploads[0], deployed = deploys[0];
    if (upload.version !== 1 || deployed.version !== 1 ||
        upload.worker_name !== workerName || deployed.worker_name !== workerName ||
        !VERSION_ID.test(upload.version_id ?? "") ||
        typeof deployed.deployment_id !== "string" || deployed.deployment_id.length === 0 ||
        typeof deployed.version_traffic !== "object" || deployed.version_traffic === null) fail("deployment-receipt-invalid");
    return { versionId: upload.version_id, deploymentId: deployed.deployment_id };
  }
  const records = entries.filter(entry => entry.type === "deploy");
  const result = records[0];
  if (records.length !== 1 || result.version !== 1 || result.worker_name !== workerName ||
      !VERSION_ID.test(result.version_id ?? "") ||
      !Array.isArray(result.targets) || !result.targets.some(target => target === workerUrl || target === `${workerUrl}/`)) fail("deployment-receipt-invalid");
  return { versionId: result.version_id };
}

// The last DO migration tag decides the deploy strategy: a matching tag means
// rooms are compatible, so a versioned rollout replaces a disruptive deploy.
export function readLocalMigrationTag(config) {
  const raw = readFileSync(join(ROOT, "services/combat-worker/wrangler.jsonc"), "utf8")
    .replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
  let parsed;
  try { parsed = JSON.parse(raw); } catch { fail("migration-tag-missing"); }
  const scope = config.wranglerEnv === undefined ? parsed : parsed.env?.[config.wranglerEnv];
  const migrations = scope?.migrations;
  if (!Array.isArray(migrations) || migrations.length === 0) fail("migration-tag-missing");
  const tag = migrations[migrations.length - 1].tag;
  if (typeof tag !== "string" || tag.length === 0 || tag.length > 128) fail("migration-tag-missing");
  return tag;
}

const boundedText = (value) => typeof value === "string" && value.length > 0 && value.length <= 128 ? value : null;

// Admission probe: mint a real match, join as a real client, read the first
// snapshot's release identity, leave, then confirm the projection receipt.
// deps = { convexMutation, convexQuery, openWebSocket, now, sleep }.
export async function runAdmissionProbe({ config }, deps) {
  const acceptance = { ticketKeyParity: "not-tested", authenticatedWebSocket: "not-tested",
    projectionReceipt: "not-tested", physicalCalibration: "not-tested" };
  const probe = { matchCreated: false, snapshotProtocolVersion: null, worker: null, durationsMs: {} };
  const errors = [];
  const sensitive = new Set();
  const sanitize = (error) => {
    let text = error instanceof Error ? error.message : String(error);
    for (const secret of sensitive) text = text.split(secret).join("[redacted]");
    return text.replace(/\s+/g, " ").slice(0, 160);
  };
  const mark = (label, start) => { probe.durationsMs[label] = Math.max(0, Math.round(deps.now() - start)); };
  const probeStart = deps.now();
  try {
    const lobbyStart = deps.now();
    const host = await deps.convexMutation("matches:create", {
      displayName: "vkz-probe-host", arenaRadiusMeters: 40,
      combatMode: "durableObject", combatGeometry: "sighting", maxPlayers: 2 });
    const guest = await deps.convexMutation("matches:join", { displayName: "vkz-probe-guest", code: host.code });
    for (const member of [host, guest]) {
      if (typeof member?.sessionSecret !== "string" || member.sessionSecret.length === 0) fail("probe-session-invalid");
      sensitive.add(member.sessionSecret);
    }
    probe.matchCreated = true;
    mark("lobby", lobbyStart);
    const sessionArgs = (member) => ({ matchId: member.matchId, playerId: member.playerId, sessionSecret: member.sessionSecret });
    const readyStart = deps.now();
    for (const member of [host, guest]) {
      await deps.convexMutation("players:heartbeat", sessionArgs(member));
      await deps.convexMutation("matches:setReady", { ...sessionArgs(member), isReady: true });
    }
    await deps.convexMutation("combat:prepare", sessionArgs(host));
    let issued;
    try { issued = await deps.convexMutation("combat:ticket", sessionArgs(host)); }
    catch (error) { acceptance.ticketKeyParity = "failed"; errors.push(sanitize(error)); }
    mark("ready", readyStart);
    if (issued !== undefined) {
      if (typeof issued?.ticket !== "string" || issued.ticket.length === 0) {
        acceptance.ticketKeyParity = "failed";
        errors.push("ticketMissing");
      } else {
        sensitive.add(issued.ticket);
        let endpoint;
        try { endpoint = new URL(issued.endpoint); } catch { endpoint = null; }
        if (endpoint === null || endpoint.origin !== config.workerUrl) {
          acceptance.ticketKeyParity = "failed";
          errors.push("endpointMismatch");
        } else {
          const socketStart = deps.now();
          let socket;
          try { socket = await deps.openWebSocket(issued.endpoint, issued.ticket); }
          catch (error) {
            acceptance.ticketKeyParity = "failed";
            acceptance.authenticatedWebSocket = "failed";
            errors.push(sanitize(error));
          }
          if (socket !== undefined) {
            try {
              let snapshot = null;
              const deadline = deps.now() + 10_000;
              for (;;) {
                const remaining = deadline - deps.now();
                if (remaining <= 0) break;
                const message = await socket.receive(remaining);
                if (message === null) break;
                if (message?.type === "snapshot") { snapshot = message; break; }
              }
              mark("snapshot", socketStart);
              if (snapshot === null) {
                acceptance.authenticatedWebSocket = "failed";
                errors.push("snapshotTimeout");
              } else if (snapshot.release?.manifest?.protocolVersion !== RELEASE_MANIFEST.protocolVersion) {
                acceptance.ticketKeyParity = "passed";
                acceptance.authenticatedWebSocket = "passed";
                errors.push("protocolMismatch");
              } else {
                acceptance.ticketKeyParity = "passed";
                acceptance.authenticatedWebSocket = "passed";
                probe.snapshotProtocolVersion = snapshot.release.manifest.protocolVersion;
                const worker = snapshot.release?.worker ?? {};
                probe.worker = {
                  versionId: typeof worker.versionId === "string" ? worker.versionId.slice(0, 128) : null,
                  versionTag: typeof worker.versionTag === "string" ? worker.versionTag.slice(0, 128) : null,
                  workerVersionTag: boundedText(worker.workerVersionTag),
                  releaseSha: boundedText(worker.releaseSha),
                  doMigrationTag: boundedText(worker.doMigrationTag),
                };
              }
              try { socket.send(JSON.stringify({ type: "command", envelope: {
                v: RELEASE_MANIFEST.protocolVersion, commandId: "vkz-probe-leave",
                clientSequence: 1, authorityEpoch: 1, frameEpoch: 1,
                sentAtMs: Math.round(deps.now()), command: { kind: "leave" } } })); } catch { /* probe is best-effort */ }
            } finally { try { socket.close(); } catch { /* already closed */ } }
          }
        }
      }
    }
    if (acceptance.authenticatedWebSocket === "passed") {
      const receiptStart = deps.now();
      for (;;) {
        const snapshot = await deps.convexQuery("queries:matchSnapshot", sessionArgs(host));
        const match = snapshot?.match;
        if (match !== undefined && match !== null &&
            ((typeof match.combatProjectionSequence === "number" && match.combatProjectionSequence > 0) ||
             typeof match.combatWorkerVersionTag === "string")) {
          acceptance.projectionReceipt = "passed";
          break;
        }
        if (deps.now() - receiptStart >= 15_000) { acceptance.projectionReceipt = "failed"; break; }
        await deps.sleep(500);
      }
      mark("receipt", receiptStart);
    }
  } catch (error) {
    errors.push(sanitize(error));
  }
  mark("total", probeStart);
  const status = errors.length === 0 && acceptance.ticketKeyParity === "passed" &&
    acceptance.authenticatedWebSocket === "passed" && acceptance.projectionReceipt === "passed"
    ? "verify-passed" : "verify-failed";
  return { status, acceptance, probe, errors };
}

export function validateHealth(value) {
  if (value?.service !== "vkz-combat" || value.protocol !== 1 || value.projection?.configured !== true) fail("health-not-configured");
}

// All seams are read-only until deployWorker. Tests inject these seams without
// invoking GitHub, Cloudflare, a compiler, or production Convex.
export async function runCombatDeploy({ config, secrets, deploy = false }, deps) {
  if (deploy && config.disruptionAcknowledged !== true) fail("active-match-disruption-not-acknowledged");
  parseSecrets(JSON.stringify(secrets));
  const gate = async () => {
    await deps.checkCheckout(config);
    if (await deps.verifyRelease(config) !== true) fail("release-not-verified");
  };
  await gate();
  validateIdentity(await deps.getIdentity(config), config.accountId);
  await deps.checkOutput(config);
  await deps.bundle(config, secrets);
  if (!deploy) return { status: "preflight-passed", externalWrites: false };
  validateIdentity(await deps.getIdentity(config), config.accountId);
  // Identity discovery may be slow. Revalidate release freshness after it,
  // immediately before the first remote write.
  await gate();
  // Versioned rollout only when the deployed Worker already runs this DO
  // migration; a new tag needs a plain deploy to apply the migration.
  const priorHealth = await deps.priorHealth(config);
  const deployedTag = typeof priorHealth?.manifest?.doMigrationTag === "string"
    ? priorHealth.manifest.doMigrationTag : null;
  const localTag = await deps.localMigrationTag(config);
  const strategy = deployedTag !== null && deployedTag === localTag ? "versions" : "deploy";
  const result = deploymentResult(await deps.deployWorker(config, secrets, strategy),
    config.workerUrl, config.workerName, strategy);
  validateHealth(await deps.health(config));
  const probe = await deps.probe(config);
  if (probe.status !== "verify-passed") fail("verify-failed");
  const evidence = {
    schemaVersion: 1, evidenceScope: "combat-worker-deployment-and-config-shape",
    release: { sha: config.sha, recordedAtUtc: new Date().toISOString() },
    worker: { name: config.workerName, versionId: result.versionId },
    deployment: { target: config.target, deployStrategy: strategy, activeMatchDisruptionAcknowledged: true,
      migrationTags: { local: localTag, deployed: deployedTag } },
    prerequisites: { sameShaCiAndConvexSpectatorDeployment: "passed", canonicalCheckout: "passed",
      convexConfiguration: "operator-confirmed-not-probed" },
    health: { service: "vkz-combat", protocol: RELEASE_MANIFEST.protocolVersion, projectionConfigured: true },
    acceptance: probe.acceptance,
    probe: probe.probe,
    ...(probe.errors.length === 0 ? {} : { probeErrors: probe.errors }),
  };
  await deps.writeEvidence(config, evidence);
  return { status: "deployed", evidence };
}

function commandEnvironment(environment, directory) {
  const env = {};
  for (const name of ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SSH_AUTH_SOCK"]) {
    if (environment[name]) env[name] = environment[name];
  }
  // Do not pass the GitHub token, combat keys, .env switches, or CI deployment
  // overrides to Wrangler. Authentication uses its existing OAuth session.
  return { ...env, CI: "true", CLOUDFLARE_ACCOUNT_ID: environment.CLOUDFLARE_ACCOUNT_ID,
    WRANGLER_SEND_METRICS: "false", WRANGLER_LOG_PATH: join(directory, "wrangler.log"),
    WRANGLER_OUTPUT_FILE_PATH: join(directory, "receipt.jsonl"),
    CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV: "false" };
}

async function privateInput(path) {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 || stat.size > 16384) fail("secret-file-must-be-private");
    return await handle.readFile("utf8");
  } finally { await handle.close(); }
}

async function stdinInput() {
  if (process.stdin.isTTY) fail("pipe-secret-json-to-stdin");
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 16384) fail("invalid-secret-input");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function fetchHealth(workerUrl) {
  const response = await fetch(`${workerUrl}/health`, { redirect: "error", signal: AbortSignal.timeout(10000) });
  if (response.status !== 200) fail("health-http-failed");
  const reader = response.body?.getReader();
  if (!reader) fail("health-empty");
  let text = "", bytes = 0;
  const decoder = new TextDecoder();
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.length;
      if (bytes > 4096) fail("health-too-large");
      text += decoder.decode(chunk.value, { stream: true });
    }
    return JSON.parse(text + decoder.decode());
  } finally { await reader.cancel(); }
}

const writeEvidenceFile = (cfg, evidence) =>
  writeFile(cfg.evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600, flag: "wx" });

function probeDependencies(config) {
  const now = () => Date.now();
  const sleep = (ms) => new Promise(resolve2 => setTimeout(resolve2, ms));
  // Convex HTTP API: POST {convexUrl}/api/mutation|query with a function path.
  const convexCall = async (operation, path, args) => {
    const response = await fetch(`${config.convexUrl}/api/${operation}`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ path, args, format: "json" }),
      redirect: "error", signal: AbortSignal.timeout(15000) });
    if (response.status !== 200) fail("convex-http-failed");
    const body = await response.json();
    if (body?.status !== "success") {
      const reason = typeof body?.errorMessage === "string" ? body.errorMessage.slice(0, 160) : "convex-call-failed";
      throw new CombatDeployError(reason);
    }
    return body.value;
  };
  // The Worker authenticates the upgrade with an Authorization Bearer header;
  // Node's global WebSocket cannot send headers, so use the ws package that
  // wrangler already vendors (same resolution pattern as generate.mjs).
  const openWebSocket = async (endpoint, ticket) => {
    const workerRequire = createRequire(join(ROOT, "services/combat-worker/package.json"));
    const wranglerRequire = createRequire(workerRequire.resolve("wrangler/package.json"));
    const { WebSocket } = wranglerRequire("ws");
    const socket = await new Promise((resolvePromise, rejectPromise) => {
      const ws = new WebSocket(endpoint, {
        headers: { Authorization: `Bearer ${ticket}` }, handshakeTimeout: 10000 });
      ws.once("open", () => resolvePromise(ws));
      ws.once("unexpected-response", (_request, response) => {
        response.destroy();
        rejectPromise(new CombatDeployError(`websocket-rejected-${response.statusCode}`));
      });
      ws.once("error", () => rejectPromise(new CombatDeployError("websocket-rejected")));
    });
    const queue = [];
    let closed = false;
    socket.on("message", (data) => {
      try { if (data.byteLength <= 16384) queue.push(JSON.parse(data.toString("utf8"))); } catch { /* non-JSON frame */ }
    });
    socket.on("close", () => { closed = true; });
    return {
      receive: (timeoutMs) => new Promise((resolvePromise) => {
        const timer = setTimeout(() => resolvePromise(null), Math.max(0, timeoutMs));
        const poll = () => {
          if (queue.length > 0 || closed) { clearTimeout(timer); resolvePromise(queue.shift() ?? null); return; }
          setImmediate(poll);
        };
        poll();
      }),
      send: (payload) => socket.send(payload),
      close: () => socket.close(),
    };
  };
  return {
    convexMutation: (path, args) => convexCall("mutation", path, args),
    convexQuery: (path, args) => convexCall("query", path, args),
    openWebSocket, now, sleep,
  };
}

export async function main(args = process.argv.slice(2), env = process.env) {
  const mode = args[0];
  if (!["--preflight", "--deploy", "--verify"].includes(mode)) fail("invalid-arguments");
  const rest = args.slice(1);
  let target = "production";
  const remaining = [];
  for (let index = 0; index < rest.length; index++) {
    if (rest[index] === "--target" && index + 1 < rest.length) target = rest[++index];
    else remaining.push(rest[index]);
  }
  if (!TARGETS.includes(target)) fail("invalid-arguments");
  const secretsRequested = (remaining[0] === "--secrets-stdin" && remaining.length === 1) ||
    (remaining[0] === "--secrets-file" && remaining.length === 2);
  if (mode === "--verify") {
    // The probe needs no Worker secrets; reject any secret arguments outright.
    if (remaining.length !== 0) fail("invalid-arguments");
    const config = probeConfig(env, target);
    const result = await runAdmissionProbe({ config }, probeDependencies(config));
    const evidence = {
      schemaVersion: 1, evidenceScope: "combat-worker-admission-probe",
      target: config.target, recordedAtUtc: new Date().toISOString(),
      acceptance: result.acceptance, probe: result.probe,
      ...(result.errors.length === 0 ? {} : { probeErrors: result.errors }),
    };
    if (config.evidencePath !== null) await writeEvidenceFile(config, evidence);
    process.stdout.write(`Combat deployment: ${result.status.toUpperCase()}\n`);
    if (result.status !== "verify-passed") fail("verify-failed");
    return;
  }
  if (!secretsRequested) fail("invalid-arguments");
  const config = { ...deploymentConfig(env, target),
    disruptionAcknowledged: env.VKZ_ACTIVE_MATCH_DISRUPTION_ACKNOWLEDGED === "true" };
  const secrets = parseSecrets(remaining[0] === "--secrets-stdin" ? await stdinInput() : await privateInput(remaining[1]));
  const directory = await mkdtemp(join(tmpdir(), "vkz-combat-deploy-"));
  try {
    const secretFile = join(directory, "secrets.json");
    await writeFile(secretFile, JSON.stringify(secrets), { mode: 0o600, flag: "wx" });
    const commandEnv = commandEnvironment(env, directory);
    const run = async (program, argv) => {
      try { return (await execute(program, argv, { cwd: ROOT, env: commandEnv,
        timeout: 300000, maxBuffer: 2 * 1024 * 1024 })).stdout; }
      catch { fail("subprocess-failed-output-withheld"); }
    };
    const wrangler = ["--dir", "services/combat-worker", "exec", "wrangler"];
    const envFlag = config.wranglerEnv === undefined ? [] : ["--env", config.wranglerEnv];
    const deployArgs = [...wrangler, "deploy", ...envFlag, "--var", `CONVEX_URL:${config.convexUrl}`,
      "--secrets-file", secretFile, "--outdir", join(directory, "bundle")];
    const result = await runCombatDeploy({ config, secrets, deploy: mode === "--deploy" }, {
      checkCheckout: async () => {
        if ((await run("git", ["rev-parse", "HEAD"])).trim() !== config.sha ||
            (await run("git", ["status", "--porcelain", "--untracked-files=normal"])).trim()) fail("checkout-not-clean-candidate");
      },
      verifyRelease: async () => {
        // PR64 is the prerequisite; no duplicated or weaker fallback gate.
        const { hasSuccessfulDeployment } = await import("./deployment-gate.mjs");
        const facts = { repository: config.repository, sha: config.sha, token: config.token };
        const [ci, deployed] = await Promise.all([hasSuccessfulCiPushRun(facts), hasSuccessfulDeployment(facts)]);
        if (ci !== true || deployed !== true) return false;
        // Read main last so evidence lookup cannot hide a newer release.
        return await fetchCurrentMainSha(facts) === config.sha;
      },
      getIdentity: async () => JSON.parse(await run("pnpm", [...wrangler, "whoami", "--json"])),
      checkOutput: async () => {
        await access(dirname(config.evidencePath), constants.W_OK);
        try { await lstat(config.evidencePath); } catch (error) { if (error.code === "ENOENT") return; throw error; }
        fail("evidence-already-exists");
      },
      bundle: async () => { await run("pnpm", [...deployArgs, "--dry-run"]); },
      priorHealth: async () => {
        try { return await fetchHealth(config.workerUrl); } catch { return null; }
      },
      localMigrationTag: async () => readLocalMigrationTag(config),
      deployWorker: async (cfg, _secrets, strategy) => {
        const outputFile = commandEnv.WRANGLER_OUTPUT_FILE_PATH;
        await rm(outputFile, { force: true });
        if (strategy === "versions") {
          await run("pnpm", [...wrangler, "versions", "upload", ...envFlag,
            "--var", `CONVEX_URL:${cfg.convexUrl}`, "--secrets-file", secretFile,
            "--outdir", join(directory, "bundle")]);
          const uploads = (await readFile(outputFile, "utf8")).trim().split("\n")
            .filter(Boolean).map(line => JSON.parse(line)).filter(entry => entry.type === "version-upload");
          const versionId = uploads[uploads.length - 1]?.version_id;
          if (!VERSION_ID.test(versionId ?? "")) fail("deployment-receipt-invalid");
          await run("pnpm", [...wrangler, "versions", "deploy", ...envFlag,
            "--yes", "--version-id", versionId]);
          return readFile(outputFile, "utf8");
        }
        await run("pnpm", deployArgs);
        return readFile(outputFile, "utf8");
      },
      health: async () => fetchHealth(config.workerUrl),
      probe: async (cfg) => runAdmissionProbe({ config: cfg }, probeDependencies(cfg)),
      writeEvidence: writeEvidenceFile,
    });
    process.stdout.write(`Combat deployment: ${result.status.toUpperCase()}\n`);
  } finally { await rm(directory, { recursive: true, force: true }); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await main(); }
  catch (error) {
    // Raw CLI/API errors may contain configuration values or credentials.
    const reason = error instanceof CombatDeployError ? error.message : "prerequisite-or-verification-failed";
    process.stderr.write(`ERROR: combat deployment stopped (${reason}). No valid success evidence was written; deployment may already have occurred if a later check failed.\n`);
    process.exitCode = 1;
  }
}
