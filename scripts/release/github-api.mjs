// Authoritative GitHub queries used by the promotion lane.
//
// Both halves of the lane need facts that only the remote can answer: what
// `main` points at right now, and whether a specific revision has a successful
// CI push run. Neither answer may come from the workflow payload alone, because
// the payload describes the moment the run was queued.

const API_ROOT = "https://api.github.com";
const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
// The canonical CI definition. A display name is not an identity: any workflow
// file in the repository may call itself "CI".
export const CI_WORKFLOW_FILE = "ci.yml";
export const CI_WORKFLOW_PATH = `.github/workflows/${CI_WORKFLOW_FILE}`;

export async function requestGitHub({ fetchImpl, token, path }) {
  if (!REPOSITORY_PATTERN.test(String(path.repository))) {
    throw new Error("Invalid repository");
  }
  const response = await fetchImpl(`${API_ROOT}${path.suffix}`, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub request failed with status ${response.status}`);
  }
  return response.json();
}

export async function fetchCurrentMainSha({
  fetchImpl = globalThis.fetch,
  repository,
  token,
}) {
  const payload = await requestGitHub({
    fetchImpl,
    token,
    path: { repository, suffix: `/repos/${repository}/commits/main` },
  });
  const sha = String(payload?.sha ?? "").toLowerCase();
  if (!SHA_PATTERN.test(sha)) {
    throw new Error("The current main revision could not be resolved");
  }
  return sha;
}

// A green pull-request run does not count: it describes a merge commit that is
// not on main. Requires the `actions: read` permission.
export async function hasSuccessfulCiPushRun({
  fetchImpl = globalThis.fetch,
  repository,
  sha,
  token,
  workflowFile = CI_WORKFLOW_FILE,
}) {
  const candidate = String(sha ?? "").toLowerCase();
  if (!SHA_PATTERN.test(candidate)) {
    throw new Error("The candidate revision is not a full commit SHA");
  }

  const query = new URLSearchParams({
    head_sha: candidate,
    event: "push",
    status: "success",
    branch: "main",
    per_page: "50",
  });
  if (!/^[a-z0-9_.-]+\.ya?ml$/u.test(String(workflowFile))) {
    throw new Error("Invalid workflow file");
  }

  // Scoped to the workflow file, so a look-alike workflow named "CI" cannot
  // vouch for a revision.
  const payload = await requestGitHub({
    fetchImpl,
    token,
    path: {
      repository,
      suffix: `/repos/${repository}/actions/workflows/${workflowFile}/runs?${query.toString()}`,
    },
  });

  const runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
  return runs.some(
    (run) =>
      run?.path === `.github/workflows/${workflowFile}` &&
      run?.event === "push" &&
      run?.status === "completed" &&
      run?.conclusion === "success" &&
      run?.head_branch === "main" &&
      String(run?.head_sha ?? "").toLowerCase() === candidate &&
      run?.repository?.full_name === repository,
  );
}

// The first canonical push run anchors this commit's deployment history. CI
// has a direct head_sha identity; reruns retain the original creation time.
// Include unsuccessful CI attempts so a later successful rerun cannot move
// the boundary past an earlier deployment attempt for the same commit.
export async function fetchCiPushHistoryStart({ fetchImpl = globalThis.fetch, repository, sha, token }) {
  const candidate = String(sha ?? "").toLowerCase();
  if (!SHA_PATTERN.test(candidate)) throw new Error("Invalid CI history candidate SHA");
  const dates = [];
  let expectedTotal;
  const seen = new Set();
  for (let page = 1; page <= 10; page += 1) {
    const query = new URLSearchParams({ head_sha: candidate, event: "push", branch: "main", per_page: "100", page: String(page) });
    const payload = await requestGitHub({ fetchImpl, token, path: { repository,
      suffix: `/repos/${repository}/actions/workflows/${CI_WORKFLOW_FILE}/runs?${query.toString()}` } });
    if (!Array.isArray(payload?.workflow_runs) || !Number.isInteger(payload.total_count) ||
        payload.total_count < 0 || payload.total_count > 1000) throw new Error("Candidate CI history is incomplete");
    expectedTotal ??= payload.total_count;
    if (expectedTotal !== payload.total_count) throw new Error("Candidate CI history changed during verification");
    for (const run of payload.workflow_runs) {
      if (seen.has(run?.id) || !Number.isSafeInteger(run?.id) || run.id <= 0 ||
          run.path !== CI_WORKFLOW_PATH || run.event !== "push" || run.head_branch !== "main" ||
          run.head_sha !== candidate || run.repository?.full_name !== repository ||
          !Number.isFinite(Date.parse(run.created_at))) throw new Error("Invalid candidate CI history");
      seen.add(run.id);
      dates.push(Date.parse(run.created_at));
    }
    if (dates.length === expectedTotal) return dates.length ? new Date(Math.min(...dates)).toISOString() : null;
    if (dates.length > expectedTotal || payload.workflow_runs.length === 0) break;
  }
  throw new Error("Candidate CI history is incomplete");
}
