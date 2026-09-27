export type CombatRoute =
  | { kind: "connect"; matchId: string }
  | { kind: "report"; matchId: string };

/** URL decoding is bounded and uses the same identifier alphabet as the protocol. */
export function combatRoute(url: URL): CombatRoute | null {
  if (url.search !== "" || url.pathname.length > 512) return null;
  const path = /^\/v1\/matches\/([^/]+)\/(connect|report)$/.exec(url.pathname);
  if (path?.[1] === undefined) return null;
  let matchId: string;
  try { matchId = decodeURIComponent(path[1]); } catch { return null; }
  if (!/^[A-Za-z0-9_:-]{1,128}$/.test(matchId)) return null;
  return { kind: path[2] === "connect" ? "connect" : "report", matchId };
}
