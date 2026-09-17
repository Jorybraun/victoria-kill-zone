import { verifyBearerTicket } from "./auth.js";
import { combatRoute } from "./routes.js";
import { projectionConfigured } from "./projection-delivery.js";
import { reportHandler } from "./report.js";
export { CombatRoom } from "./room.js";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health" && url.search === "") {
      return Response.json({ service: "vkz-combat", protocol: 1, projection: { configured: projectionConfigured(env) } });
    }
    const route = combatRoute(url);
    if (route === null) return new Response(null, { status: 404 });
    const allowed = route.kind === "connect" ? ["GET"] : route.kind === "report" ? ["POST"] : ["GET", "PUT"];
    if (!allowed.includes(request.method)) return new Response(null, { status: 405, headers: { Allow: allowed.join(", ") } });
    if (route.kind === "connect" && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
    const claims = await verifyBearerTicket(request, env.COMBAT_TICKET_SECRET, Math.floor(Date.now() / 1000));
    if (claims === null || claims.matchId !== route.matchId) return new Response(null, { status: 401 });
    if (route.kind === "report") {
      const handler = reportHandler(env);
      return handler === null ? new Response(null, { status: 503 }) : handler.fetch(request, claims);
    }
    // Routing occurs only after authentication. WebSocket upgrade responses use
    // fetch forwarding: WebSockets cannot cross Workers' structured-clone RPC.
    return env.COMBAT_ROOMS.getByName(claims.matchId).fetch(request);
  },
} satisfies ExportedHandler<Env>;
