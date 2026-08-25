// Authoritative GitHub queries used by the promotion lane.
//
// Both halves of the lane need facts that only the remote can answer: what
// `main` points at right now, and whether a specific revision has a successful
// CI push run. Neither answer may come from the workflow payload alone, because
// the payload describes the moment the run was queued.

const API_ROOT = "https://api.github.com";
const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;

async function request({ fetchImpl, token, path }) {
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
  const payload = await request({
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
// not on main.
export async function hasSuccessfulCiPushRun({
  fetchImpl = globalThis.fetch,
  repository,
  sha,
  token,
  workflowName = "CI",
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
  const payload = await request({
    fetchImpl,
    token,
    path: {
      repository,
      suffix: `/repos/${repository}/actions/runs?${query.toString()}`,
    },
  });

  const runs = Array.isArray(payload?.workflow_runs) ? payload.workflow_runs : [];
  return runs.some(
    (run) =>
      run?.name === workflowName &&
      run?.event === "push" &&
      run?.status === "completed" &&
      run?.conclusion === "success" &&
      run?.head_branch === "main" &&
      String(run?.head_sha ?? "").toLowerCase() === candidate &&
      run?.repository?.full_name === repository,
  );
}
