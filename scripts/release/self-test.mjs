import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  assertUnknownCodeReturnsNull,
  loadConvexClient,
  makeValidCode,
} from "./smoke-convex.mjs";
import { createEvidence, writeEvidence } from "./write-evidence.mjs";

const allowedCode = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/u;

const deterministicCode = makeValidCode(() => 0);
assert.equal(deterministicCode, "AAAAAA");
assert.match(deterministicCode, allowedCode);

const queriedCodes = [];
await assertUnknownCodeReturnsNull(async (code) => {
  queriedCodes.push(code);
  return queriedCodes.length === 1 ? { match: "occupied" } : null;
}, { nextIndex: () => 1 });
assert.equal(queriedCodes.length, 2);
assert.ok(queriedCodes.every((code) => allowedCode.test(code)));

await assert.rejects(
  assertUnknownCodeReturnsNull(async () => ({ match: "occupied" }), {
    maxAttempts: 2,
    nextIndex: () => 2,
  }),
);
assert.throws(() => makeValidCode(() => -1));

const convexClient = await loadConvexClient();
assert.equal(typeof convexClient.ConvexHttpClient, "function");
assert.equal(typeof convexClient.makeFunctionReference, "function");

const evidenceEnvironment = {
  GITHUB_RUN_ATTEMPT: "3",
  GITHUB_RUN_ID: "987654321",
  GITHUB_WORKFLOW: "Deploy",
  GITHUB_WORKFLOW_REF: "example/vkz/.github/workflows/deploy.yml@refs/heads/main",
  VKZ_EVIDENCE_PATH: "unused",
  VKZ_PAGES_ARTIFACT_ID: "123456789",
  VKZ_RELEASE_ENVIRONMENT: "production",
  VKZ_RELEASE_SHA: "0123456789abcdef0123456789abcdef01234567",
  VKZ_SOURCE_RUN_ID: "12345",
  UNRELATED_DEPLOYMENT_URL: "https://must-not-appear.invalid",
  UNRELATED_SECRET: "must-not-appear",
};
const evidenceTime = new Date("2026-08-22T20:00:00.000Z");
const evidence = createEvidence(evidenceEnvironment, evidenceTime);

assert.equal(evidence.evidenceScope, "deployment-smoke");
assert.equal(evidence.release.sha, evidenceEnvironment.VKZ_RELEASE_SHA);
assert.equal(evidence.release.environment, "production");
assert.equal(evidence.release.recordedAtUtc, evidenceTime.toISOString());
assert.equal(evidence.workflow.runId, "987654321");
assert.equal(evidence.workflow.runAttempt, "3");
assert.equal(evidence.workflow.sourceRunId, "12345");
assert.equal(evidence.deploymentIdentifiers.pagesArtifactId, "123456789");
assert.equal(evidence.smokeResults.convexSpectatorSnapshotUnknownCode.status, "passed");
assert.equal(evidence.smokeResults.pagesHttp.status, "passed");

const serializedEvidence = JSON.stringify(evidence);
assert.doesNotMatch(serializedEvidence, /https?:\/\//u);
assert.doesNotMatch(serializedEvidence, /must-not-appear/u);
assert.doesNotMatch(serializedEvidence, /device|session|secret|url/u);
assert.throws(() =>
  createEvidence({ ...evidenceEnvironment, VKZ_RELEASE_SHA: "not-a-sha" }),
);
assert.throws(() =>
  createEvidence({ ...evidenceEnvironment, GITHUB_RUN_ATTEMPT: "0" }),
);
assert.throws(() =>
  createEvidence({ ...evidenceEnvironment, GITHUB_WORKFLOW: "Deploy\nunsafe" }),
);

const evidenceDirectory = await mkdtemp(join(tmpdir(), "vkz-release-evidence-test-"));
try {
  const evidencePath = join(evidenceDirectory, "evidence.json");
  await writeEvidence(
    { ...evidenceEnvironment, VKZ_EVIDENCE_PATH: evidencePath },
    evidenceTime,
  );
  const writtenEvidence = JSON.parse(await readFile(evidencePath, "utf8"));
  assert.deepEqual(writtenEvidence, evidence);
} finally {
  await rm(evidenceDirectory, { force: true, recursive: true });
}

process.stdout.write("Release JavaScript self-tests: PASS\n");
