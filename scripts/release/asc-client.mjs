// App Store Connect client for the TestFlight promotion lane.
//
// The private key is read from a file outside the repository, is never logged,
// and never becomes a process argument. Only the build's processing state,
// build number, and upload time leave this module.

import { createPrivateKey, sign as signPayload } from "node:crypto";
import { readFile } from "node:fs/promises";

import { sanitizeText } from "./redact.mjs";

const API_ROOT = "https://api.appstoreconnect.apple.com/v1";
const AUDIENCE = "appstoreconnect-v1";
const TOKEN_LIFETIME_SECONDS = 15 * 60;

export const TERMINAL_STATES = Object.freeze({
  VALID: "ready-for-testing",
  FAILED: "processing-failed",
  INVALID: "processing-invalid",
});

function base64Url(input) {
  return Buffer.from(input).toString("base64url");
}

export function createAscToken({ keyId, issuerId, privateKeyPem }, now = new Date()) {
  if (!/^[A-Z0-9]{8,12}$/u.test(String(keyId))) {
    throw new Error("Invalid App Store Connect key id");
  }
  if (!/^[0-9a-f-]{36}$/iu.test(String(issuerId))) {
    throw new Error("Invalid App Store Connect issuer id");
  }

  const issuedAt = Math.floor(now.getTime() / 1000);
  const header = base64Url(
    JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }),
  );
  const payload = base64Url(
    JSON.stringify({
      iss: issuerId,
      iat: issuedAt,
      exp: issuedAt + TOKEN_LIFETIME_SECONDS,
      aud: AUDIENCE,
    }),
  );

  const key = createPrivateKey(privateKeyPem);
  const signature = signPayload(
    "sha256",
    Buffer.from(`${header}.${payload}`),
    { dsaEncoding: "ieee-p1363", key },
  );

  return `${header}.${payload}.${signature.toString("base64url")}`;
}

export async function readPrivateKey(keyPath) {
  const contents = await readFile(keyPath, "utf8");
  if (!contents.includes("PRIVATE KEY")) {
    throw new Error("The App Store Connect key file is not a private key");
  }
  return contents;
}

async function requestJson({ fetchImpl, url, token }) {
  const response = await fetchImpl(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
  });

  if (!response.ok) {
    const error = new Error(
      `App Store Connect request failed with status ${response.status}`,
    );
    error.status = response.status;
    error.retryable = response.status === 429 || response.status >= 500;
    throw error;
  }

  return response.json();
}

function buildsUrl({ appId, version, buildNumber }) {
  const query = new URLSearchParams({
    "filter[app]": appId,
    "filter[preReleaseVersion.version]": version,
    // The build number identifies this upload. Selecting "the newest build"
    // instead would race a concurrent or unrelated upload.
    "filter[version]": buildNumber,
    "fields[builds]": "processingState,version,uploadedDate,expired",
    sort: "-uploadedDate",
    limit: "20",
  });
  return `${API_ROOT}/builds?${query.toString()}`;
}

function selectBuild(payload, { uploadedAfter, buildNumber }) {
  const builds = Array.isArray(payload?.data) ? payload.data : [];
  const candidates = builds
    .filter((build) => {
      const attributes = build?.attributes ?? {};
      if (String(attributes.version ?? "") !== String(buildNumber)) {
        return false;
      }
      const uploadedDate = Date.parse(attributes.uploadedDate ?? "");
      return Number.isFinite(uploadedDate) && uploadedDate >= uploadedAfter;
    })
    .sort(
      (left, right) =>
        Date.parse(right.attributes.uploadedDate) -
        Date.parse(left.attributes.uploadedDate),
    );
  return candidates[0] ?? null;
}

export async function pollProcessingState({
  fetchImpl = globalThis.fetch,
  token,
  appId,
  version,
  buildNumber,
  uploadedAfter,
  timeoutMs = 30 * 60 * 1000,
  initialDelayMs = 20 * 1000,
  maxDelayMs = 2 * 60 * 1000,
  now = () => Date.now(),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  if (!/^[0-9]+$/u.test(String(appId))) {
    throw new Error("Invalid App Store Connect app id");
  }
  if (!/^[0-9]+(\.[0-9]+){0,2}$/u.test(String(version))) {
    throw new Error("Invalid marketing version");
  }
  if (!/^[0-9]+(\.[0-9]+){0,3}$/u.test(String(buildNumber))) {
    throw new Error("Invalid build number");
  }

  const deadline = now() + timeoutMs;
  const url = buildsUrl({ appId, version, buildNumber });
  let delayMs = initialDelayMs;
  let attempts = 0;
  let transientFailures = 0;

  while (now() < deadline) {
    attempts += 1;
    let payload;
    try {
      payload = await requestJson({ fetchImpl, url, token });
    } catch (error) {
      if (!error.retryable) {
        throw new Error(sanitizeText(error.message));
      }
      transientFailures += 1;
      await sleep(delayMs);
      delayMs = Math.min(delayMs * 2, maxDelayMs);
      continue;
    }

    const build = selectBuild(payload, { uploadedAfter, buildNumber });
    const processingState = build?.attributes?.processingState ?? null;

    if (processingState && Object.hasOwn(TERMINAL_STATES, processingState)) {
      return {
        state: TERMINAL_STATES[processingState],
        processingState,
        buildNumber: String(build.attributes.version ?? ""),
        uploadedDate: String(build.attributes.uploadedDate ?? ""),
        attempts,
        transientFailures,
        timedOut: false,
      };
    }

    await sleep(delayMs);
    delayMs = Math.min(delayMs * 2, maxDelayMs);
  }

  return {
    state: "processing-timeout",
    processingState: null,
    buildNumber: String(buildNumber),
    uploadedDate: null,
    attempts,
    transientFailures,
    timedOut: true,
  };
}

export async function resolveAppId({
  fetchImpl = globalThis.fetch,
  token,
  bundleId,
}) {
  const query = new URLSearchParams({
    "filter[bundleId]": bundleId,
    "fields[apps]": "bundleId",
    limit: "2",
  });
  const payload = await requestJson({
    fetchImpl,
    token,
    url: `${API_ROOT}/apps?${query.toString()}`,
  });
  const apps = Array.isArray(payload?.data) ? payload.data : [];
  if (apps.length !== 1 || !/^[0-9]+$/u.test(String(apps[0]?.id ?? ""))) {
    throw new Error("The bundle id does not resolve to exactly one app record");
  }
  return String(apps[0].id);
}
