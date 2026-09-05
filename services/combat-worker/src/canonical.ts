/** Stable identity for bounded, schema-validated JSON values (never credentials). */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((entry: unknown) => canonicalJson(entry)).join(",")}]`;
  const record: Record<string, unknown> = Object.fromEntries(Object.entries(value));
  return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(",")}}`;
}
