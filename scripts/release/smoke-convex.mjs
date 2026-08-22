import { randomInt } from "node:crypto";
import { readFile, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_CODE_ATTEMPTS = 8;

export function makeValidCode(nextIndex = (length) => randomInt(length)) {
  let code = "";

  for (let index = 0; index < 6; index += 1) {
    const alphabetIndex = nextIndex(CODE_ALPHABET.length);
    if (!Number.isInteger(alphabetIndex) || alphabetIndex < 0 || alphabetIndex >= CODE_ALPHABET.length) {
      throw new Error("Invalid random index");
    }
    code += CODE_ALPHABET[alphabetIndex];
  }

  return code;
}

export async function assertUnknownCodeReturnsNull(querySnapshot, options = {}) {
  const maxAttempts = options.maxAttempts ?? MAX_CODE_ATTEMPTS;
  const nextIndex = options.nextIndex;

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const code = makeValidCode(nextIndex);
    const snapshot = await querySnapshot(code);

    if (snapshot === null) {
      return;
    }
  }

  throw new Error("No unknown code found");
}

export async function loadConvexClient() {
  const requireFromSpectator = createRequire(
    new URL("../../spectator/package.json", import.meta.url),
  );
  const browserModule = requireFromSpectator("convex/browser");
  const serverModule = requireFromSpectator("convex/server");

  return {
    ConvexHttpClient: browserModule.ConvexHttpClient,
    makeFunctionReference: serverModule.makeFunctionReference,
  };
}

async function consumeDeploymentUrl(filePath) {
  let deploymentUrl;

  try {
    deploymentUrl = (await readFile(filePath, "utf8")).trim();
  } finally {
    await rm(filePath, { force: true });
  }

  const parsedUrl = new URL(deploymentUrl);
  if (parsedUrl.protocol !== "https:" || parsedUrl.username || parsedUrl.password) {
    throw new Error("Invalid deployment URL");
  }

  return deploymentUrl;
}

export async function runConvexSmoke() {
  const urlFile = process.env.VKZ_CONVEX_URL_FILE;
  if (!urlFile) {
    throw new Error("Missing deployment URL handoff");
  }

  const deploymentUrl = await consumeDeploymentUrl(urlFile);
  const { ConvexHttpClient, makeFunctionReference } = await loadConvexClient();
  const client = new ConvexHttpClient(deploymentUrl);
  const spectatorSnapshot = makeFunctionReference("queries:spectatorSnapshot");

  await assertUnknownCodeReturnsNull((code) =>
    client.query(spectatorSnapshot, { code }),
  );
}

function isMainModule() {
  return Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
}

if (isMainModule()) {
  try {
    await runConvexSmoke();
    process.stdout.write("Convex spectator smoke: PASS\n");
  } catch {
    process.stderr.write("ERROR: Convex spectator smoke failed.\n");
    process.exitCode = 1;
  }
}
