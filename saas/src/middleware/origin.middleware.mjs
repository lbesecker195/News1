import { APP } from "../services/platform.service.mjs";

/*
 * The CSRF defence. Browsers always send Origin on cross-site state-changing
 * requests, and the session cookie is SameSite=Lax, so an exact match against
 * the app's own origin is enough without a token round trip.
 */
export function requireSameOrigin(req, res, next) {
  if (req.get("origin") !== APP) {
    return res.status(403).json({
      error: "Invalid request origin."
    });
  }

  next();
}

export function protectMutations(req, res, next) {
  if (["GET", "HEAD", "OPTIONS"].includes(req.method)) {
    return next();
  }

  return requireSameOrigin(req, res, next);
}
