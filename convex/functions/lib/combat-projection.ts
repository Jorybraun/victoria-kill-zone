import { hmac } from "@noble/hashes/hmac.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils.js";
import { validateCombatProjection, type CombatProjection } from "@vkz/combat-protocol";
import { digestsMatch } from "../../domain/session.js";

/** Separate key and domain prevent replay of a player admission JWT as a projection. */
export function verifyCombatProjection(payload: string,signature: string,secret: string): CombatProjection | null {
  if (payload.length > 131_072 || utf8ToBytes(payload).length > 131_072 || utf8ToBytes(secret).length < 32 || !/^[0-9a-f]{64}$/.test(signature)) return null;
  const expected=bytesToHex(hmac(sha256,utf8ToBytes(secret),utf8ToBytes(`vkz-projection-v1.${payload}`)));
  if (!digestsMatch(expected,signature)) return null;
  let value: unknown;
  try {value=JSON.parse(payload);} catch {return null;}
  return validateCombatProjection(value);
}
