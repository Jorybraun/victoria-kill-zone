import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";

import { pollProcessingState, createAscToken, createTokenProvider } from "./asc-client.mjs";
import {
  CI_WORKFLOW_FILE,
  CI_WORKFLOW_PATH,
  fetchCurrentMainSha,
  hasSuccessfulCiPushRun,
} from "./github-api.mjs";
import { createEvidence, runCommand, runPromotion } from "./promote-testflight.mjs";
import { decidePromotion, decideWithRemoteFacts } from "./promotion-gate.mjs";
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
  ciVerifiedForSha: true,
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

// Gate: manual dispatch may not bypass CI. Without a recorded successful CI
// push run for this exact revision, the signing runner is never queued.
const manualDispatch = {
  enabled: true,
  eventName: "workflow_dispatch",
  repository: REPOSITORY,
  candidateSha: CURRENT_SHA,
  currentMainSha: CURRENT_SHA,
};
assert.equal(decidePromotion(manualDispatch).reasonKey, "ciNotVerifiedForSha");
assert.equal(
  decidePromotion({ ...manualDispatch, ciVerifiedForSha: true }).reasonKey,
  "promote",
);
assert.equal(decidePromotion({ ...greenRun, ciVerifiedForSha: false }).reasonKey, "ciNotVerifiedForSha");

// Gate: currency and CI success come from the remote, not from the payload.
const remoteEnvironment = {
  VKZ_TESTFLIGHT_ENABLED: "true",
  VKZ_EVENT_NAME: "workflow_dispatch",
  VKZ_REPOSITORY: REPOSITORY,
  VKZ_CANDIDATE_SHA: CURRENT_SHA,
};
assert.equal(
  (
    await decideWithRemoteFacts(remoteEnvironment, {
      fetchCurrentMain: async () => CURRENT_SHA,
      verifyCi: async () => true,
    })
  ).reasonKey,
  "promote",
);
assert.equal(
  (
    await decideWithRemoteFacts(remoteEnvironment, {
      fetchCurrentMain: async () => CURRENT_SHA,
      verifyCi: async () => false,
    })
  ).reasonKey,
  "ciNotVerifiedForSha",
);
assert.equal(
  (
    await decideWithRemoteFacts(remoteEnvironment, {
      fetchCurrentMain: async () => STALE_SHA,
      verifyCi: async () => true,
    })
  ).reasonKey,
  "staleSha",
);
// A lookup failure fails closed rather than promoting on stale information.
assert.equal(
  (
    await decideWithRemoteFacts(remoteEnvironment, {
      fetchCurrentMain: async () => {
        throw new Error("GitHub request failed with status 502");
      },
      verifyCi: async () => true,
    })
  ).reasonKey,
  "remoteUnavailable",
);
assert.equal(
  (await decideWithRemoteFacts({ ...remoteEnvironment, VKZ_TESTFLIGHT_ENABLED: "false" }, {
    fetchCurrentMain: async () => {
      throw new Error("the disabled lane must not reach the network");
    },
    verifyCi: async () => true,
  })).reasonKey,
  "disabled",
);

// GitHub facts: only a completed successful CI push run on this repository's
// own main counts as proof for a revision.
const requestedUrls = [];
const runsFor = (runs) => async (url) => {
  requestedUrls.push(String(url));
  return { ok: true, status: 200, json: async () => ({ workflow_runs: runs }) };
};
const pushRun = {
  name: "CI",
  path: CI_WORKFLOW_PATH,
  event: "push",
  status: "completed",
  conclusion: "success",
  head_branch: "main",
  head_sha: CURRENT_SHA,
  repository: { full_name: REPOSITORY },
};
assert.equal(
  await hasSuccessfulCiPushRun({
    fetchImpl: runsFor([pushRun]),
    repository: REPOSITORY,
    sha: CURRENT_SHA,
    token: "t",
  }),
  true,
);
// The lookup is scoped to the canonical workflow file, not a display name.
assert.equal(
  requestedUrls[0],
  `https://api.github.com/repos/${REPOSITORY}/actions/workflows/${CI_WORKFLOW_FILE}/runs` +
    `?head_sha=${CURRENT_SHA}&event=push&status=success&branch=main&per_page=50`,
);
for (const rejected of [
  { ...pushRun, event: "pull_request" },
  // A look-alike workflow that merely calls itself "CI" cannot vouch for a
  // revision.
  { ...pushRun, path: ".github/workflows/vendor-ci.yml" },
  { ...pushRun, conclusion: "failure" },
  { ...pushRun, head_sha: STALE_SHA },
  { ...pushRun, repository: { full_name: "fork/victoria-kill-zone" } },
]) {
  assert.equal(
    await hasSuccessfulCiPushRun({
      fetchImpl: runsFor([rejected]),
      repository: REPOSITORY,
      sha: CURRENT_SHA,
      token: "t",
    }),
    false,
  );
}
assert.equal(
  await fetchCurrentMainSha({
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ sha: CURRENT_SHA }) }),
    repository: REPOSITORY,
    token: "t",
  }),
  CURRENT_SHA,
);
await assert.rejects(
  fetchCurrentMainSha({
    fetchImpl: async () => ({ ok: false, status: 502 }),
    repository: REPOSITORY,
    token: "t",
  }),
  /status 502/u,
);
// Without `actions: read` the runs endpoint answers 403, which must fail closed
// rather than read as "no CI run".
await assert.rejects(
  hasSuccessfulCiPushRun({
    fetchImpl: async () => ({ ok: false, status: 403 }),
    repository: REPOSITORY,
    sha: CURRENT_SHA,
    token: "t",
  }),
  /status 403/u,
);
assert.equal(
  (
    await decideWithRemoteFacts(remoteEnvironment, {
      fetchCurrentMain: async () => CURRENT_SHA,
      verifyCi: async () => {
        const error = new Error("GitHub request failed with status 403");
        throw error;
      },
    })
  ).reasonKey,
  "remoteUnavailable",
);
await assert.rejects(
  hasSuccessfulCiPushRun({
    fetchImpl: runsFor([pushRun]),
    repository: REPOSITORY,
    sha: CURRENT_SHA,
    token: "t",
    workflowFile: "../../etc/passwd",
  }),
  /workflow file/u,
);
assert.equal(
  await hasSuccessfulCiPushRun({
    fetchImpl: runsFor([]),
    repository: REPOSITORY,
    sha: CURRENT_SHA,
    token: "t",
  }),
  false,
);

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

const pollDefaults = {
  tokenProvider: () => "token",
  appId: "1234567890",
  version: "0.1.0",
  buildNumber: "17",
};

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
await assert.rejects(
  pollProcessingState({
    ...pollDefaults,
    tokenProvider: undefined,
    fetchImpl: async () => buildsResponse("VALID"),
  }),
  /token provider/u,
);

// Token: polling that outlives one 15-minute token keeps authenticating.
// Processing here takes 45 minutes of fake time and still reaches VALID.
const signingKey = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ format: "pem", type: "pkcs8" })
  .toString();
let tokenClock = Date.parse("2026-08-25T12:00:00Z");
const refreshingProvider = createTokenProvider({
  keyId: "ABC1234567",
  issuerId: "6a4b6dc0-0000-4000-8000-1c1d1e1f2021",
  privateKeyPem: signingKey,
  now: () => tokenClock,
});
const tokensSeen = new Set();
const longPollStates = ["PROCESSING", "PROCESSING", "PROCESSING", "VALID"];
const longPoll = await pollProcessingState({
  ...pollDefaults,
  tokenProvider: refreshingProvider,
  fetchImpl: async (_url, init) => {
    tokensSeen.add(init.headers.Authorization);
    return buildsResponse(longPollStates.shift() ?? "VALID");
  },
  uploadedAfter: Date.parse("2026-08-25T11:00:00Z"),
  timeoutMs: 60 * 60 * 1000,
  initialDelayMs: 15 * 60 * 1000,
  maxDelayMs: 15 * 60 * 1000,
  now: () => tokenClock,
  sleep: async (ms) => {
    tokenClock += ms;
  },
});
assert.equal(longPoll.state, "ready-for-testing");
assert.ok(tokensSeen.size > 1, "a fresh token must be minted before expiry");

// Command output: raw build output never reaches the log or the caller.
const emitted = [];
const leaky = await runCommand(
  "node",
  [
    "-e",
    [
      'console.log("using /Users/runner/.appstoreconnect/private_keys/AuthKey_ABC1234567.p8");',
      'console.log("posting to https://hooks.slack.com/services/T000/B000/abcdefghijklmnop");',
      'console.error("device 00008120-000E4D8A0A88C01E rejected token " + "gh" + "p_0123456789abcdef0123456789abcdef0123");',
      "process.exit(65);",
    ].join(""),
  ],
  { write: (line) => emitted.push(line) },
);
assert.equal(leaky.code, 65);
for (const sink of [emitted.join(""), leaky.output]) {
  for (const fragment of ["AuthKey_", "/Users/", "hooks.slack.com", "00008120", "ghp_"]) {
    assert.ok(!sink.includes(fragment), `leaked ${fragment} from build output`);
  }
  assert.ok(sink.includes("[redacted]"));
}

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
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.1.0", buildNumber: "18" }),
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
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.1.0", buildNumber: "19" }),
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

// Orchestration: an archive built from another revision never ships.
const wrongShaRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ sha: STALE_SHA, marketingVersion: "0.1.0", buildNumber: "20" }),
    }),
    poll: async () => {
      throw new Error("polling must not run for a foreign archive");
    },
    notify: recorder().notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(wrongShaRun.succeeded, false);
assert.equal(wrongShaRun.state, "failed");

// Orchestration: the archive's marketing version wins over a stale configured
// one, so polling, Slack, and evidence all describe the same release train.
const supersededRecorder = recorder();
const supersededPolls = [];
const supersededRun = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.2.0", buildNumber: "21" }),
    }),
    poll: async (request) => {
      supersededPolls.push(request);
      return {
        state: "ready-for-testing",
        processingState: "VALID",
        buildNumber: "21",
        attempts: 1,
        transientFailures: 0,
        timedOut: false,
      };
    },
    notify: supersededRecorder.notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(supersededPolls[0].version, "0.2.0");
assert.equal(supersededRun.evidence.result.version, "0.2.0");
assert.equal(supersededRecorder.posted.at(-1).version, "0.2.0");

// Orchestration: main moving on while the Mac job queued skips the promotion
// instead of shipping a superseded revision.
const staleRecorder = recorder();
const revalidatedStale = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    revalidate: async () => STALE_SHA,
    archiveAndUpload: async () => {
      throw new Error("archiving must not start for a superseded revision");
    },
    poll: async () => {
      throw new Error("polling must not run for a superseded revision");
    },
    notify: staleRecorder.notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.deepEqual(
  staleRecorder.posted.map((status) => status.state),
  ["queued", "skipped-stale"],
);
assert.equal(revalidatedStale.state, "skipped-stale");
// An unanswerable currency check fails closed rather than archiving blind.
const unknownCurrency = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    revalidate: async () => {
      throw new Error("GitHub request failed with status 502");
    },
    archiveAndUpload: async () => {
      throw new Error("archiving must not start without a currency check");
    },
    poll: async () => {
      throw new Error("unreachable");
    },
    notify: recorder().notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(unknownCurrency.state, "failed");
const revalidatedGood = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    revalidate: async () => CURRENT_SHA,
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.1.0", buildNumber: "22" }),
    }),
    poll: async () => ({
      state: "ready-for-testing",
      processingState: "VALID",
      buildNumber: "22",
      attempts: 1,
      transientFailures: 0,
      timedOut: false,
    }),
    notify: recorder().notify,
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(revalidatedGood.succeeded, true);

// Orchestration: an unrecorded promotion is not a success, and evidence
// failure never rewrites the promotion's own state.
const unrecordedRecorder = recorder();
const unrecordedSuccess = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({
      code: 0,
      output: "archive ok",
      buildFacts: async () => ({ sha: CURRENT_SHA, marketingVersion: "0.1.0", buildNumber: "23" }),
    }),
    poll: async () => ({
      state: "ready-for-testing",
      processingState: "VALID",
      buildNumber: "23",
      attempts: 1,
      transientFailures: 0,
      timedOut: false,
    }),
    notify: unrecordedRecorder.notify,
    persistEvidence: async () => {
      throw new Error("read-only file system");
    },
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
assert.equal(unrecordedSuccess.state, "ready-for-testing");
assert.equal(unrecordedSuccess.evidencePersisted, false);
assert.equal(unrecordedSuccess.succeeded, false);
// The channel must not be left claiming a release the lane cannot evidence:
// the last posted state is a failure, and no success was ever posted.
assert.equal(unrecordedRecorder.posted.at(-1).state, "failed");
assert.ok(
  unrecordedRecorder.posted.every((status) => status.state !== "ready-for-testing"),
);
assert.match(
  buildStatusMessage(unrecordedRecorder.posted.at(-1)),
  /ready-for-testing, but evidence could not be persisted/u,
);

const unrecordedFailure = await runPromotion({
  config: { sha: CURRENT_SHA, version: "0.1.0" },
  deps: {
    archiveAndUpload: async () => ({ code: 65, output: "archive failed" }),
    poll: async () => {
      throw new Error("unreachable");
    },
    notify: recorder().notify,
    persistEvidence: async () => {
      throw new Error("read-only file system");
    },
    now: () => new Date("2026-08-25T12:00:00Z"),
  },
});
// The original failure is still the reported state, not an evidence error.
assert.equal(unrecordedFailure.state, "failed");
assert.match(unrecordedFailure.evidence.result.detail, /archive or upload failed/u);
assert.equal(unrecordedFailure.succeeded, false);

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
