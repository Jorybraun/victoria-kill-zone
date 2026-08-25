import assert from "node:assert/strict";

import { pollProcessingState, createAscToken } from "./asc-client.mjs";
import { createEvidence, runPromotion } from "./promote-testflight.mjs";
import { decidePromotion } from "./promotion-gate.mjs";
import { sanitizeText } from "./redact.mjs";
import { buildStatusMessage, postStatus } from "./slack-notify.mjs";

const CURRENT_SHA = "1111111111111111111111111111111111111111";
const STALE_SHA = "2222222222222222222222222222222222222222";
const REPOSITORY = "example/victoria-kill-zone";

const greenRun = {
  enabled: true,
  eventName: "workflow_run",
  ciWorkflowName: "CI",
  ciEvent: "push",
  ciConclusion: "success",
  headBranch: "main",
  headRepository: REPOSITORY,
  repository: REPOSITORY,
  candidateSha: CURRENT_SHA,
  currentMainSha: CURRENT_SHA,
};

// Gate: the exact current green main revision promotes.
assert.deepEqual(decidePromotion(greenRun), {
  promote: true,
  reasonKey: "promote",
  reason: "the exact current main revision is green",
  sha: CURRENT_SHA,
});

// Gate: a stale revision is skipped rather than promoted.
const stale = decidePromotion({ ...greenRun, candidateSha: STALE_SHA });
assert.equal(stale.promote, false);
assert.equal(stale.reasonKey, "staleSha");
assert.equal(stale.sha, null);

// Gate: the lane fails closed unless it is explicitly enabled.
assert.equal(decidePromotion({ ...greenRun, enabled: false }).reasonKey, "disabled");
assert.equal(decidePromotion({ ...greenRun, enabled: "true" }).reasonKey, "disabled");

// Gate: only green CI on this repository's own main may promote.
assert.equal(decidePromotion({ ...greenRun, ciConclusion: "failure" }).reasonKey, "ciNotSuccessful");
assert.equal(decidePromotion({ ...greenRun, headBranch: "feature" }).reasonKey, "notMain");
// A green pull-request CI run must never queue the signing runner.
assert.equal(decidePromotion({ ...greenRun, ciEvent: "pull_request" }).reasonKey, "notMergeEvent");
assert.equal(decidePromotion({ ...greenRun, ciWorkflowName: "Deploy" }).reasonKey, "notCiWorkflow");
assert.equal(
  decidePromotion({ ...greenRun, headRepository: "fork/victoria-kill-zone" }).reasonKey,
  "forkedRepository",
);
assert.equal(decidePromotion({ ...greenRun, eventName: "push" }).reasonKey, "unsupportedEvent");
assert.equal(decidePromotion({ ...greenRun, candidateSha: "abc" }).reasonKey, "invalidCandidate");
assert.equal(decidePromotion({ ...greenRun, currentMainSha: "" }).reasonKey, "invalidCurrent");

// Redaction: nothing sensitive survives sanitization. The credential-shaped
// fixtures are assembled at runtime so this file never stores a literal that
// the repository secret scan must flag.
const dangerous = [
  "https://hooks.slack.com/services/T000/B000/abcdefghijklmnopqrstuvwx",
  "AuthKey_ABC1234567.p8",
  "/Users/runner/.appstoreconnect/private_keys",
  `${"-----BEGIN "}PRIVATE KEY-----\nMIIBOgIBAAJBAK\n-----END PRIVATE KEY-----`,
  `gh${"p"}_0123456789abcdef0123456789abcdef0123`,
  "device 00008120-000E4D8A0A88C01E",
  "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJhYmMifQ.c2lnbmF0dXJlLXZhbHVl",
];
for (const value of dangerous) {
  const sanitized = sanitizeText(`failed: ${value}`);
  assert.ok(sanitized.includes("[redacted]"), `expected redaction for: ${value.slice(0, 12)}`);
  for (const fragment of ["hooks.slack.com", "AuthKey_", "/Users/", "PRIVATE KEY", "ghp_", "00008120", "eyJhbGciOi"]) {
    assert.ok(!sanitized.includes(fragment), `leaked ${fragment}`);
  }
}
assert.equal(sanitizeText("multi\nline\r\nerror"), "multi line error");
assert.ok(sanitizeText("x".repeat(500)).length <= 300);

// Slack: statuses carry only the short revision and sanitized detail.
const failureMessage = buildStatusMessage({
  state: "failed",
  sha: CURRENT_SHA,
  version: "0.1.0",
  detail: "upload rejected using /Users/runner/.appstoreconnect/private_keys",
});
assert.ok(failureMessage.includes(CURRENT_SHA.slice(0, 12)));
assert.ok(!failureMessage.includes(CURRENT_SHA));
assert.ok(failureMessage.includes("[redacted]"));
assert.throws(() => buildStatusMessage({ state: "bogus", sha: CURRENT_SHA }));

// Slack: a webhook failure is reported, never thrown, and never echoes the URL.
const slackFailure = await postStatus({
  fetchImpl: async () => {
    throw new Error("connect ECONNREFUSED https://hooks.slack.com/services/T000/B000/xyz");
  },
  webhookUrl: "https://hooks.slack.com/services/T000/B000/xyz",
  channelId: "C0BSKKELMDL",
  state: "queued",
  sha: CURRENT_SHA,
});
assert.equal(slackFailure.posted, false);
assert.ok(!slackFailure.reason.includes("hooks.slack.com"));
assert.equal(
  (await postStatus({
    fetchImpl: async () => ({ ok: false, status: 500 }),
    webhookUrl: "https://hooks.slack.com/services/T000/B000/xyz",
    state: "queued",
    sha: CURRENT_SHA,
  })).posted,
  false,
);

const postedBodies = [];
assert.equal(
  (await postStatus({
    fetchImpl: async (_url, init) => {
      postedBodies.push(init.body);
      return { ok: true, status: 200 };
    },
    webhookUrl: "https://hooks.slack.com/services/T000/B000/xyz",
    channelId: "C0BSKKELMDL",
    state: "ready-for-testing",
    sha: CURRENT_SHA,
    buildNumber: "42",
  })).posted,
  true,
);
assert.ok(postedBodies[0].includes("C0BSKKELMDL"));

// App Store Connect polling: PROCESSING converges on a terminal state.
function buildsResponse(
  processingState,
  uploadedDate = "2026-08-25T12:00:00Z",
  version = "17",
) {
  return {
    ok: true,
    status: 200,
    json: async () => ({
      data: [
        {
          id: "1",
          attributes: { processingState, version, uploadedDate, expired: false },
        },
      ],
    }),
  };
}

const pollDefaults = { token: "token", appId: "1234567890", version: "0.1.0", buildNumber: "17" };

const pollDelays = [];
const states = ["PROCESSING", "PROCESSING", "VALID"];
let clock = Date.parse("2026-08-25T12:00:00Z");
const success = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => buildsResponse(states.shift()),
  uploadedAfter: Date.parse("2026-08-25T11:00:00Z"),
  now: () => clock,
  sleep: async (ms) => {
    pollDelays.push(ms);
    clock += ms;
  },
});
assert.deepEqual(
  { state: success.state, buildNumber: success.buildNumber, attempts: success.attempts },
  { state: "ready-for-testing", buildNumber: "17", attempts: 3 },
);
assert.ok(pollDelays[1] > pollDelays[0], "backoff must grow between polls");

// Polling: an invalid build is terminal and does not wait for the timeout.
const invalid = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => buildsResponse("INVALID"),
  uploadedAfter: 0,
  now: () => 0,
  sleep: async () => {},
});
assert.equal(invalid.state, "processing-invalid");

// Polling: stuck processing ends at the timeout instead of hanging.
let timeoutClock = 0;
const timedOut = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => buildsResponse("PROCESSING"),
  uploadedAfter: 0,
  timeoutMs: 60_000,
  initialDelayMs: 10_000,
  now: () => timeoutClock,
  sleep: async (ms) => {
    timeoutClock += ms;
  },
});
assert.equal(timedOut.state, "processing-timeout");
assert.equal(timedOut.timedOut, true);

// Polling: transient failures retry, and hard failures surface sanitized.
let transientCalls = 0;
const recovered = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => {
    transientCalls += 1;
    return transientCalls === 1 ? { ok: false, status: 503 } : buildsResponse("VALID");
  },
  uploadedAfter: 0,
  now: () => 0,
  sleep: async () => {},
});
assert.equal(recovered.state, "ready-for-testing");
assert.equal(recovered.transientFailures, 1);
await assert.rejects(
  pollProcessingState({
    ...pollDefaults,
    fetchImpl: async () => ({ ok: false, status: 401 }),
    uploadedAfter: 0,
    now: () => 0,
    sleep: async () => {},
  }),
  /status 401/u,
);

// Polling: builds uploaded before this promotion are ignored.
let oldBuildClock = 0;
const ignoresOldBuild = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => buildsResponse("VALID", "2026-08-25T10:00:00Z"),
  uploadedAfter: Date.parse("2026-08-25T11:00:00Z"),
  timeoutMs: 1000,
  initialDelayMs: 1000,
  now: () => oldBuildClock,
  sleep: async (ms) => {
    oldBuildClock += ms;
  },
});
assert.equal(ignoresOldBuild.state, "processing-timeout");

// Polling: another marketing-version build number is never mistaken for this
// upload, even when it is the newest build App Store Connect reports.
let otherBuildClock = 0;
const ignoresOtherBuild = await pollProcessingState({
  ...pollDefaults,
  fetchImpl: async () => buildsResponse("VALID", "2026-08-25T12:00:00Z", "18"),
  uploadedAfter: 0,
  timeoutMs: 1000,
  initialDelayMs: 1000,
  now: () => otherBuildClock,
  sleep: async (ms) => {
    otherBuildClock += ms;
  },
});
assert.equal(ignoresOtherBuild.state, "processing-timeout");
assert.equal(ignoresOtherBuild.buildNumber, "17");
await assert.rejects(
  pollProcessingState({ ...pollDefaults, buildNumber: "", fetchImpl: async () => buildsResponse("VALID") }),
  /build number/u,
);

// Token: identifiers are validated before any signing material is used.
assert.throws(() => createAscToken({ keyId: "bad id", issuerId: "x", privateKeyPem: "" }));
assert.throws(() =>
  createAscToken({ keyId: "ABC1234567", issuerId: "not-an-issuer", privateKeyPem: "" }),
);

// Orchestration: a successful promotion posts every lifecycle state.
function recorder() {
  const posted = [];
  return {
    posted,
    notify: async (status) => {
      posted.push(status);
      buildStatusMessage(status);
      return { posted: true, reason: null };
    },
  };
}

const successRecorder = recorder();
const evidenceWrites = [];
const polledFor = [];
const successRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0", runId: "987654321" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.1.0", buildNumber: "17" }),
    }),
    poll: async (request) => {
      polledFor.push(request);
      return {
        state: "ready-for-testing",
        processingState: "VALID",
        buildNumber: "17",
        attempts: 2,
        transientFailures: 0,
        timedOut: false,
      };
    },
    notify: successRecorder.notify,
    persistEvidence: async (evidence) => evidenceWrites.push(evidence),
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.deepEqual(
  successRecorder.posted.map((status) => status.state),
  ["queued", "archiving", "uploaded", "ready-for-testing"],
);
assert.equal(successRun.succeeded, true);
assert.equal(evidenceWrites.length, 1);
assert.equal(evidenceWrites[0].result.buildNumber, "17");
assert.equal(evidenceWrites[0].release.runId, "987654321");
assert.equal(evidenceWrites[0].physicalDeviceEvidence, "not-claimed");
// The archived build number, not "the latest build", drives the poll.
assert.equal(polledFor[0].buildNumber, "17");
assert.equal(
  successRecorder.posted.filter((status) => status.buildNumber === "17").length,
  2,
);

// Orchestration: an upload failure ends the lane with a sanitized failure.
const failureRecorder = recorder();
const failedRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 65,
      output: "xcodebuild: error using /Users/runner/.appstoreconnect/private_keys/AuthKey_ABC1234567.p8",
      buildFacts: async () => {
        throw new Error("build facts must not be read after a failed archive");
      },
    }),
    poll: async () => {
      throw new Error("polling must not run after an upload failure");
    },
    notify: failureRecorder.notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.deepEqual(
  failureRecorder.posted.map((status) => status.state),
  ["queued", "archiving", "failed"],
);
assert.equal(failedRun.succeeded, false);
const failureDetail = buildStatusMessage(failureRecorder.posted.at(-1));
assert.ok(!failureDetail.includes("AuthKey_"));
assert.ok(!failureDetail.includes("/Users/"));

// Orchestration: a Slack outage does not fail the promotion.
const flakySlackRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ buildNumber: "18" }),
    }),
    poll: async () => ({
      state: "ready-for-testing",
      processingState: "VALID",
      buildNumber: "18",
      attempts: 1,
      transientFailures: 0,
      timedOut: false,
    }),
    notify: async () => ({ posted: false, reason: "Slack responded with status 500" }),
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(flakySlackRun.succeeded, true);
assert.ok(flakySlackRun.statuses.every((status) => status.posted === false));

// Orchestration: a processing timeout is reported as a non-success terminal state.
const timeoutRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ buildNumber: "19" }),
    }),
    poll: async () => ({
      state: "processing-timeout",
      processingState: null,
      buildNumber: null,
      attempts: 9,
      transientFailures: 1,
      timedOut: true,
    }),
    notify: recorder().notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(timeoutRun.succeeded, false);
assert.equal(timeoutRun.evidence.processing.timedOut, true);
assert.equal(timeoutRun.evidence.processing.pollAttempts, 9);
assert.equal(timeoutRun.evidence.result.buildNumber, "19");

// Orchestration: an unidentifiable upload fails instead of polling blindly.
const unidentifiableRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => {
        throw new Error("The archived build number could not be recovered");
      },
    }),
    poll: async () => {
      throw new Error("polling must not run without an identified build");
    },
    notify: recorder().notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(unidentifiableRun.state, "failed");

// Evidence: sanitized, revision-scoped, and never claims device evidence.
const evidence = createEvidence({
  sha: CURRENT_SHA,
  state: "failed",
  version: "0.1.0",
  buildNumber: null,
  poll: null,
  detail: "failed reading /Users/runner/.appstoreconnect/private_keys",
  recordedAtUtc: "2026-08-25T12:00:00.000Z",
});
assert.equal(evidence.evidenceScope, "testflight-promotion");
assert.equal(evidence.release.sha, CURRENT_SHA);
assert.equal(evidence.result.succeeded, false);
assert.ok(!JSON.stringify(evidence).includes("/Users/"));
assert.throws(() => createEvidence({ sha: "short", state: "failed", recordedAtUtc: "now" }));

process.stdout.write("TestFlight promotion lane self-tests: PASS\n");
