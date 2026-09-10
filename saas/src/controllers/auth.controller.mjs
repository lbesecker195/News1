import * as auth from "../models/auth.model.mjs";
import {
  APP,
  token,
  hash
} from "../services/platform.service.mjs";

import { readCookie } from "../utils/cookies.mjs";
import { HttpError } from "../utils/http-error.mjs";
import {
  emailSchema,
  isLoginToken
} from "../utils/validation.mjs";

const SESSION_COOKIE = {
  httpOnly: true,
  secure: APP.startsWith("https://"),
  sameSite: "lax",
  path: "/"
};

export async function requestLogin(req, res) {
  const email = emailSchema.parse(req.body?.email);
  const secret = token();

  await auth.createLogin({
    email,
    tokenHash: hash(secret),
    url: `${APP}/login/${secret}`
  });

  /*
   * Deliberately the same answer whether or not the address is already known:
   * this endpoint must not double as an account-existence oracle.
   */
  res.json({
    message: "Check your email for a sign-in link."
  });
}

/*
 * An interstitial rather than signing in straight from the GET. Mail scanners
 * and link previewers follow links in email, and a GET that creates a session
 * would burn the token before the recipient ever clicked it.
 */
export function showLogin(req, res) {
  if (!isLoginToken(req.params.token)) {
    throw new HttpError(400, "Invalid sign-in link.");
  }

  res.set("Cache-Control", "no-store").render("auth/login", {
    title: "Confirm sign in",
    loginToken: req.params.token
  });
}

export async function completeLogin(req, res) {
  if (!isLoginToken(req.params.token)) {
    throw new HttpError(400, "Invalid sign-in link.");
  }

  const sessionSecret = token();

  const tenantId = await auth.consumeLoginAndCreateSession({
    loginHash: hash(req.params.token),
    sessionHash: hash(sessionSecret)
  });

  if (!tenantId) {
    throw new HttpError(400, "Link expired or already used.");
  }

  res.cookie("session", sessionSecret, {
    ...SESSION_COOKIE,
    maxAge: 14 * 86400000
  });

  res.redirect("/app");
}

export async function logout(req, res) {
  await auth.deleteSession(
    hash(readCookie(req, "session") || "")
  );

  /* Attributes must match the ones the cookie was set with, or it survives. */
  res.clearCookie("session", SESSION_COOKIE);
  res.json({ ok: true });
}
