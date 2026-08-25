// Decides whether a green `main` revision may be promoted to TestFlight.
//
// The gate is fail-closed: promotion happens only when it is explicitly
// enabled, the triggering CI run succeeded on this repository's `main`, and
// the candidate revision is still the exact current `main` SHA. Stale
// revisions are skipped rather than queued, so a burst of merges promotes
// only the newest green revision.

import { appendFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const SHA_PATTERN = /^[0-9a-f]{40}$/u;

export const PROMOTION_DECISIONS = Object.freeze({
  disabled: "the TestFlight lane is disabled",
  forkedRepository: "the CI run came from another repository",
  notCiWorkflow: "the completed run was not the CI workflow",
  notMergeEvent: "the CI run was not a push to main",
  invalidCandidate: "the candidate revision is not a full commit SHA",
  invalidCurrent: "the current main revision is not a full commit SHA",
  notMain: "the CI run was not on main",
  ciNotSuccessful: "the CI run did not succeed",
  staleSha: "a newer main revision exists",
  unsupportedEvent: "the triggering event cannot promote",
  promote: "the exact current main revision is green",
});

function normalizeSha(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

export function decidePromotion(input) {
  const {
    enabled,
    eventName,
    ciWorkflowName,
    ciEvent,
    ciConclusion,
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
    if (ciWorkflowName !== "CI") {
      return decide("notCiWorkflow");
    }
    if (ciConclusion !== "success") {
      return decide("ciNotSuccessful");
    }
    // Only a merge to main promotes. A pull-request CI run is green against a
    // merge commit that does not exist on main.
    if (ciEvent !== "push") {
      return decide("notMergeEvent");
    }
    if (headBranch !== "main") {
      return decide("notMain");
    }
    if (headRepository !== repository) {
      return decide("forkedRepository");
    }
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
    ciWorkflowName: environment.VKZ_CI_WORKFLOW_NAME,
    ciEvent: environment.VKZ_CI_EVENT,
    ciConclusion: environment.VKZ_CI_CONCLUSION,
    headBranch: environment.VKZ_CI_HEAD_BRANCH,
    headRepository: environment.VKZ_CI_HEAD_REPOSITORY,
    repository: environment.VKZ_REPOSITORY,
    candidateSha: environment.VKZ_CANDIDATE_SHA,
    currentMainSha: environment.VKZ_CURRENT_MAIN_SHA,
  });
}

function isMainModule() {
  return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  const decision = decideFromEnvironment();
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
