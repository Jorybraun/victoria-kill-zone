// Posts sanitized TestFlight promotion status to the release channel.
//
// The webhook URL arrives through the environment and is never logged. Every
// field is sanitized before it is sent, and the short revision is used so a
// full SHA never appears in chat.

import { sanitizeText } from "./redact.mjs";

export const RELEASE_STATES = Object.freeze([
  "queued",
  "archiving",
  "uploaded",
  "ready-for-testing",
  "processing-failed",
  "processing-invalid",
  "processing-timeout",
  "skipped-stale",
  "failed",
]);

const STATE_HEADLINES = Object.freeze({
  queued: "PEW PEW promotion queued",
  archiving: "PEW PEW archiving and signing",
  uploaded: "PEW PEW uploaded — App Store Connect processing",
  "ready-for-testing": "PEW PEW ready for TestFlight testing",
  "processing-failed": "PEW PEW processing failed",
  "processing-invalid": "PEW PEW build rejected as invalid",
  "processing-timeout": "PEW PEW processing timed out",
  "skipped-stale": "PEW PEW promotion skipped — main moved on",
  failed: "PEW PEW promotion failed",
});

export function buildStatusMessage({ state, sha, version, buildNumber, detail }) {
  if (!RELEASE_STATES.includes(state)) {
    throw new Error(`Unsupported release state: ${sanitizeText(state)}`);
  }

  const shortSha = /^[0-9a-f]{40}$/u.test(String(sha ?? ""))
    ? String(sha).slice(0, 12)
    : "unknown";

  const lines = [`${STATE_HEADLINES[state]} (${state})`, `revision \`${shortSha}\``];

  if (version) {
    lines.push(`version ${sanitizeText(version, 32)}`);
  }
  if (buildNumber) {
    lines.push(`build ${sanitizeText(buildNumber, 32)}`);
  }
  if (detail) {
    lines.push(sanitizeText(detail));
  }

  return lines.join("\n");
}

export async function postStatus({
  fetchImpl = globalThis.fetch,
  webhookUrl,
  channelId,
  ...status
}) {
  const text = buildStatusMessage(status);

  if (!webhookUrl) {
    return { posted: false, reason: "no webhook configured", text };
  }

  let response;
  try {
    response = await fetchImpl(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ channel: channelId, text }),
    });
  } catch (error) {
    // Slack is an observer of the lane, never a gate on it.
    return { posted: false, reason: sanitizeText(error.message), text };
  }

  if (!response.ok) {
    return {
      posted: false,
      reason: `Slack responded with status ${response.status}`,
      text,
    };
  }

  return { posted: true, reason: null, text };
}
