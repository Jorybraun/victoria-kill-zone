import type { DemoFixtureKind } from "./demoFixtures";

export type SpectatorRuntime =
  | { kind: "demo"; fixture: DemoFixtureKind }
  | { kind: "convex"; deploymentUrl: string }
  | { kind: "configuration-error"; message: string };

export function readDemoFixture(
  searchParams: URLSearchParams,
): DemoFixtureKind {
  switch (searchParams.get("demo")) {
    case "arena": return "arena";
    case "arena-degraded": return "arena-degraded";
    case "arena-recovery": return "arena-recovery";
    case "arena-calibrating": return "arena-calibrating";
    case "arena-paused": return "arena-paused";
    case "arena-ended": return "arena-ended";
    case "loading":
      return "loading";
    case "waiting":
      return "waiting";
    case "countdown":
      return "countdown";
    case "ended":
      return "ended";
    case "cancelled":
      return "cancelled";
    case "degraded":
      return "degraded";
    case "recovery":
      return "recovery";
    case "error":
      return "error";
    case "active":
    default:
      return "active";
  }
}

function isAllowedDevelopmentUrl(url: URL): boolean {
  return (
    url.protocol === "http:" &&
    (url.hostname === "localhost" ||
      url.hostname === "127.0.0.1" ||
      url.hostname === "[::1]")
  );
}

export function resolveRuntime(
  rawDeploymentUrl: string | undefined,
  searchParams: URLSearchParams,
): SpectatorRuntime {
  const deploymentUrl = rawDeploymentUrl?.trim();
  if (!deploymentUrl) {
    return { kind: "demo", fixture: readDemoFixture(searchParams) };
  }

  try {
    const parsed = new URL(deploymentUrl);
    if (parsed.protocol !== "https:" && !isAllowedDevelopmentUrl(parsed)) {
      return {
        kind: "configuration-error",
        message:
          "VITE_CONVEX_URL must use HTTPS, except for a localhost development deployment.",
      };
    }
    return { kind: "convex", deploymentUrl: parsed.toString() };
  } catch {
    return {
      kind: "configuration-error",
      message: "VITE_CONVEX_URL is not a valid deployment URL.",
    };
  }
}
