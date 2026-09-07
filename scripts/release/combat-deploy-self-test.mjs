import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import {
  deploymentConfig, parseSecrets, validateIdentity, deploymentResult,
  validateHealth, runCombatDeploy,
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
const config = deploymentConfig(environment);
const identity = () => ({ loggedIn: true, authType: "OAuth Token",
  accounts: [{ id: config.accountId }], tokenPermissions: ["workers:write"] });
const versionId = randomUUID();
const receipt = (changes = {}) => JSON.stringify({ type: "deploy", version: 1,
  worker_name: "vkz-combat", version_id: versionId, targets: [config.workerUrl], ...changes });
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
  { VKZ_COMBAT_EVIDENCE_PATH: new URL("./fixture-evidence.json", import.meta.url).pathname },
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
validateHealth(health());
for (const invalid of [null, {}, { ...health(), service: "other" }, { ...health(), protocol: 2 },
  { ...health(), projection: { configured: false } }]) assert.throws(() => validateHealth(invalid), /health-not-configured/u);

function fixture(overrides = {}) {
  const calls = [];
  const written = [];
  const defaults = {
    checkCheckout: async () => undefined,
    verifyRelease: async () => true,
    getIdentity: async () => identity(),
    checkOutput: async () => undefined,
    bundle: async () => undefined,
    deployWorker: async () => receipt(),
    health: async () => health(),
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
  "getIdentity", "checkCheckout", "verifyRelease", "deployWorker", "health", "writeEvidence"]);
assert.equal(success.written.length, 1);
assert.equal(result.evidence.release.sha, config.sha);
assert.equal(result.evidence.worker.versionId, versionId);
assert.ok(Number.isFinite(Date.parse(result.evidence.release.recordedAtUtc)));
assert.equal(result.evidence.prerequisites.convexConfiguration, "operator-confirmed-not-probed");
assert.ok(Object.values(result.evidence.acceptance).every(value => value === "not-tested"));
const encoded = JSON.stringify(result.evidence);
for (const privateValue of [config.token, config.accountId, config.convexUrl, config.workerUrl, config.evidencePath,
  ...Object.values(secrets)]) assert.equal(encoded.includes(privateValue), false);
assert.equal(/https?:\/\//u.test(encoded), false);
process.stdout.write("Combat deployment self-tests passed.\n");
