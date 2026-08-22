# ADR 0002: Server-issued, Keychain-persisted demo match sessions

- **Status:** Accepted for g2.v1 and phase0.v1 demo delivery
- **Date:** 2026-08-22
- **Decision owners:** Product and integration
- **Reconsider:** After Phase 0 physical-device proof

## Context

The technical specification describes a client-generated device identity and match secret. The already-frozen G2 wire instead returns a server-generated `PlayerSession` from `matches:create` and `matches:join`. Replacing that wire now would invalidate the independently implemented Convex and iOS G2 lanes, while leaving the returned capability only in process memory would make reconnect unsafe and unreliable.

The decision must preserve the reviewed G2 wire, provide restart recovery on both demo phones, and prevent credential material from entering public projections or delivery evidence.

## Decision

For the 2026-08-22 demo contracts `g2.v1` and `phase0.v1`, Convex generates a cryptographically random 256-bit, match-scoped bearer secret during `matches:create` or `matches:join`. It returns the lowercase hexadecimal secret exactly once as part of that player's `PlayerSession` and persists only its SHA-256 digest.

The iOS client must save the complete `PlayerSession` to an app-private, device-only Keychain item before enabling the session. On relaunch it restores the item, resubscribes, and keeps all mutations locked until it receives a fresh authoritative snapshot for the same match and player.

This decision supersedes the session-issuance mechanism in sections 11.2–11.3 of the technical specification and the anonymous-device-identity clause in ADR 0001 only for these two demo contract versions. It does not change an existing G2 wire name or DTO, and phase0.v1 reuses the same PlayerSession and capability semantics. The phase0.v1 shots:fire request calls the bound player shooterId, as required by the technical specification; it must equal PlayerSession.playerId. Stable anonymous device identity and client-generated credentials remain the post-demo target.

## Capability contract

```ts
type PlayerSession = {
  matchId: string;
  code: string;
  playerId: string;
  sessionSecret: string; // exactly 64 lowercase hex characters
};

type AuthenticatedPlayerArgs = {
  matchId: string;
  playerId: string;
  sessionSecret: string;
};
```

- A secret authenticates exactly one player in exactly one match.
- Match and player IDs are routing identifiers, not credentials.
- No query or later mutation can retrieve a session secret.
- Phone and spectator snapshots contain neither the secret nor its digest.
- Authentication compares digests without logging request arguments.

## Required iOS persistence behavior

Use one versioned generic-password Keychain item in the app's private access group with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and iCloud synchronization disabled.

1. Validate the create/join response.
2. Save all four fields before starting a subscription or enabling controls.
3. If the save fails, fail closed and allow retrying only the Keychain write; do not repeat create/join.
4. Restore and subscribe on launch, but remain input-locked until a fresh matching snapshot arrives.
5. Preserve the item across transport failures.
6. Delete it on explicit leave, corrupt or unsupported data, `INVALID_SESSION`, or `MATCH_NOT_FOUND`.
7. Never store it in `UserDefaults`, files, state restoration, clipboard, analytics, or test fixtures.

## Redaction and evidence

Never log or render a `PlayerSession`, request dictionary, session secret, digest, Keychain query, private session URL, match/player/device identifier, or raw Convex exception. Sanitized diagnostics may contain only operation names, stable public error codes, and Keychain status numbers.

Backend, iOS, spectator, CI, screenshots, PRs, Slack, and build evidence must all prove that capability material is absent rather than displaying sample or partially masked values.

## Required proof

Backend tests must prove 256-bit lowercase-hex issuance, digest-only persistence, player/match binding, malformed-secret rejection, and secret-free public projections. iOS tests must prove save/load/delete, restart restoration, fail-closed persistence, fresh-snapshot locking, and redacted diagnostics.

Physical acceptance must terminate and relaunch each phone into the same lobby, then disconnect/reconnect and prove that gameplay remains locked until a fresh snapshot arrives.

## Migration

After the demo, introduce a credential V2 alongside V1: iOS creates a stable Keychain device ID and session secret with `SecRandomCopyBytes`, create/join send only their hashes, and the backend records the credential version. Existing V1 matches expire naturally. Remove server-issued V1 only after V2 passes the same two-phone proof.
