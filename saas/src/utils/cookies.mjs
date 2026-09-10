/*
 * A single first-party cookie is not worth a cookie-parser dependency.
 * Only the first match wins, mirroring how browsers order duplicates.
 */
export function readCookie(req, name) {
  const prefix = `${name}=`;

  const match = (req.headers.cookie || "")
    .split(";")
    .map(value => value.trim())
    .find(value => value.startsWith(prefix));

  return match ? decodeURIComponent(match.slice(prefix.length)) : undefined;
}
