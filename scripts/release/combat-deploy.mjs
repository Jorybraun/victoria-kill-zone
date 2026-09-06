// Guarded Worker bootstrap. Convex configuration is a separate operator step.
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { access, lstat, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { fetchCurrentMainSha, hasSuccessfulCiPushRun } from "./github-api.mjs";

const execute = promisify(execFile);
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const REPOSITORY = "Jorybraun/victoria-kill-zone";
const KEYS = ["COMBAT_TICKET_SECRET", "COMBAT_PROJECTION_SECRET"];
class CombatDeployError extends Error {}
const fail = (code) => { throw new CombatDeployError(code); };

export function httpsOrigin(value) {
  if (typeof value !== "string" || value.length > 256) fail("invalid-origin");
  let url;
  try { url = new URL(value); } catch { fail("invalid-origin"); }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") fail("invalid-origin");
  return url.origin;
}

export function deploymentConfig(env) {
  if (!/^[a-f0-9]{40}$/.test(env.VKZ_CANDIDATE_SHA ?? "")) fail("invalid-sha");
  if (!env.VKZ_GITHUB_TOKEN || !/^[a-f0-9]{32}$/.test(env.CLOUDFLARE_ACCOUNT_ID ?? "")) fail("missing-auth-input");
  const convexUrl = httpsOrigin(env.VKZ_CONVEX_URL);
  const workerUrl = httpsOrigin(env.VKZ_COMBAT_WORKER_URL);
  if (!/^https:\/\/[a-z0-9-]+\.convex\.cloud$/.test(convexUrl) ||
      !/^https:\/\/vkz-combat\.[a-z0-9-]+\.workers\.dev$/.test(workerUrl)) fail("unexpected-deployment-origin");
  if (env.VKZ_CONVEX_CONFIGURATION_CONFIRMED !== "true") fail("convex-operator-handoff-required");
  if (!isAbsolute(env.VKZ_COMBAT_EVIDENCE_PATH ?? "")) fail("evidence-path-required");
  const evidencePath = resolve(env.VKZ_COMBAT_EVIDENCE_PATH);
  if (!relative(ROOT, evidencePath).startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) fail("evidence-must-be-outside-checkout");
  return { sha: env.VKZ_CANDIDATE_SHA, repository: REPOSITORY, token: env.VKZ_GITHUB_TOKEN,
    accountId: env.CLOUDFLARE_ACCOUNT_ID, convexUrl, workerUrl, evidencePath };
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

export function deploymentResult(raw, workerUrl) {
  let entries;
  try { entries = raw.trim().split("\n").filter(Boolean).map(line => JSON.parse(line)); }
  catch { fail("deployment-receipt-invalid"); }
  const records = entries.filter(entry => entry.type === "deploy");
  const result = records[0];
  if (records.length !== 1 || result.version !== 1 || result.worker_name !== "vkz-combat" ||
      !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(result.version_id ?? "") ||
      !Array.isArray(result.targets) || !result.targets.some(target => target === workerUrl || target === `${workerUrl}/`)) fail("deployment-receipt-invalid");
  return { versionId: result.version_id };
}

export function validateHealth(value) {
  if (value?.service !== "vkz-combat" || value.protocol !== 1 || value.projection?.configured !== true) fail("health-not-configured");
}

// All seams are read-only until deployWorker. Tests inject these seams without
// invoking GitHub, Cloudflare, a compiler, or production Convex.
export async function runCombatDeploy({ config, secrets, deploy = false }, deps) {
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
  await gate();
  validateIdentity(await deps.getIdentity(config), config.accountId);
  const result = deploymentResult(await deps.deployWorker(config, secrets), config.workerUrl);
  validateHealth(await deps.health(config));
  const evidence = {
    schemaVersion: 1, evidenceScope: "combat-worker-deployment-and-config-shape",
    release: { sha: config.sha, recordedAtUtc: new Date().toISOString() },
    worker: { name: "vkz-combat", versionId: result.versionId },
    prerequisites: { sameShaCiAndConvexSpectatorDeployment: "passed", canonicalCheckout: "passed",
      convexConfiguration: "operator-confirmed-not-probed" },
    health: { service: "vkz-combat", protocol: 1, projectionConfigured: true },
    acceptance: { ticketKeyParity: "not-tested", authenticatedWebSocket: "not-tested",
      projectionReceipt: "not-tested", physicalCalibration: "not-tested" },
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

export async function main(args = process.argv.slice(2), env = process.env) {
  const deploy = args[0] === "--deploy";
  if (!["--preflight", "--deploy"].includes(args[0]) ||
      !((args[1] === "--secrets-stdin" && args.length === 2) ||
        (args[1] === "--secrets-file" && args.length === 3))) fail("invalid-arguments");
  const config = deploymentConfig(env);
  const secrets = parseSecrets(args[1] === "--secrets-stdin" ? await stdinInput() : await privateInput(args[2]));
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
    const deployArgs = [...wrangler, "deploy", "--var", `CONVEX_URL:${config.convexUrl}`,
      "--secrets-file", secretFile, "--outdir", join(directory, "bundle")];
    const result = await runCombatDeploy({ config, secrets, deploy }, {
      checkCheckout: async () => {
        if ((await run("git", ["rev-parse", "HEAD"])).trim() !== config.sha ||
            (await run("git", ["status", "--porcelain", "--untracked-files=normal"])).trim()) fail("checkout-not-clean-candidate");
      },
      verifyRelease: async () => {
        // PR64 is the prerequisite; no duplicated or weaker fallback gate.
        const { hasSuccessfulDeployment } = await import("./deployment-gate.mjs");
        const facts = { repository: config.repository, sha: config.sha, token: config.token };
        if (await fetchCurrentMainSha(facts) !== config.sha) return false;
        const [ci, deployed] = await Promise.all([hasSuccessfulCiPushRun(facts), hasSuccessfulDeployment(facts)]);
        return ci === true && deployed === true;
      },
      getIdentity: async () => JSON.parse(await run("pnpm", [...wrangler, "whoami", "--json"])),
      checkOutput: async () => {
        await access(dirname(config.evidencePath), constants.W_OK);
        try { await lstat(config.evidencePath); } catch (error) { if (error.code === "ENOENT") return; throw error; }
        fail("evidence-already-exists");
      },
      bundle: async () => { await run("pnpm", [...deployArgs, "--dry-run"]); },
      deployWorker: async () => {
        await rm(commandEnv.WRANGLER_OUTPUT_FILE_PATH, { force: true });
        await run("pnpm", deployArgs);
        return readFile(commandEnv.WRANGLER_OUTPUT_FILE_PATH, "utf8");
      },
      health: async () => {
        const response = await fetch(`${config.workerUrl}/health`, { redirect: "error", signal: AbortSignal.timeout(10000) });
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
      },
      writeEvidence: (cfg, evidence) => writeFile(cfg.evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600, flag: "wx" }),
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
