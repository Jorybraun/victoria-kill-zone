import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

function requiredEnvironment(name, environment) {
  const value = environment[name];
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function requireSingleLine(value, label) {
  if (value.length > 512 || /[\r\n\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

function requireDigits(value, label) {
  if (!/^[1-9][0-9]*$/u.test(value)) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

export function createEvidence(environment, now = new Date()) {
  const releaseSha = requiredEnvironment("VKZ_RELEASE_SHA", environment).toLowerCase();
  if (!/^[0-9a-f]{40}$/u.test(releaseSha)) {
    throw new Error("Invalid release SHA");
  }

  const releaseEnvironment = requiredEnvironment(
    "VKZ_RELEASE_ENVIRONMENT",
    environment,
  );
  if (!/^[a-z][a-z0-9-]{0,31}$/u.test(releaseEnvironment)) {
    throw new Error("Invalid release environment");
  }

  const sourceRunId = environment.VKZ_SOURCE_RUN_ID || null;
  if (sourceRunId !== null) {
    requireDigits(sourceRunId, "source workflow run ID");
  }

  const workflowName = requireSingleLine(
    requiredEnvironment("GITHUB_WORKFLOW", environment),
    "workflow name",
  );
  const workflowRef = requireSingleLine(
    requiredEnvironment("GITHUB_WORKFLOW_REF", environment),
    "workflow ref",
  );
  const pagesArtifactId = requireDigits(
    requiredEnvironment("VKZ_PAGES_ARTIFACT_ID", environment),
    "Pages artifact ID",
  );

  let combatWorker = null;
  const combatWorkerJson = environment.VKZ_COMBAT_WORKER_VERSION;
  if (combatWorkerJson !== undefined && combatWorkerJson !== "") {
    let parsed;
    try { parsed = JSON.parse(combatWorkerJson); } catch { throw new Error("Invalid combat worker evidence"); }
    if (parsed?.status === "not-configured") {
      combatWorker = { status: "not-configured" };
    } else {
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("Invalid combat worker evidence");
      }
      const nullableText = (value) => (value === null ||
        (typeof value === "string" && value.length > 0 && value.length <= 128 &&
         !/[\r\n\u0000-\u001f\u007f]/u.test(value)) ? value : undefined);
      if (!Number.isSafeInteger(parsed.protocolVersion) || parsed.protocolVersion < 1 ||
          nullableText(parsed.versionId) === undefined || nullableText(parsed.versionTag) === undefined ||
          nullableText(parsed.workerVersionTag) === undefined || nullableText(parsed.releaseSha) === undefined ||
          nullableText(parsed.doMigrationTag) === undefined) {
        throw new Error("Invalid combat worker evidence");
      }
      combatWorker = {
        versionId: parsed.versionId,
        versionTag: parsed.versionTag,
        workerVersionTag: parsed.workerVersionTag,
        releaseSha: parsed.releaseSha,
        protocolVersion: parsed.protocolVersion,
        doMigrationTag: parsed.doMigrationTag,
      };
    }
  }

  if (Number.isNaN(now.getTime())) {
    throw new Error("Invalid evidence time");
  }

  return {
    schemaVersion: 1,
    evidenceScope: "deployment-smoke",
    release: {
      sha: releaseSha,
      environment: releaseEnvironment,
      recordedAtUtc: now.toISOString(),
    },
    workflow: {
      name: workflowName,
      ref: workflowRef,
      runId: requireDigits(
        requiredEnvironment("GITHUB_RUN_ID", environment),
        "workflow run ID",
      ),
      runAttempt: requireDigits(
        requiredEnvironment("GITHUB_RUN_ATTEMPT", environment),
        "workflow run attempt",
      ),
      sourceRunId,
    },
    deploymentIdentifiers: {
      convexAuditMessage: `GitHub Actions ${releaseSha}`,
      pagesBuildVersion: releaseSha,
      pagesArtifactId,
      pagesEnvironment: "github-pages",
    },
    combatWorker,
    smokeResults: {
      convexSpectatorSnapshotUnknownCode: {
        status: "passed",
        expectedResult: "null",
      },
      pagesHttp: {
        status: "passed",
        expectedStatus: "2xx",
      },
    },
  };
}

export async function writeEvidence(environment = process.env, now = new Date()) {
  const outputPath = requiredEnvironment("VKZ_EVIDENCE_PATH", environment);
  const evidence = createEvidence(environment, now);
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

function isMainModule() {
  return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  try {
    await writeEvidence();
    process.stdout.write("Sanitized release evidence: CREATED\n");
  } catch {
    process.stderr.write("ERROR: release evidence creation failed.\n");
    process.exitCode = 1;
  }
}
