import { describe, expect, it } from "vitest";
import { exports as workerExports } from "cloudflare:workers";
import { MatchReportHandler } from "../src/report.js";
import { combatRoute } from "../src/routes.js";
import { claims, token } from "./helpers.js";

describe("combatRoute report", () => {
  it("parses the report route and rejects query strings", () => {
    expect(combatRoute(new URL("https://combat.test/v1/matches/m1/report"))).toEqual({ kind: "report", matchId: "m1" });
    expect(combatRoute(new URL("https://combat.test/v1/matches/m1/report?x=1"))).toBeNull();
  });
});

describe("worker report dispatch", () => {
  const url = (matchId: string) => `https://combat.test/v1/matches/${encodeURIComponent(matchId)}/report`;

  it("rejects unauthenticated and wrong-method requests", async () => {
    const payload = claims();
    expect((await workerExports.default.fetch(new Request(url(payload.matchId), { method: "POST" }))).status).toBe(401);
    const bearer = await token(payload);
    const get = await workerExports.default.fetch(new Request(url(payload.matchId), { headers: { Authorization: `Bearer ${bearer}` } }));
    expect(get.status).toBe(405);
  });

  it("returns 503 while the issue token is unconfigured", async () => {
    const payload = claims();
    const response = await workerExports.default.fetch(new Request(url(payload.matchId), {
      method: "POST",
      headers: { Authorization: `Bearer ${await token(payload)}`, "Content-Type": "application/json" },
      body: "{}",
    }));
    expect(response.status).toBe(503);
  });
});

describe("MatchReportHandler", () => {
  const post = (handler: MatchReportHandler, body: unknown, headers: Record<string, string> = { "Content-Type": "application/json" }) =>
    handler.fetch(new Request("https://combat.test/v1/matches/m/report", { method: "POST", headers, body: JSON.stringify(body) }), claims());

  it("creates a labeled issue from a bounded report", async () => {
    let sent: { title: string; body: string } | undefined;
    const handler = new MatchReportHandler(async (input) => { sent = input; return { number: 7, url: "https://github.com/x/issues/7" }; });
    const response = await post(handler, {
      device: { model: "iPhone16,1", ios: "26.0", build: "62" },
      transcript: "the other player teleported through the wall",
      log: [{ elapsedMs: 1200, kind: "stage", detail: "aligned -> degraded" }],
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ issue: 7, url: "https://github.com/x/issues/7" });
    expect(sent?.title).toBe("[match report] the other player teleported through the wall");
    expect(sent?.body).toContain("iPhone16,1");
    expect(sent?.body).toContain("aligned -> degraded");
    expect(sent?.body).toContain("### Player description");
  });

  it("bounds event count and field lengths", async () => {
    let sent: { title: string; body: string } | undefined;
    const handler = new MatchReportHandler(async (input) => { sent = input; return { number: 1, url: "u" }; });
    const response = await post(handler, {
      transcript: `${"x".repeat(5000)}`,
      log: [...Array.from({ length: 299 }, (_, i) => ({ elapsedMs: i, kind: "stage", detail: `event ${i}` })),
        { elapsedMs: 300, kind: "k".repeat(64), detail: "d".repeat(600) }],
    });
    expect(response.status).toBe(200);
    expect(sent?.body.length).toBeLessThanOrEqual(60_000);
    const parsed = JSON.parse(/```json\n(.+)\n```/.exec(sent!.body)![1]) as { kind: string; detail: string }[];
    expect(parsed.length).toBe(256);
    expect(parsed.at(-1)!.kind).toBe("k".repeat(32));
    expect(parsed.at(-1)!.detail).toBe("d".repeat(512));
  });

  it("rejects malformed input without calling GitHub", async () => {
    let calls = 0;
    const handler = new MatchReportHandler(async () => { calls++; return { number: 1, url: "u" }; });
    expect((await post(handler, {}, { "Content-Type": "text/plain" })).status).toBe(415);
    const invalid = await handler.fetch(new Request("https://combat.test/v1/matches/m/report", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "not json",
    }), claims());
    expect(invalid.status).toBe(400);
    expect(calls).toBe(0);
  });

  it("maps issue-creation failure to 502", async () => {
    const handler = new MatchReportHandler(async () => { throw new Error("issue-rejected"); });
    expect((await post(handler, { transcript: "hi" })).status).toBe(502);
  });
});
