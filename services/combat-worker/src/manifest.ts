import type { ReleaseManifestSummary, WorkerIdentity } from "@vkz/combat-protocol";
import releaseManifest from "../../../release-manifest.json";

/** release-manifest.json minus its envelope metadata; stamped at release time. */
export function releaseManifestSummary(): ReleaseManifestSummary {
  const { protocolVersion, rulesSchemaHash, doClass, doMigrationTag, iosMinProtocol, iosMaxProtocol, convexMinProtocol, workerVersionTag, releaseSha } = releaseManifest;
  return { protocolVersion, rulesSchemaHash, doClass, doMigrationTag, iosMinProtocol, iosMaxProtocol, convexMinProtocol, workerVersionTag, releaseSha };
}

type VersionMetadataEnv = { VERSION_METADATA?: { id?: string; tag?: string } };

/** Identity of the code this worker instance is actually running. */
export function workerIdentity(env: VersionMetadataEnv): WorkerIdentity {
  return {
    // An absent binding or an empty local-dev tag both mean "unversioned".
    versionId: env.VERSION_METADATA?.id || null,
    versionTag: env.VERSION_METADATA?.tag || null,
    releaseSha: releaseManifest.releaseSha,
    workerVersionTag: releaseManifest.workerVersionTag,
    doMigrationTag: releaseManifest.doMigrationTag,
  };
}
