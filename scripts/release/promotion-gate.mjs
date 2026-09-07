// Decides whether a green `main` revision may be promoted to TestFlight.
//
// The gate is fail-closed: promotion happens only when it is explicitly
// enabled, CI and deployment passed for this repository's `main`, and
// the candidate revision is still the exact current `main` SHA. Stale
// revisions are skipped rather than queued, so a burst of merges promotes
// only the newest green revision.

import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

import { fetchCurrentMainSha, hasSuccessfulCiPushRun } from "./github-api.mjs";
import { hasSuccessfulDeployment } from "./deployment-gate.mjs";

const SHA_PATTERN = /^[0-9a-f]{40}$/u;

export const PROMOTION_DECISIONS = Object.freeze({
  disabled: "the TestFlight lane is disabled",
  forkedRepository: "the deployment run came from another repository",
  notDeployWorkflow: "the completed run was not the Deploy workflow",
  notDeployEvent: "the deployment run was not an authorized deployment event",
  ciNotVerifiedForSha: "no successful CI push run is recorded for this revision",
  deployNotVerifiedForSha: "the latest deployment attempt has no successful deployment and smoke evidence for this revision",
  invalidCandidate: "the candidate revision is not a full commit SHA",
  invalidCurrent: "the current main revision is not a full commit SHA",
  notMain: "the deployment run was not on main",
  deployNotSuccessful: "the deployment run did not succeed",
  staleSha: "a newer main revision exists",
  unsupportedEvent: "the triggering event cannot promote",
  remoteUnavailable: "the remote promotion prerequisites could not be confirmed",
  promote: "the exact current main revision passed CI, deployment and smoke checks",
});

function normalizeSha(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

export function decidePromotion(input) {
  const {
    enabled,
    eventName,
    deployWorkflowName,
    deployEvent,
    deployConclusion,
    ciVerifiedForSha,
    deployVerifiedForSha,
    headBranch,
    headRepository,
    repository,
    candidateSha,
    currentMainSha,
  } = input;

  const candidate = normalizeSha(candidateSha);
  const current = normalizeSha(currentMainSha);

  const decide = (reasonKey) => ({
    promote: reasonKey === "promote",
    reasonKey,
    reason: PROMOTION_DECISIONS[reasonKey],
    sha: reasonKey === "promote" ? candidate : null,
  });

  if (enabled !== true) {
    return decide("disabled");
  }
  if (eventName !== "workflow_run" && eventName !== "workflow_dispatch") {
    return decide("unsupportedEvent");
  }
  if (!SHA_PATTERN.test(candidate)) {
    return decide("invalidCandidate");
  }
  if (!SHA_PATTERN.test(current)) {
    return decide("invalidCurrent");
  }
  if (eventName === "workflow_run") {
    if (deployWorkflowName !== "Deploy") {
      return decide("notDeployWorkflow");
    }
    if (deployConclusion !== "success") {
      return decide("deployNotSuccessful");
    }
    // Deploy follows CI or an explicit main dispatch; CI is verified separately.
    if (!["workflow_run", "workflow_dispatch"].includes(deployEvent)) {
      return decide("notDeployEvent");
    }
    if (headBranch !== "main") {
      return decide("notMain");
    }
    if (headRepository !== repository) {
      return decide("forkedRepository");
    }
  }
  // Manual dispatch may not skip CI: the revision itself must have a recorded
  // successful CI push run.
  if (ciVerifiedForSha !== true) {
    return decide("ciNotVerifiedForSha");
  }
  if (deployVerifiedForSha !== true) {
    return decide("deployNotVerifiedForSha");
  }
  if (candidate !== current) {
    return decide("staleSha");
  }

  return decide("promote");
}

export function decideFromEnvironment(environment = process.env) {
  return decidePromotion({
    enabled: environment.VKZ_TESTFLIGHT_ENABLED === "true",
    eventName: environment.VKZ_EVENT_NAME,
    deployWorkflowName: environment.VKZ_DEPLOY_WORKFLOW_NAME,
    deployEvent: environment.VKZ_DEPLOY_EVENT,
    deployConclusion: environment.VKZ_DEPLOY_CONCLUSION,
    ciVerifiedForSha: environment.VKZ_CI_VERIFIED_FOR_SHA === "true",
    deployVerifiedForSha: environment.VKZ_DEPLOY_VERIFIED_FOR_SHA === "true",
    headBranch: environment.VKZ_DEPLOY_HEAD_BRANCH,
    headRepository: environment.VKZ_DEPLOY_HEAD_REPOSITORY,
    repository: environment.VKZ_REPOSITORY,
    candidateSha: environment.VKZ_CANDIDATE_SHA,
    currentMainSha: environment.VKZ_CURRENT_MAIN_SHA,
  });
}

// Current main, CI and deployment evidence come from the remote.
// Any lookup failure fails closed, including on manual dispatch.
export async function decideWithRemoteFacts(environment = process.env, deps = {}) {
  const {
    fetchCurrentMain = fetchCurrentMainSha,
    verifyCi = hasSuccessfulCiPushRun,
    verifyDeployment = hasSuccessfulDeployment,
  } = deps;

  if (environment.VKZ_TESTFLIGHT_ENABLED !== "true") {
    return decidePromotion({ enabled: false });
  }

  const repository = environment.VKZ_REPOSITORY ?? "";
  const token = environment.VKZ_GITHUB_TOKEN ?? "";
  let candidateSha = environment.VKZ_CANDIDATE_SHA ?? "";

  let currentMainSha;
  let ciVerifiedForSha;
  let deployVerifiedForSha;
  try {
    currentMainSha = await fetchCurrentMain({ repository, token });
    // A chained run's head_sha is context, not proof of its checked-out release.
    // Automatic promotion targets current main only when this triggering Deploy
    // attempt produced evidence for that exact SHA.
    if (environment.VKZ_EVENT_NAME === "workflow_run") candidateSha = currentMainSha;
    [ciVerifiedForSha, deployVerifiedForSha] = await Promise.all([
      verifyCi({ repository, sha: candidateSha, token }),
      verifyDeployment({ repository, sha: candidateSha, token,
        ...(environment.VKZ_EVENT_NAME === "workflow_run" ? {
          triggerRunId: environment.VKZ_DEPLOY_RUN_ID ?? "",
          triggerRunAttempt: environment.VKZ_DEPLOY_RUN_ATTEMPT ?? "",
        } : {}),
      }),
    ]);
  } catch {
    return {
      promote: false,
      reasonKey: "remoteUnavailable",
      reason: PROMOTION_DECISIONS.remoteUnavailable,
      sha: null,
    };
  }

  return decidePromotion({
    enabled: true,
    eventName: environment.VKZ_EVENT_NAME,
    deployWorkflowName: environment.VKZ_DEPLOY_WORKFLOW_NAME,
    deployEvent: environment.VKZ_DEPLOY_EVENT,
    deployConclusion: environment.VKZ_DEPLOY_CONCLUSION,
    ciVerifiedForSha,
    deployVerifiedForSha,
    headBranch: environment.VKZ_DEPLOY_HEAD_BRANCH,
    headRepository: environment.VKZ_DEPLOY_HEAD_REPOSITORY,
    repository,
    candidateSha,
    currentMainSha,
  });
}

// Recheck the same prerequisites on the Outpost immediately before archiving.
// Return a changed SHA so the existing stale-candidate path can skip cleanly.
export async function revalidatePromotion({ repository, sha, token }, deps = {}) {
  const { fetchCurrentMain = fetchCurrentMainSha, verifyCi = hasSuccessfulCiPushRun,
    verifyDeployment = hasSuccessfulDeployment } = deps;
  const current = await fetchCurrentMain({ repository, token });
  if (normalizeSha(current) !== normalizeSha(sha)) return current;
  const [ci, deployed] = await Promise.all([
    verifyCi({ repository, sha, token }), verifyDeployment({ repository, sha, token }),
  ]);
  if (ci !== true || deployed !== true) {
    throw new Error("The candidate no longer has verified CI, deployment and smoke evidence");
  }
  return current;
}

function isMainModule() {
  return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  const decision = await decideWithRemoteFacts();
  const outputPath = process.env.GITHUB_OUTPUT;
  if (outputPath) {
    await appendFile(
      outputPath,
      `promote=${decision.promote}\nreason_key=${decision.reasonKey}\nsha=${decision.sha ?? ""}\n`,
      "utf8",
    );
  }
  process.stdout.write(`Promotion gate: ${decision.promote ? "PROMOTE" : "SKIP"} — ${decision.reason}\n`);
}
