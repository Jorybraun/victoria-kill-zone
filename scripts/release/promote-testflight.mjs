// Orchestrates one TestFlight promotion on the persistent Mac Outpost runner.
//
// The lane archives and signs the promoted revision, uploads it, polls App
// Store Connect to a terminal processing state, posts sanitized status to the
// release channel, and writes sanitized machine-readable evidence. Slack and
// evidence failures never mask the promotion result.

import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

import {
  createTokenProvider,
  pollProcessingState,
  readPrivateKey,
  resolveAppId,
} from "./asc-client.mjs";
import { fetchCurrentMainSha } from "./github-api.mjs";
import { postStatus } from "./slack-notify.mjs";
import { sanitizeText } from "./redact.mjs";

const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const VERSION_PATTERN = /^[0-9]+(\.[0-9]+){0,3}$/u;
const SUCCESS_STATE = "ready-for-testing";
const SKIPPED_STATE = "skipped-stale";

export function createEvidence({
  sha,
  state,
  version,
  buildNumber,
  runId,
  poll,
  detail,
  recordedAtUtc,
}) {
  if (!SHA_PATTERN.test(String(sha ?? ""))) {
    throw new Error("The promoted revision is not a full commit SHA");
  }

  return {
    schemaVersion: 1,
    evidenceScope: "testflight-promotion",
    release: {
      sha,
      recordedAtUtc,
      runId: runId ? sanitizeText(runId, 32) : null,
      lane: "mac-outpost-self-hosted",
    },
    result: {
      state,
      succeeded: state === SUCCESS_STATE,
      version: version ? sanitizeText(version, 32) : null,
      buildNumber: buildNumber ? sanitizeText(buildNumber, 32) : null,
      detail: detail ? sanitizeText(detail) : null,
    },
    processing: {
      processingState: poll?.processingState ?? null,
      uploadedDate: poll?.uploadedDate ?? null,
      pollAttempts: poll?.attempts ?? 0,
      transientFailures: poll?.transientFailures ?? 0,
      timedOut: Boolean(poll?.timedOut),
    },
    // Tier 2 stays open until OTA installation is observed on both phones.
    physicalDeviceEvidence: "not-claimed",
  };
}

// Build output reaches the workflow log only after redaction: xcodebuild and
// altool echo key paths, tokens, and device identifiers on failure, and a
// workflow log is readable by anyone who can read the repository.
export function runCommand(command, args, { cwd, env, write } = {}) {
  const emit = write ?? ((line) => process.stdout.write(line));

  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    let pending = "";

    const flush = (final) => {
      const lines = pending.split("\n");
      pending = final ? "" : lines.pop() ?? "";
      for (const line of lines) {
        if (line.trim()) {
          emit(`${sanitizeText(line)}\n`);
        }
      }
      if (final && pending.trim()) {
        emit(`${sanitizeText(pending)}\n`);
      }
    };

    const consume = (chunk) => {
      const text = String(chunk);
      output += text;
      pending += text;
      flush(false);
    };

    child.stdout.on("data", consume);
    child.stderr.on("data", consume);
    child.on("error", (error) => resolve({ code: 1, output: String(error.message) }));
    child.on("close", (code) => {
      flush(true);
      // The retained output is sanitized as well, so no caller can leak it.
      resolve({ code: code ?? 1, output: sanitizeOutput(output) });
    });
  });
}

function sanitizeOutput(output) {
  return String(output ?? "")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => sanitizeText(line))
    .join("\n");
}

function lastLine(output) {
  const lines = String(output ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  return lines.at(-1) ?? "no output";
}

export async function readBuildFacts(path) {
  const facts = JSON.parse(await readFile(path, "utf8"));
  if (!VERSION_PATTERN.test(String(facts.buildNumber ?? ""))) {
    throw new Error("The archived build number could not be recovered");
  }
  if (!VERSION_PATTERN.test(String(facts.marketingVersion ?? ""))) {
    throw new Error("The archived marketing version could not be recovered");
  }
  return facts;
}

// The archive is the authority on what was uploaded. A configured marketing
// version that disagrees with it would send polling, Slack, and evidence at a
// different release train.
function reconcileFacts({ facts, sha, configuredVersion }) {
  if (String(facts.sha ?? "").toLowerCase() !== sha) {
    throw new Error("The archive was built from a different revision");
  }
  const version = String(facts.marketingVersion);
  return {
    version,
    buildNumber: String(facts.buildNumber),
    versionOverridden: Boolean(configuredVersion) && configuredVersion !== version,
  };
}

export async function runPromotion({ config, deps }) {
  const {
    archiveAndUpload,
    poll,
    revalidate,
    notify = postStatus,
    persistEvidence,
    now = () => new Date(),
  } = deps;

  const { sha, version: configuredVersion, runId = null } = config;
  let version = configuredVersion;
  const statuses = [];

  const announce = async (state, extra = {}) => {
    const result = await notify({ state, sha, version, ...extra });
    statuses.push({ state, posted: result.posted });
    if (!result.posted) {
      process.stdout.write(
        `Slack status not delivered (${sanitizeText(result.reason ?? "unknown")}); continuing.\n`,
      );
    }
    return result;
  };

  const finish = async (state, { detail = null, buildNumber = null, pollResult = null } = {}) => {
    const evidence = createEvidence({
      sha,
      state,
      version,
      buildNumber,
      runId,
      poll: pollResult,
      detail,
      recordedAtUtc: now().toISOString(),
    });

    // Evidence is a gate, not a courtesy: an unrecorded promotion cannot be
    // audited, so it does not count as a success. Persisting happens before the
    // terminal status is posted, so the channel never ends on a success the
    // lane cannot evidence.
    let evidencePersisted = true;
    let evidenceError = null;
    if (persistEvidence) {
      try {
        await persistEvidence(evidence);
      } catch (error) {
        evidencePersisted = false;
        evidenceError = sanitizeText(error.message);
        process.stdout.write(`Evidence not persisted (${evidenceError}).\n`);
      }
    }

    if (evidencePersisted) {
      await announce(state, { detail, buildNumber });
    } else {
      // The Apple outcome is preserved in the returned and recorded state; the
      // channel is told the lane failed, because an unaudited promotion is not
      // a promotion anyone may act on.
      await announce("failed", {
        buildNumber,
        detail: `App Store Connect outcome ${state}, but evidence could not be persisted: ${evidenceError}`,
      });
    }

    return {
      state,
      succeeded: (state === SUCCESS_STATE || state === SKIPPED_STATE) && evidencePersisted,
      evidencePersisted,
      evidence,
      statuses,
    };
  };

  await announce("queued");

  // The hosted gate ran earlier; main can have moved on while this job queued
  // for the Outpost runner.
  if (revalidate) {
    let currentMainSha;
    try {
      currentMainSha = await revalidate();
    } catch (error) {
      return finish("failed", {
        detail: `current main could not be confirmed: ${sanitizeText(error.message)}`,
      });
    }
    if (String(currentMainSha).toLowerCase() !== sha) {
      return finish(SKIPPED_STATE, { detail: "a newer main revision exists" });
    }
  }

  await announce("archiving");

  const startedAt = now().getTime();
  const upload = await archiveAndUpload();
  if (upload.code !== 0) {
    return finish("failed", { detail: `archive or upload failed: ${lastLine(upload.output)}` });
  }

  // The uploaded artifact is identified by the build number that was actually
  // archived, not by whichever build App Store Connect saw most recently.
  let uploadedBuildNumber;
  try {
    const reconciled = reconcileFacts({
      facts: await upload.buildFacts(),
      sha,
      configuredVersion,
    });
    uploadedBuildNumber = reconciled.buildNumber;
    version = reconciled.version;
    if (reconciled.versionOverridden) {
      process.stdout.write(
        `Configured marketing version ${sanitizeText(configuredVersion, 32)} superseded by archived ${sanitizeText(version, 32)}.\n`,
      );
    }
  } catch (error) {
    return finish("failed", {
      detail: `uploaded build could not be identified: ${sanitizeText(error.message)}`,
    });
  }

  await announce("uploaded", { buildNumber: uploadedBuildNumber });

  let pollResult;
  try {
    pollResult = await poll({
      version,
      buildNumber: uploadedBuildNumber,
      uploadedAfter: startedAt - 60 * 1000,
    });
  } catch (error) {
    return finish("failed", {
      buildNumber: uploadedBuildNumber,
      detail: `processing status unavailable: ${sanitizeText(error.message)}`,
    });
  }

  return finish(pollResult.state, {
    buildNumber: pollResult.buildNumber ?? uploadedBuildNumber,
    pollResult,
    detail:
      pollResult.state === SUCCESS_STATE
        ? null
        : `App Store Connect reported ${pollResult.processingState ?? "no terminal state"}`,
  });
}

async function main() {
  if (process.env.VKZ_TESTFLIGHT_ENABLED !== "true") {
    process.stdout.write("Promotion skipped: the TestFlight lane is disabled\n");
    return 0;
  }

  const sha = String(process.env.VKZ_RELEASE_SHA ?? "").toLowerCase();
  if (!SHA_PATTERN.test(sha)) {
    process.stdout.write("Promotion refused: the promoted revision is not a full commit SHA\n");
    return 1;
  }

  const repository = process.env.VKZ_REPOSITORY ?? "";
  const githubToken = process.env.VKZ_GITHUB_TOKEN ?? "";
  const version = process.env.VKZ_MARKETING_VERSION ?? "";
  const repoRoot = process.env.VKZ_REPO_ROOT ?? process.cwd();
  const keyId = process.env.VKZ_ASC_KEY_ID ?? "";
  const issuerId = process.env.VKZ_ASC_ISSUER_ID ?? "";
  const keyDir = process.env.VKZ_ASC_KEY_DIR ?? join(process.env.HOME ?? "", ".appstoreconnect/private_keys");
  const evidencePath = process.env.VKZ_EVIDENCE_PATH ?? join(repoRoot, "artifacts/testflight-evidence.json");
  const buildFactsPath = process.env.VKZ_BUILD_FACTS_FILE ?? join(dirname(evidencePath), "build-facts.json");
  // Freeze the build number so this upload stays identifiable in App Store
  // Connect. The run number is monotonic per repository.
  const buildNumber = process.env.VKZ_BUILD_NUMBER ?? process.env.GITHUB_RUN_NUMBER ?? "";

  const result = await runPromotion({
    config: { sha, version, runId: process.env.GITHUB_RUN_ID ?? null },
    deps: {
      archiveAndUpload: async () => {
        const run = await runCommand("bash", ["scripts/release/testflight-upload.sh"], {
          cwd: repoRoot,
          env: {
            ...process.env,
            VKZ_RELEASE_SHA: sha,
            VKZ_BUILD_NUMBER: buildNumber,
            VKZ_BUILD_FACTS_FILE: buildFactsPath,
          },
        });
        return { ...run, buildFacts: () => readBuildFacts(buildFactsPath) };
      },
      // Re-read main from the remote on the Mac itself: the hosted gate's
      // answer is only as fresh as the moment this job was queued.
      revalidate: () => fetchCurrentMainSha({ repository, token: githubToken }),
      poll: async ({ uploadedAfter, version: archivedVersion, buildNumber: uploadedBuildNumber }) => {
        // Polling can outlive one 15-minute App Store Connect token.
        const tokenProvider = createTokenProvider({
          keyId,
          issuerId,
          privateKeyPem: await readPrivateKey(join(keyDir, `AuthKey_${keyId}.p8`)),
        });
        const appId =
          process.env.VKZ_ASC_APP_ID ||
          (await resolveAppId({ tokenProvider, bundleId: process.env.VKZ_BUNDLE_ID ?? "" }));
        return pollProcessingState({
          tokenProvider,
          appId,
          version: archivedVersion,
          buildNumber: uploadedBuildNumber,
          uploadedAfter,
          timeoutMs: Number(process.env.VKZ_ASC_TIMEOUT_MS ?? 45 * 60 * 1000),
        });
      },
      notify: (status) =>
        postStatus({
          ...status,
          webhookUrl: process.env.VKZ_SLACK_WEBHOOK_URL ?? "",
          channelId: process.env.VKZ_SLACK_CHANNEL_ID ?? "",
        }),
      persistEvidence: async (evidence) => {
        await mkdir(dirname(evidencePath), { recursive: true });
        await writeFile(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, "utf8");
      },
    },
  });

  return result.succeeded ? 0 : 1;
}

if (Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main();
}
