import type { MatchPhase } from "../domain/spectator";

export function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), maximum);
}

export function formatCountdown(milliseconds: number): string {
  return String(Math.max(0, Math.ceil(milliseconds / 1_000)));
}

export function formatTimestamp(timestamp: number): string {
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(timestamp);
}

export function formatPhase(phase: MatchPhase): string {
  switch (phase) {
    case "lobby":
      return "LOBBY";
    case "countdown":
      return "COUNTDOWN";
    case "running":
      return "RUNNING";
    case "finished":
      return "FINISHED";
    case "cancelled":
      return "CANCELLED";
  }
}
