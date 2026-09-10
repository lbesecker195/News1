import crypto from "node:crypto";
import { promisify } from "node:util";

const scrypt = promisify(crypto.scrypt);

/*
 * scrypt from the standard library rather than a bcrypt dependency: it is
 * memory-hard, it ships with Node, and there is no native build to go wrong.
 *
 * Stored as scrypt$N$r$p$salt$hash so the parameters travel with the hash and
 * can be raised later without invalidating existing passwords.
 */
const PARAMS = { N: 16384, r: 8, p: 1 };
const KEY_LENGTH = 64;

/*
 * Eight, following NIST 800-63B: length floors above that push people towards
 * predictable padding, and what actually stops guessing here is the rate limit
 * on the sign-in route, not the rule.
 */
export const MIN_LENGTH = 8;

export async function hashPassword(plain) {
  if (typeof plain !== "string" || plain.length < MIN_LENGTH) {
    throw new Error(`A password must be at least ${MIN_LENGTH} characters.`);
  }

  const salt = crypto.randomBytes(16);
  const key = await scrypt(plain, salt, KEY_LENGTH, PARAMS);

  return [
    "scrypt",
    PARAMS.N,
    PARAMS.r,
    PARAMS.p,
    salt.toString("hex"),
    key.toString("hex")
  ].join("$");
}

/*
 * Returns false rather than throwing on a malformed stored value: a corrupt
 * row must fail the login, not crash the request.
 */
export async function verifyPassword(plain, stored) {
  if (typeof plain !== "string" || typeof stored !== "string") return false;

  const [scheme, N, r, p, salt, expected] = stored.split("$");

  if (scheme !== "scrypt" || !salt || !expected) return false;

  try {
    const key = await scrypt(
      plain,
      Buffer.from(salt, "hex"),
      expected.length / 2,
      { N: Number(N), r: Number(r), p: Number(p) }
    );

    const expectedBuffer = Buffer.from(expected, "hex");

    /* Lengths must match before timingSafeEqual, which throws otherwise. */
    if (key.length !== expectedBuffer.length) return false;

    return crypto.timingSafeEqual(key, expectedBuffer);
  } catch {
    return false;
  }
}
