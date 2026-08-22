import type { RejectReason } from "./types.js";

export type DomainResult<T> = { ok: true; value: T } | { ok: false; reason: RejectReason };

export function ok<T>(value: T): DomainResult<T> {
  return { ok: true, value };
}

export function rejected<T>(reason: RejectReason): DomainResult<T> {
  return { ok: false, reason };
}
