import type { CombatTicketClaims } from "@vkz/combat-protocol";

const BODY_BYTES = 128 * 1024;
const TRANSCRIPT_CHARS = 4_000;
const ISSUE_BODY_CHARS = 60_000;
const EVENT_DETAIL_CHARS = 512;
const REPOSITORY = "Jorybraun/victoria-kill-zone";

type ReportEnv = { GITHUB_ISSUES_TOKEN?: string };
type CreateIssue = (input: { title: string; body: string }) => Promise<{ number: number; url: string }>;

export type MatchReport = {
  device?: { model?: string; ios?: string; build?: string };
  transcript?: string;
  log?: { elapsedMs?: number; kind?: string; detail?: string }[];
};

/** Match-scoped problem report → GitHub issue tagged for Devin triage. */
export class MatchReportHandler {
  constructor(private readonly createIssue: CreateIssue) {}

  async fetch(request: Request, claims: CombatTicketClaims): Promise<Response> {
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    if (request.headers.get("Content-Type") !== "application/json") return new Response(null, { status: 415 });
    const length = request.headers.get("Content-Length");
    if (length !== null && (!/^[0-9]+$/.test(length) || Number(length) > BODY_BYTES)) return new Response(null, { status: 413 });
    let report: MatchReport;
    try {
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > BODY_BYTES) return new Response(null, { status: 413 });
      report = JSON.parse(raw);
    } catch { return new Response(null, { status: 400 }); }
    if (typeof report !== "object" || report === null || Array.isArray(report)) return new Response(null, { status: 400 });
    const issue = await this.createIssue({
      title: issueTitle(report),
      body: issueBody(report, claims.matchId),
    }).catch(() => null);
    if (issue === null) return new Response(null, { status: 502 });
    return Response.json({ issue: issue.number, url: issue.url });
  }
}

/** 503 when unconfigured; the guarded deploy carries only the two combat secrets. */
export function reportHandler(env: Env): MatchReportHandler | null {
  const token = (env as Env & ReportEnv).GITHUB_ISSUES_TOKEN;
  if (typeof token !== "string" || token.length === 0) return null;
  return new MatchReportHandler(async (input) => {
    const response = await fetch(`https://api.github.com/repos/${REPOSITORY}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "User-Agent": "vkz-combat-worker",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({ ...input, labels: ["devin-report"] }),
    });
    if (response.status !== 201) throw new Error("issue-rejected");
    const created = await response.json() as { number?: number; html_url?: string };
    if (typeof created.number !== "number" || typeof created.html_url !== "string") throw new Error("issue-receipt-invalid");
    return { number: created.number, url: created.html_url };
  });
}

function text(value: unknown, limit: number): string {
  return typeof value === "string" ? value.slice(0, limit) : "";
}

function issueTitle(report: MatchReport): string {
  const summary = text(report.transcript, TRANSCRIPT_CHARS).split("\n")[0].trim().slice(0, 72);
  return `[match report] ${summary === "" ? "player report" : summary}`;
}

function issueBody(report: MatchReport, matchId: string): string {
  const device = report.device ?? {};
  const log = (report.log ?? [])
    .filter((e) => typeof e === "object" && e !== null)
    .map((e) => ({
      elapsedMs: Math.max(0, Math.floor(Number(e.elapsedMs) || 0)),
      kind: text(e.kind, 32),
      detail: text(e.detail, EVENT_DETAIL_CHARS),
    }))
    .slice(-256);
  const body = [
    "## Match report",
    "",
    `- Device: ${text(device.model, 64) || "unknown"}`,
    `- iOS: ${text(device.ios, 32) || "unknown"}`,
    `- Build: ${text(device.build, 32) || "unknown"}`,
    `- Match: \`${matchId.slice(0, 36)}\``,
    "",
    "### Player description",
    "",
    text(report.transcript, TRANSCRIPT_CHARS) || "_none_",
    "",
    "### Setup log",
    "",
    "```json",
    JSON.stringify(log),
    "```",
  ].join("\n");
  return body.slice(0, ISSUE_BODY_CHARS);
}
