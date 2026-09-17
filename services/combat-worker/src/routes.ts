export type CombatRoute =
  | { kind: "connect"; matchId: string }
  | { kind: "map"; matchId: string; frameEpoch: number }
  | { kind: "report"; matchId: string };

/** URL decoding is bounded and uses the same identifier alphabet as the protocol. */
export function combatRoute(url: URL): CombatRoute | null {
  if (url.search !== "" || url.pathname.length > 512) return null;
  const path = /^\/v1\/matches\/([^/]+)\/(connect|report|frames\/([0-9]+)\/map)$/.exec(url.pathname);
  if (path?.[1] === undefined) return null;
  let matchId: string;
  try { matchId = decodeURIComponent(path[1]); } catch { return null; }
  if (!/^[A-Za-z0-9_:-]{1,128}$/.test(matchId)) return null;
  if (path[2] === "connect") return { kind: "connect", matchId };
  if (path[2] === "report") return { kind: "report", matchId };
  const frameEpoch = Number(path[3]);
  if (!Number.isSafeInteger(frameEpoch) || frameEpoch < 1) return null;
  return { kind: "map", matchId, frameEpoch };
}
