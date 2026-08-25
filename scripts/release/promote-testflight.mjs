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
  createAscToken,
  pollProcessingState,
  readPrivateKey,
  resolveAppId,
} from "./asc-client.mjs";
import { decideFromEnvironment } from "./promotion-gate.mjs";
import { postStatus } from "./slack-notify.mjs";
import { sanitizeText } from "./redact.mjs";

const SHA_PATTERN = /^[0-9a-f]{40}$/u;
const SUCCESS_STATE = "ready-for-testing";

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

export function runCommand(command, args, { cwd, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
      process.stdout.write(chunk);
    });
    child.stderr.on("data", (chunk) => {
      output += chunk;
      process.stderr.write(chunk);
    });
    child.on("error", (error) => resolve({ code: 1, output: String(error.message) }));
    child.on("close", (code) => resolve({ code: code ?? 1, output }));
  });
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
  if (!/^[0-9]+(\.[0-9]+){0,3}$/u.test(String(facts.buildNumber ?? ""))) {
    throw new Error("The archived build number could not be recovered");
  }
  return facts;
}

export async function runPromotion({ config, deps }) {
  const {
    archiveAndUpload,
    poll,
    notify = postStatus,
    persistEvidence,
    now = () => new Date(),
  } = deps;

  const { sha, version, runId = null } = config;
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
    await announce(state, { detail, buildNumber });
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
    if (persistEvidence) {
      try {
        await persistEvidence(evidence);
      } catch (error) {
        process.stdout.write(
          `Evidence not persisted (${sanitizeText(error.message)}); continuing.\n`,
        );
      }
    }
    return { state, succeeded: state === SUCCESS_STATE, evidence, statuses };
  };

  await announce("queued");
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
    uploadedBuildNumber = String((await upload.buildFacts()).buildNumber);
  } catch (error) {
    return finish("failed", {
      detail: `uploaded build could not be identified: ${sanitizeText(error.message)}`,
    });
  }

  await announce("uploaded", { buildNumber: uploadedBuildNumber });

  let pollResult;
  try {
    pollResult = await poll({
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
  const decision = decideFromEnvironment();
  if (!decision.promote) {
    process.stdout.write(`Promotion skipped: ${decision.reason}\n`);
    return 0;
  }

  const sha = decision.sha;
  const version = process.env.VKZ_MARKETING_VERSION ?? "0.1.0";
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
      poll: async ({ uploadedAfter, buildNumber: uploadedBuildNumber }) => {
        const token = createAscToken({
          keyId,
          issuerId,
          privateKeyPem: await readPrivateKey(join(keyDir, `AuthKey_${keyId}.p8`)),
        });
        const appId =
          process.env.VKZ_ASC_APP_ID ||
          (await resolveAppId({ token, bundleId: process.env.VKZ_BUNDLE_ID ?? "" }));
        return pollProcessingState({
          token,
          appId,
          version,
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
