// Prove the latest production deployment attempt actually deployed and smoked
// this SHA. A successful workflow with skipped jobs is not deployment evidence.
import { fetchCiPushHistoryStart, requestGitHub } from "./github-api.mjs";

export const DEPLOY_WORKFLOW_FILE = "deploy.yml";
export const DEPLOY_WORKFLOW_PATH = `.github/workflows/${DEPLOY_WORKFLOW_FILE}`;
const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const ID_PATTERN = /^[1-9][0-9]*$/u;
const REQUIRED_STEPS = new Map([
  ["Revalidate fast gate", ["Verify workspace"]],
  ["Revalidate iOS gate", ["Verify iOS"]],
  ["Build production release", [
    "Deploy Convex and build spectator",
    "Smoke the sanitized production spectator query",
    "Upload spectator artifact",
  ]],
  ["Deploy spectator to Pages", [
    "Deploy GitHub Pages artifact",
    "Smoke the deployed spectator page",
    "Create sanitized release evidence",
    "Upload sanitized release evidence",
  ]],
]);

// Rerunning an older run keeps its ID and creation time. Include the current
// attempt's start time when selecting the latest attempt, including failures.
function attemptTime(run) {
  return Math.max(Date.parse(run.created_at), Date.parse(run.run_started_at ?? run.created_at));
}

function completedSuccessfully(value) {
  return value?.status === "completed" && value?.conclusion === "success";
}

export async function hasSuccessfulDeployment({
  fetchImpl = globalThis.fetch, repository, sha, token,
  triggerRunId, triggerRunAttempt,
}) {
  const candidate = String(sha ?? "").toLowerCase();
  if (!SHA_PATTERN.test(candidate)) throw new Error("Invalid deployment candidate SHA");
  if (triggerRunId !== undefined && (!ID_PATTERN.test(String(triggerRunId)) ||
      !ID_PATTERN.test(String(triggerRunAttempt)))) {
    throw new Error("Invalid triggering deployment attempt");
  }
  const get = (suffix) => requestGitHub({
    fetchImpl, token, path: { repository, suffix: `/repos/${repository}${suffix}` },
  });
  const historyStart = await fetchCiPushHistoryStart({ fetchImpl, repository, sha: candidate, token });
  if (historyStart === null) return false;
  const runTitle = `Deploy ${candidate}`;

  // Only inspect this commit's CI era, not the repository's lifetime. Names
  // bind queued/failed runs to the same actual SHA used by Deploy's checkout.
  // Do not filter by success or chained head_sha: both can conceal failures.
  // Enumerate this bounded window fully, retaining old run IDs that were rerun.
  const runs = [];
  let expectedTotal;
  const seenIds = new Set();
  for (let page = 1; page <= 10; page += 1) {
    const query = new URLSearchParams({ branch: "main", created: `>=${historyStart}`, per_page: "100", page: String(page) });
    const payload = await get(`/actions/workflows/${DEPLOY_WORKFLOW_FILE}/runs?${query.toString()}`);
    if (!Array.isArray(payload?.workflow_runs) || !Number.isInteger(payload.total_count) ||
        payload.total_count < 0 || payload.total_count > 1000) {
      throw new Error("Candidate deployment history could not be verified completely");
    }
    expectedTotal ??= payload.total_count;
    if (payload.total_count !== expectedTotal || payload.workflow_runs.some(run => seenIds.has(run?.id))) {
      throw new Error("Deployment history changed during verification");
    }
    for (const run of payload.workflow_runs) seenIds.add(run?.id);
    runs.push(...payload.workflow_runs);
    if (runs.length > expectedTotal || seenIds.size !== runs.length) {
      throw new Error("Deployment history is inconsistent");
    }
    if (runs.length === expectedTotal) break;
    if (payload.workflow_runs.length === 0 || page === 10) {
      throw new Error("Deployment history is incomplete");
    }
  }
  const candidateRuns = runs.filter(run => run?.display_title === runTitle);
  if (candidateRuns.length === 0) return false;
  if (candidateRuns.some(run => run?.path !== DEPLOY_WORKFLOW_PATH ||
      run?.repository?.full_name !== repository || run?.head_branch !== "main" ||
      !["workflow_run", "workflow_dispatch"].includes(run?.event) ||
      !ID_PATTERN.test(String(run?.id)) || !Number.isFinite(attemptTime(run)) ||
      !Number.isFinite(Date.parse(run.updated_at)) ||
      Date.parse(run.created_at) < Date.parse(historyStart))) return false;
  // A queued rerun of an old ID may not have a fresh start timestamp yet.
  if (candidateRuns.some(run => run.status !== "completed")) return false;
  candidateRuns.sort((a, b) => attemptTime(b) - attemptTime(a) || Number(b.id) - Number(a.id));
  // Completion time must never rank an older success ahead of a newer failed
  // attempt. If an old-ID rerun has an ambiguous start timestamp, stop instead
  // of assuming a later updated_at means it is the successful latest attempt.
  if (candidateRuns.slice(1).some(run => run.run_attempt > 1 &&
      Date.parse(run.updated_at) > attemptTime(candidateRuns[0]))) return false;

  // Refresh the chosen run: a rerun may have started since the history read.
  const run = await get(`/actions/runs/${candidateRuns[0].id}`);
  if (run?.id !== candidateRuns[0].id || run?.path !== DEPLOY_WORKFLOW_PATH || run?.display_title !== runTitle ||
      run?.repository?.full_name !== repository || run?.head_repository?.full_name !== repository ||
      run?.head_branch !== "main" || !["workflow_run", "workflow_dispatch"].includes(run?.event) ||
      !ID_PATTERN.test(String(run?.run_attempt)) || !completedSuccessfully(run)) return false;
  if (triggerRunId !== undefined && (String(run.id) !== String(triggerRunId) ||
      String(run.run_attempt) !== String(triggerRunAttempt))) return false;

  const [jobPayload, artifactPayload] = await Promise.all([
    get(`/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`),
    get(`/actions/runs/${run.id}/artifacts?per_page=100`),
  ]);
  const jobs = jobPayload?.jobs;
  const artifacts = artifactPayload?.artifacts;
  if (!Array.isArray(jobs) || jobPayload.total_count !== jobs.length ||
      !Array.isArray(artifacts) || artifactPayload.total_count !== artifacts.length) return false;
  for (const [name, stepNames] of REQUIRED_STEPS) {
    const matchingJobs = jobs.filter(job => job.name === name);
    if (matchingJobs.length !== 1 || !completedSuccessfully(matchingJobs[0])) return false;
    const job = matchingJobs[0];
    if (job.run_attempt !== run.run_attempt || !Array.isArray(job.steps)) return false;
    for (const stepName of stepNames) {
      const steps = job.steps.filter(step => step.name === stepName);
      if (steps.length !== 1 || !completedSuccessfully(steps[0])) return false;
    }
  }

  const upload = jobs.find(job => job.name === "Deploy spectator to Pages")
    .steps.find(step => step.name === "Upload sanitized release evidence");
  const started = Date.parse(upload.started_at), completed = Date.parse(upload.completed_at);
  if (!Number.isFinite(started) || !Number.isFinite(completed) || completed < started) return false;
  // This canonical workflow names evidence from its actual deployment SHA and
  // uploads it only after both smokes. Bind artifact creation to the current
  // attempt's upload step; evidence surviving an earlier rerun cannot qualify.
  const evidence = artifacts.filter(artifact => artifact.name === `release-evidence-${candidate}` &&
    artifact.expired === false && artifact.size_in_bytes > 0 && Date.parse(artifact.created_at) >= started &&
    Date.parse(artifact.created_at) <= completed);
  if (evidence.length !== 1) return false;
  const refreshed = await get(`/actions/runs/${run.id}`);
  return refreshed?.run_attempt === run.run_attempt && completedSuccessfully(refreshed);
}
