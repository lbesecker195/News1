import * as admins from "../models/admin.model.mjs";
import { hash } from "../services/platform.service.mjs";
import { readCookie } from "../utils/cookies.mjs";

/*
 * A separate cookie from the tenant session, so an admin browsing the platform
 * and a customer signed into their own dashboard never collide, and neither
 * cookie can be mistaken for the other.
 */
export const ADMIN_COOKIE = "admin_session";

export async function requireAdmin(req, res, next) {
  try {
    const value = readCookie(req, ADMIN_COOKIE);
    const admin = value ? await admins.findBySession(hash(value)) : null;

    if (!admin) {
      return res.redirect("/admin/login");
    }

    req.admin = admin;
    next();
  } catch (error) {
    next(error);
  }
}
