import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { utf8ToBytes } from "@noble/hashes/utils.js";
import { validateTicketClaims, type CombatTicketClaims } from "@vkz/combat-protocol";

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
export function base64url(bytes: Uint8Array): string {
  let result = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index] ?? 0, b = bytes[index + 1] ?? 0, c = bytes[index + 2] ?? 0;
    result += (alphabet[a >> 2] ?? "") + (alphabet[((a & 3) << 4) | (b >> 4)] ?? "");
    if (index + 1 < bytes.length) result += alphabet[((b & 15) << 2) | (c >> 6)];
    if (index + 2 < bytes.length) result += alphabet[c & 63];
  }
  return result;
}

/** Compact HS256 JWT; the trusted runtime binds the verified player to commands. */
export function signCombatTicket(claims: CombatTicketClaims, secret: string): string {
  const key = utf8ToBytes(secret);
  if (key.length < 32 || validateTicketClaims(claims, claims.iat) === null) throw new Error("Invalid combat ticket configuration");
  const encoded = `${base64url(utf8ToBytes(JSON.stringify({alg:"HS256",typ:"JWT"})))}.${base64url(utf8ToBytes(JSON.stringify(claims)))}`;
  return `${encoded}.${base64url(hmac(sha256, key, utf8ToBytes(encoded)))}`;
}
