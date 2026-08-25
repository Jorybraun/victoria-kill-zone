// Sanitizes text that leaves the promotion lane (Slack, evidence, logs).
//
// Nothing produced here may contain credentials, signing material, App Store
// Connect keys, Slack webhook URLs, filesystem paths, or device identifiers.

const REDACTED = "[redacted]";

const PATTERNS = [
  // Private keys and certificate blocks.
  /-----BEGIN[^-]*-----[\s\S]*?-----END[^-]*-----/gu,
  // JSON web tokens (App Store Connect authorization).
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu,
  // Any URL, which also covers Slack webhooks and Convex deployments.
  /\b[a-z][a-z0-9+.-]*:\/\/\S+/giu,
  // App Store Connect key files and key/issuer identifiers.
  /\bAuthKey_[A-Za-z0-9]+(?:\.p8)?/gu,
  // Absolute filesystem paths, which expose the worker account.
  /(?:\/Users|\/Volumes|\/var\/folders|\/private)\/\S*/gu,
  // Known credential prefixes.
  /\b(?:cog|gh[pousr]|xox[abposr]|sk|pk)[-_][A-Za-z0-9_-]{16,}\b/gu,
  // Long opaque tokens, hex digests, and device identifiers.
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/giu,
  // Device identifiers, including the iOS 8-16 hexadecimal UDID form.
  /\b[0-9a-f]{8}-[0-9a-f]{16}\b/giu,
  /\b[0-9A-Fa-f]{16,}\b/gu,
  /\b[A-Za-z0-9+/]{40,}={0,2}\b/gu,
];

const MAX_LENGTH = 300;

export function sanitizeText(value, maxLength = MAX_LENGTH) {
  if (value === undefined || value === null) {
    return null;
  }

  let text = String(value);
  for (const pattern of PATTERNS) {
    text = text.replace(pattern, REDACTED);
  }

  text = text
    // Collapse control characters so a single Slack line cannot be forged.
    .replace(/[\u0000-\u001f\u007f]+/gu, " ")
    .replace(/\s{2,}/gu, " ")
    .trim();

  if (text.length > maxLength) {
    text = `${text.slice(0, maxLength - 1).trimEnd()}…`;
  }

  return text.length === 0 ? REDACTED : text;
}

export function assertSanitized(value, label) {
  const text = String(value);
  if (sanitizeText(text, Number.MAX_SAFE_INTEGER) !== text) {
    throw new Error(`Unsanitized ${label}`);
  }
  return text;
}
