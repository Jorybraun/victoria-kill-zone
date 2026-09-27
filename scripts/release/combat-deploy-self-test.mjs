import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  deploymentConfig, probeConfig, parseSecrets, validateIdentity, deploymentResult,
  validateHealth, runCombatDeploy, runAdmissionProbe, main,
} from "./combat-deploy.mjs";

// Credentials exist only in memory and assertions never print their values.
const secrets = {
  COMBAT_TICKET_SECRET: randomBytes(32).toString("hex"),
  COMBAT_PROJECTION_SECRET: randomBytes(32).toString("hex"),
};
const environment = {
  VKZ_CANDIDATE_SHA: randomBytes(20).toString("hex"),
  VKZ_GITHUB_TOKEN: randomBytes(32).toString("hex"),
  CLOUDFLARE_ACCOUNT_ID: randomBytes(16).toString("hex"),
  VKZ_CONVEX_URL: "https://release-test.convex.cloud",
  VKZ_COMBAT_WORKER_URL: "https://vkz-combat.release-test.workers.dev",
  VKZ_CONVEX_CONFIGURATION_CONFIRMED: "true",
  VKZ_COMBAT_EVIDENCE_PATH: `/tmp/vkz-combat-evidence-${randomUUID()}.json`,
};
const config = Object.assign(deploymentConfig(environment), { disruptionAcknowledged: true });
const identity = () => ({ loggedIn: true, authType: "OAuth Token",
  accounts: [{ id: config.accountId }], tokenPermissions: ["workers:write"] });
const versionId = randomUUID();
const receipt = (changes = {}) => JSON.stringify({ type: "deploy", version: 1,
  worker_name: "vkz-combat", version_id: versionId, targets: [config.workerUrl], ...changes });
const versionsReceipt = (changes = {}) => [
  JSON.stringify({ type: "version-upload", version: 1, worker_name: "vkz-combat",
    worker_tag: randomUUID(), version_id: versionId, preview_url: null,
    preview_alias_url: null, wrangler_environment: null, worker_name_overridden: false }),
  JSON.stringify({ type: "version-deploy", version: 1, worker_name: "vkz-combat",
    worker_tag: randomUUID(), deployment_id: randomUUID(), version_traffic: {}, ...changes }),
].join("\n");
const health = () => ({ service: "vkz-combat", protocol: 1, projection: { configured: true } });

for (const origin of ["http://release-test.convex.cloud", "https://user@release-test.convex.cloud",
  "https://release-test.convex.cloud/path", "https://release-test.convex.cloud/?query=1",
  "https://release-test.convex.cloud/#fragment", "not-a-url", "https://example.com"]) {
  assert.throws(() => deploymentConfig({ ...environment, VKZ_CONVEX_URL: origin }));
}
for (const override of [
  { VKZ_COMBAT_WORKER_URL: "https://other.release-test.workers.dev" },
  { VKZ_COMBAT_WORKER_URL: "https://vkz-combat.release-test.workers.dev/path" },
  { VKZ_CANDIDATE_SHA: "invalid" }, { VKZ_GITHUB_TOKEN: "" },
  { CLOUDFLARE_ACCOUNT_ID: "" }, { VKZ_CONVEX_CONFIGURATION_CONFIRMED: "false" },
  { VKZ_COMBAT_EVIDENCE_PATH: "relative.json" },
  { VKZ_COMBAT_EVIDENCE_PATH: fileURLToPath(new URL("./fixture-evidence.json", import.meta.url)) },
]) assert.throws(() => deploymentConfig({ ...environment, ...override }));

assert.ok(Object.keys(parseSecrets(JSON.stringify(secrets))).length === 2);
for (const invalid of ["not-json", "null", "[]", "{}",
  JSON.stringify({ COMBAT_TICKET_SECRET: secrets.COMBAT_TICKET_SECRET }),
  JSON.stringify({ ...secrets, EXTRA: randomBytes(32).toString("hex") }),
  JSON.stringify({ ...secrets, COMBAT_TICKET_SECRET: randomBytes(8).toString("hex") }),
  JSON.stringify({ ...secrets, COMBAT_PROJECTION_SECRET: secrets.COMBAT_TICKET_SECRET }),
  JSON.stringify({ ...secrets, COMBAT_PROJECTION_SECRET: randomBytes(4097).toString("hex") }),
]) assert.throws(() => parseSecrets(invalid), /invalid-secret-input/u);

validateIdentity(identity(), config.accountId);
validateIdentity({ ...identity(), tokenPermissions: ["workers_scripts:write"] }, config.accountId);
for (const invalid of [null, { ...identity(), loggedIn: false },
  { ...identity(), authType: "API Token" }, { ...identity(), accounts: [] },
  { ...identity(), accounts: [{ id: randomBytes(16).toString("hex") }] },
  { ...identity(), tokenPermissions: ["workers:read"] },
  { ...identity(), tokenPermissions: undefined },
]) assert.throws(() => validateIdentity(invalid, config.accountId), /cloudflare-auth-not-verified/u);

assert.equal(deploymentResult(receipt(), config.workerUrl).versionId, versionId);
assert.equal(deploymentResult(receipt({ targets: [`${config.workerUrl}/`] }), config.workerUrl).versionId, versionId);
for (const invalid of ["", "invalid-json", "{}", "null", `${receipt()}\n${receipt()}`,
  receipt({ version: 2 }), receipt({ worker_name: "other" }), receipt({ version_id: "invalid" }),
  receipt({ targets: ["https://vkz-combat.other.workers.dev"] }), receipt({ targets: [] }),
]) assert.throws(() => deploymentResult(invalid, config.workerUrl));
// Versioned receipts: one version-upload plus one version-deploy record.
const versionsResult = deploymentResult(versionsReceipt(), config.workerUrl, "vkz-combat", "versions");
assert.equal(versionsResult.versionId, versionId);
for (const invalid of [versionsReceipt({ worker_name: "other" }), receipt(),
  `${versionsReceipt()}\n${versionsReceipt()}`,
  versionsReceipt().split("\n")[0],
  versionsReceipt({ version: 2 }),
]) assert.throws(() => deploymentResult(invalid, config.workerUrl, "vkz-combat", "versions"));
validateHealth(health());
for (const invalid of [null, {}, { ...health(), service: "other" }, { ...health(), protocol: 2 },
  { ...health(), projection: { configured: false } }]) assert.throws(() => validateHealth(invalid), /health-not-configured/u);

const probePass = () => ({
  status: "verify-passed",
  acceptance: { ticketKeyParity: "passed", authenticatedWebSocket: "passed",
    projectionReceipt: "passed", physicalCalibration: "not-tested" },
  probe: { matchCreated: true, snapshotProtocolVersion: 1,
    worker: { versionId, versionTag: null, workerVersionTag: "vkz-combat-2026.09",
      releaseSha: "0".repeat(40), doMigrationTag: "v1" },
    durationsMs: { lobby: 1, ready: 2, snapshot: 3, receipt: 4, total: 10 } },
  errors: [],
});

function fixture(overrides = {}) {
  const calls = [];
  const written = [];
  const defaults = {
    checkCheckout: async () => undefined,
    verifyRelease: async () => true,
    getIdentity: async () => identity(),
    checkOutput: async () => undefined,
    bundle: async () => undefined,
    priorHealth: async () => null,
    localMigrationTag: async () => "v1",
    deployWorker: async (_config, _secrets, strategy = "deploy") =>
      strategy === "versions" ? versionsReceipt() : receipt(),
    health: async () => ({ ...health(), worker: { versionId } }),
    sleep: async () => undefined,
    probe: async () => probePass(),
    writeEvidence: async (_config, evidence) => { written.push(evidence); },
  };
  const deps = Object.fromEntries(Object.entries({ ...defaults, ...overrides }).map(([name, operation]) =>
    [name, async (...args) => { calls.push(name); return operation(...args); }]));
  return { calls, written, deps };
}
const run = (f, deploy = true) => runCombatDeploy({ config, secrets, deploy }, f.deps);
const preflight = fixture();
assert.deepEqual(await run(preflight, false), { status: "preflight-passed", externalWrites: false });
assert.deepEqual(preflight.calls, ["checkCheckout", "verifyRelease", "getIdentity", "checkOutput", "bundle"]);
assert.equal(preflight.written.length, 0);

// Every predeployment prerequisite fails closed, including an absent seam.
for (const name of ["checkCheckout", "verifyRelease", "getIdentity", "checkOutput", "bundle"]) {
  const f = fixture({ [name]: async () => { throw new Error("fixture-prerequisite-failed"); } });
  await assert.rejects(run(f));
  assert.equal(f.calls.includes("deployWorker"), false);
  assert.equal(f.written.length, 0);
}
for (const name of ["checkCheckout", "verifyRelease", "getIdentity", "checkOutput", "bundle"]) {
  const f = fixture(); delete f.deps[name];
  await assert.rejects(run(f));
  assert.equal(f.calls.includes("deployWorker"), false);
  assert.equal(f.written.length, 0);
}
for (const result of [false, undefined, "true"]) {
  const f = fixture({ verifyRelease: async () => result });
  await assert.rejects(run(f), /release-not-verified/u);
  assert.equal(f.calls.includes("bundle"), false);
  assert.equal(f.calls.includes("deployWorker"), false);
}
const invalidAuth = fixture({ getIdentity: async () => ({ ...identity(), accounts: [] }) });
await assert.rejects(run(invalidAuth), /cloudflare-auth-not-verified/u);
assert.equal(invalidAuth.calls.includes("bundle"), false);

let gateCalls = 0;
const changedGate = fixture({ verifyRelease: async () => ++gateCalls === 1 });
await assert.rejects(run(changedGate), /release-not-verified/u);
assert.equal(gateCalls, 2);
assert.equal(changedGate.calls.includes("bundle"), true);
assert.equal(changedGate.calls.includes("deployWorker"), false);
assert.equal(changedGate.written.length, 0);
let identityCalls = 0;
const changedAuth = fixture({ getIdentity: async () => ++identityCalls === 1 ? identity() : { loggedIn: false } });
await assert.rejects(run(changedAuth), /cloudflare-auth-not-verified/u);
assert.equal(identityCalls, 2);
assert.equal(changedAuth.calls.includes("deployWorker"), false);

// Main can advance while the final identity lookup is awaiting its response.
let releaseFresh = true, freshnessIdentityCalls = 0;
const changedDuringIdentity = fixture({
  verifyRelease: async () => releaseFresh,
  getIdentity: async () => {
    if (++freshnessIdentityCalls === 2) releaseFresh = false;
    return identity();
  },
});
const staleReleaseError = await run(changedDuringIdentity).catch(error => error);
assert.equal(freshnessIdentityCalls, 2);
assert.equal(changedDuringIdentity.calls.includes("deployWorker"), false,
  "Main advancing during final identity lookup must prevent deployment");
assert.equal(changedDuringIdentity.written.length, 0);
assert.ok(staleReleaseError instanceof Error);
assert.match(staleReleaseError.message, /release-not-verified/u);

for (const invalid of ["invalid-json", receipt({ targets: ["https://vkz-combat.other.workers.dev"] })]) {
  const f = fixture({ deployWorker: async () => invalid });
  await assert.rejects(run(f));
  assert.equal(f.calls.includes("health"), false);
  assert.equal(f.written.length, 0);
}
for (const override of [
  { deployWorker: async () => { throw new Error("fixture-deploy-failed"); } },
  { health: async () => { throw new Error("fixture-health-failed"); } },
  { health: async () => ({ ...health(), projection: { configured: false } }) },
]) {
  const f = fixture(override);
  await assert.rejects(run(f));
  assert.equal(f.written.length, 0);
}
const failedEvidence = fixture({ writeEvidence: async () => { throw new Error("fixture-evidence-failed"); } });
await assert.rejects(run(failedEvidence), /fixture-evidence-failed/u);

const success = fixture();
const result = await run(success);
assert.equal(result.status, "deployed");
assert.deepEqual(success.calls, ["checkCheckout", "verifyRelease", "getIdentity", "checkOutput", "bundle",
  "getIdentity", "checkCheckout", "verifyRelease", "priorHealth", "localMigrationTag",
  "deployWorker", "health", "probe", "writeEvidence"]);
assert.equal(success.written.length, 1);
assert.equal(result.evidence.release.sha, config.sha);
assert.equal(result.evidence.worker.versionId, versionId);
assert.ok(Number.isFinite(Date.parse(result.evidence.release.recordedAtUtc)));
assert.equal(result.evidence.prerequisites.convexConfiguration, "operator-confirmed-not-probed");
assert.equal(result.evidence.deployment.deployStrategy, "deploy");
assert.equal(result.evidence.deployment.activeMatchDisruptionAcknowledged, true);
assert.deepEqual(result.evidence.deployment.migrationTags, { local: "v1", deployed: null });
assert.equal(result.evidence.deployment.servingVersionId, versionId);
assert.equal(result.evidence.acceptance.physicalCalibration, "not-tested");
assert.equal(result.evidence.acceptance.ticketKeyParity, "passed");
assert.equal(result.evidence.probe.worker.workerVersionTag, "vkz-combat-2026.09");
const encoded = JSON.stringify(result.evidence);
for (const privateValue of [config.token, config.accountId, config.convexUrl, config.workerUrl, config.evidencePath,
  ...Object.values(secrets)]) assert.equal(encoded.includes(privateValue), false);
assert.equal(/https?:\/\//u.test(encoded), false);

// --deploy without the disruption acknowledgement fails closed before any call.
{
  const f = fixture();
  await assert.rejects(
    runCombatDeploy({ config: { ...config, disruptionAcknowledged: false }, secrets, deploy: true }, f.deps),
    /active-match-disruption-not-acknowledged/u);
  assert.equal(f.calls.length, 0);
}

// Same DO migration tag on the deployed Worker selects the versions strategy.
{
  const f = fixture({ priorHealth: async () => ({ manifest: { doMigrationTag: "v1" } }) });
  const outcome = await run(f);
  assert.equal(outcome.evidence.deployment.deployStrategy, "versions");
  assert.equal(outcome.evidence.deployment.migrationTags.deployed, "v1");
}
// A different or unknown deployed tag keeps the plain deploy path.
for (const prior of ["v2", null]) {
  const f = fixture({
    priorHealth: async () => (prior === null ? null : { manifest: { doMigrationTag: prior } }),
  });
  const outcome = await run(f);
  assert.equal(outcome.evidence.deployment.deployStrategy, "deploy");
}

// The serving version must match the deployment receipt before the probe runs
// and the probe must observe that same version.
{
  let polls = 0;
  const f = fixture({ health: async () => ({ ...health(), worker: { versionId: polls++ === 0 ? randomUUID() : versionId } }) });
  const outcome = await run(f);
  assert.equal(outcome.evidence.deployment.servingVersionId, versionId);
  assert.ok(f.calls.includes("sleep"));
}
{
  const f = fixture({ health: async () => ({ ...health(), worker: { versionId: randomUUID() } }) });
  await assert.rejects(run(f), /deployed-version-not-serving/u);
  assert.equal(f.written.length, 0);
  assert.equal(f.calls.includes("probe"), false);
}
{
  const f = fixture({ probe: async () => ({ ...probePass(),
    probe: { ...probePass().probe, worker: { ...probePass().probe.worker, versionId: randomUUID() } } }) });
  await assert.rejects(run(f), /deployed-version-not-serving/u);
  assert.equal(f.written.length, 0);
}

// A failing admission probe blocks evidence and exits failed.
{
  const f = fixture({ probe: async () => ({ ...probePass(), status: "verify-failed",
    acceptance: { ...probePass().acceptance, projectionReceipt: "failed" }, errors: ["receiptTimeout"] }) });
  await assert.rejects(run(f), /verify-failed/u);
  assert.equal(f.written.length, 0);
}

// Staging target reads its own origins and worker name.
const stagingEnvironment = {
  ...environment,
  VKZ_CONVEX_STAGING_URL: "https://staging-test.convex.cloud",
  VKZ_COMBAT_STAGING_WORKER_URL: "https://vkz-combat-staging.release-test.workers.dev",
};
{
  const staging = deploymentConfig(stagingEnvironment, "staging");
  assert.equal(staging.workerName, "vkz-combat-staging");
  assert.equal(staging.wranglerEnv, "staging");
  assert.equal(staging.target, "staging");
  assert.throws(() => probeConfig({ ...stagingEnvironment, VKZ_COMBAT_WORKER_URL: "https://vkz-combat.other.workers.dev",
    VKZ_COMBAT_STAGING_WORKER_URL: "https://vkz-combat.release-test.workers.dev" }, "staging"), /unexpected-deployment-origin/u);
  assert.throws(() => deploymentConfig(stagingEnvironment, "staging2"), /invalid-arguments/u);
  // Staging origins must never alias the production deployment.
  assert.throws(() => probeConfig({ ...stagingEnvironment, VKZ_CONVEX_STAGING_URL: environment.VKZ_CONVEX_URL }, "staging"), /staging-origins-match-production/u);
  assert.throws(() => probeConfig({ ...stagingEnvironment, VKZ_COMBAT_STAGING_WORKER_URL: environment.VKZ_COMBAT_WORKER_URL }, "staging"), /staging-origins-match-production/u);
  assert.doesNotThrow(() => probeConfig({ VKZ_CONVEX_STAGING_URL: stagingEnvironment.VKZ_CONVEX_STAGING_URL,
    VKZ_COMBAT_STAGING_WORKER_URL: stagingEnvironment.VKZ_COMBAT_STAGING_WORKER_URL }, "staging"));
}

// --verify rejects any secret argument without touching the network.
for (const args of [["--verify", "--secrets-stdin"], ["--verify", "--secrets-file", "/tmp/x"], ["--verify", "--target", "invalid"]]) {
  await assert.rejects(main(args, environment), /invalid-arguments/u);
}

// Admission probe end-to-end with fake deps: create/join/ready/prepare/ticket,
// websocket snapshot with release identity, leave, and projection receipt.
function probeFixture(overrides = {}) {
  let clock = 1_000_000;
  const ticket = `probe-ticket-${randomUUID()}`;
  const sent = [];
  const mutations = [];
  const session = (playerId) => ({ matchId: "match-1", code: "ABCD", playerId, sessionSecret: `session-${playerId}-${randomUUID()}` });
  const host = session("host"), guest = session("guest");
  const snapshotMessage = { type: "snapshot", eventSequence: 0, clientSequence: 0,
    release: { manifest: { protocolVersion: 1 }, worker: {
      versionId, versionTag: "tag-1", workerVersionTag: "vkz-combat-2026.09",
      releaseSha: "0".repeat(40), doMigrationTag: "v1" } },
    snapshot: {} };
  const deps = {
    convexMutation: async (path) => {
      mutations.push(path);
      if (path === "matches:create") return host;
      if (path === "matches:join") return guest;
      if (path === "combat:ticket") return { endpoint: `${config.workerUrl}/v1/matches/match-1/connect`, ticket, expiresAt: 0, authorityEpoch: 1, frameEpoch: 1 };
      return null;
    },
    convexQuery: async () => ({ match: { combatProjectionSequence: 3, combatWorkerVersionTag: "vkz-combat-2026.09" } }),
    openWebSocket: async (endpoint, presented) => ({
      receive: async () => snapshotMessage,
      send: (payload) => { sent.push(payload); },
      close: () => undefined,
    }),
    now: () => clock,
    sleep: async (ms) => { clock += ms; },
    ...overrides,
  };
  return { deps, ticket, sent, mutations, sessions: [host, guest] };
}
{
  const f = probeFixture();
  const result = await runAdmissionProbe({ config }, f.deps);
  assert.equal(result.status, "verify-passed");
  assert.deepEqual(result.acceptance, { ticketKeyParity: "passed", authenticatedWebSocket: "passed",
    projectionReceipt: "passed", physicalCalibration: "not-tested" });
  assert.equal(result.probe.matchCreated, true);
  assert.equal(result.probe.snapshotProtocolVersion, 1);
  assert.equal(result.probe.worker.doMigrationTag, "v1");
  assert.deepEqual(f.mutations, ["matches:create", "matches:join", "players:heartbeat", "matches:setReady",
    "players:heartbeat", "matches:setReady", "combat:prepare", "combat:ticket"]);
  assert.equal(f.sent.length, 1);
  assert.match(f.sent[0], /"kind":\s*"leave"/u);
  const encodedProbe = JSON.stringify(result);
  for (const secret of [f.ticket, ...f.sessions.map(s => s.sessionSecret), config.workerUrl, config.convexUrl]) {
    assert.equal(encodedProbe.includes(secret), false);
  }
}
// A failed ticket mutation is a probe error, not key-parity evidence; only a
// websocket handshake rejection fails key parity.
{
  const f = probeFixture({ convexMutation: async (path) => {
    if (path === "combat:ticket") throw new Error("AUTH_KEY_MISMATCH raw text must not persist");
    return { matchId: "m", code: "ABCD", playerId: "p", sessionSecret: `s-${randomUUID()}` };
  } });
  const result = await runAdmissionProbe({ config }, f.deps);
  assert.equal(result.status, "verify-failed");
  assert.equal(result.acceptance.ticketKeyParity, "not-tested");
  assert.equal(result.acceptance.authenticatedWebSocket, "not-tested");
  assert.equal(JSON.stringify(result).includes("AUTH_KEY_MISMATCH"), false);
  assert.ok(result.errors.every(code => /^(convex-http-\d+|websocket-rejected-\d+|timeout|probe-session-invalid|endpointMismatch|snapshot-invalid|network|unknown)$/u.test(code)));
}
{
  const f = probeFixture({ openWebSocket: async () => { throw new Error("websocket-rejected-401"); } });
  const result = await runAdmissionProbe({ config }, f.deps);
  assert.equal(result.status, "verify-failed");
  assert.equal(result.acceptance.ticketKeyParity, "failed");
  assert.equal(result.acceptance.authenticatedWebSocket, "failed");
  assert.ok(result.errors.includes("websocket-rejected-401"));
}
// Any other handshake or transport failure is not key-parity evidence.
for (const rejected of ["websocket-rejected-503", "websocket-rejected", "ECONNREFUSED"]) {
  const f = probeFixture({ openWebSocket: async () => { throw new Error(rejected); } });
  const result = await runAdmissionProbe({ config }, f.deps);
  assert.equal(result.status, "verify-failed");
  assert.equal(result.acceptance.ticketKeyParity, "not-tested");
  assert.equal(result.acceptance.authenticatedWebSocket, "failed");
}
// A projection that never lands fails the receipt check on timeout.
{
  const f = probeFixture({ convexQuery: async () => ({ match: { combatProjectionSequence: 0 } }) });
  const result = await runAdmissionProbe({ config }, f.deps);
  assert.equal(result.status, "verify-failed");
  assert.equal(result.acceptance.projectionReceipt, "failed");
  assert.equal(result.acceptance.authenticatedWebSocket, "passed");
}
// A snapshot on a foreign protocol version still fails verification.
{
  const wrong = probeFixture({
    openWebSocket: async () => ({
      receive: async () => ({ type: "snapshot", release: { manifest: { protocolVersion: 2 }, worker: {} }, snapshot: {} }),
      send: () => undefined, close: () => undefined }),
  });
  const result = await runAdmissionProbe({ config }, wrong.deps);
  assert.equal(result.status, "verify-failed");
  assert.equal(result.acceptance.authenticatedWebSocket, "passed");
  assert.ok(result.errors.includes("snapshot-invalid"));
}
process.stdout.write("Combat deployment self-tests passed.\n");
