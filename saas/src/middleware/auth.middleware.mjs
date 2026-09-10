import * as auth from "../models/auth.model.mjs";
import { hash } from "../services/platform.service.mjs";
import { readCookie } from "../utils/cookies.mjs";

/* The tenant session cookie. Staff use a separate one; see admin.middleware. */
const SESSION_COOKIE = "session";

async function resolveTenant(req) {
  const value = readCookie(req, SESSION_COOKIE);

  return value
    ? auth.findTenantBySession(hash(value))
    : null;
}

/* JSON endpoints: an unauthenticated caller gets a 401 it can act on. */
export async function requireAuth(req, res, next) {
  try {
    const tenant = await resolveTenant(req);

    if (!tenant) {
      return res.status(401).json({ error: "Sign in first." });
    }

    req.tenant = tenant;
    next();
  } catch (error) {
    next(error);
  }
}

/*
 * Page routes: a signed-out visitor is sent to the marketing page instead of a
 * JSON error. Separate from requireAuth because inspecting req.path to guess
 * which behaviour was wanted breaks as soon as a router is mounted under a
 * prefix — req.path is relative to the mount point, not the URL.
 */
export async function requireAuthPage(req, res, next) {
  try {
    const tenant = await resolveTenant(req);

    if (!tenant) {
      return res.redirect("/");
    }

    req.tenant = tenant;
    next();
  } catch (error) {
    next(error);
  }
}

/*
 * Never blocks. Sets res.locals.signedIn so shared chrome — the header, the
 * footer — can offer the dashboard to someone who has a session and the
 * sign-in page to someone who does not.
 *
 * Costs nothing for an anonymous visitor: with no session cookie there is no
 * query to make.
 */
export async function attachSession(req, res, next) {
  res.locals.signedIn = false;

  if (!readCookie(req, SESSION_COOKIE)) return next();

  try {
    const tenant = await resolveTenant(req);

    if (tenant) {
      req.tenant = tenant;
      res.locals.signedIn = true;
    }
  } catch (error) {
    /* The chrome is not worth failing a page render over. */
    console.error("Session lookup for page chrome failed:", error.message);
  }

  next();
}
