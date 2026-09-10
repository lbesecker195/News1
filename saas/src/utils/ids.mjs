const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/*
 * Hand-rolled rather than z.string().uuid() because the string-format helpers
 * moved and were deprecated between Zod 3 and 4; a regex is stable, this runs
 * on every public feed request, and it keeps the leaf modules that only need
 * an id check free of a schema dependency.
 */
export const isUUID = value =>
  typeof value === "string" && UUID.test(value);

/* token() is 32 random bytes as base64url, which is always 43 characters. */
export const isLoginToken = value =>
  typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
