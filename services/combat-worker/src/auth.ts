import { LIMITS, validateTicketClaims, type CombatTicketClaims } from "@vkz/combat-protocol";

const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
const encoder = new TextEncoder();

function decodePart(part: string): Uint8Array<ArrayBuffer> {
  if (part.length === 0 || !/^[A-Za-z0-9_-]+$/.test(part)) throw new Error("Invalid encoding");
  const binary = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

/** No token, claim, or crypto failure is logged or returned to the caller. */
export async function verifyBearerTicket(request: Request, secret: string, nowSeconds: number): Promise<CombatTicketClaims | null> {
  const authorization = request.headers.get("Authorization");
  if (authorization === null || authorization.length > LIMITS.messageBytes || !authorization.startsWith("Bearer ")) return null;
  if (encoder.encode(secret).byteLength < 32) return null;
  const parts = authorization.slice(7).split(".");
  if (parts.length !== 3) return null;
  const [headerPart, payloadPart, signaturePart] = parts;
  if (headerPart === undefined || payloadPart === undefined || signaturePart === undefined) return null;
  try {
    const header: unknown = JSON.parse(decoder.decode(decodePart(headerPart)));
    if (typeof header !== "object" || header === null || !("alg" in header) || !("typ" in header)) return null;
    if (header.alg !== "HS256" || header.typ !== "JWT" || Object.keys(header).some((key) => key !== "alg" && key !== "typ")) return null;
    const signature = decodePart(signaturePart);
    if (signature.byteLength !== 32) return null;
    const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const verified = await crypto.subtle.verify("HMAC", key, signature, encoder.encode(`${headerPart}.${payloadPart}`));
    if (!verified) return null;
    const payload: unknown = JSON.parse(decoder.decode(decodePart(payloadPart)));
    return validateTicketClaims(payload, nowSeconds);
  } catch {
    return null;
  }
}
