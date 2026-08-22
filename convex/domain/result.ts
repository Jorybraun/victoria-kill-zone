import type { ErrorCode } from "./contract.js";

/**
 * Pure-domain rule outcome. Rules never throw and never touch the database, so
 * every lifecycle decision is deterministic and unit testable.
 */
export type DomainResult<Value> =
  | { readonly ok: true; readonly value: Value }
  | { readonly ok: false; readonly code: ErrorCode };

export function ok<Value>(value: Value): DomainResult<Value> {
  return { ok: true, value };
}

export function rejected<Value>(code: ErrorCode): DomainResult<Value> {
  return { ok: false, code };
}
