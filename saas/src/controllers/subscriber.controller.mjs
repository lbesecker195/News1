import * as subscribers from "../models/subscriber.model.mjs";
import { HttpError } from "../utils/http-error.mjs";

import {
  emailSchema,
  recipientSchema,
  isUUID
} from "../utils/validation.mjs";

export async function add(req, res) {
  const input = recipientSchema.parse(req.body);

  await subscribers.addRecipient({
    tenantId: req.tenant.id,
    email: input.email,
    authorisedBy: req.tenant.owner_email
  });

  res.json({
    message: "Recipient added. They will receive the next issue."
  });
}

export async function remove(req, res) {
  const removed = await subscribers.remove(
    req.tenant.id,
    emailSchema.parse(req.body?.email)
  );

  res.json({ ok: true, removed });
}

export function showConfirmation(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid invitation.");
  }

  res.set("Cache-Control", "no-store").render("subscribers/confirm", {
    title: "Confirm subscription",
    confirmationToken: req.params.token
  });
}

export async function confirm(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid invitation.");
  }

  const confirmed = await subscribers.confirm(req.params.token);

  res.status(confirmed ? 200 : 400).render("message", {
    title: "Subscription",
    heading: confirmed
      ? "You're subscribed."
      : "This invitation is no longer valid.",
    message: confirmed
      ? "Your company briefing will arrive by email."
      : "Ask your account administrator for help."
  });
}

export function showUnsubscribe(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid unsubscribe link.");
  }

  res.set("Cache-Control", "no-store").render("subscribers/unsubscribe", {
    title: "Unsubscribe",
    unsubscribeToken: req.params.token
  });
}

/*
 * Reached both from the confirmation page and from a mail client's one-click
 * List-Unsubscribe POST, so it answers the same way for an unknown token as
 * for a known one — the sender of a one-click request has no way to act on an
 * error, and confirming which tokens exist helps nobody.
 */
export async function unsubscribe(req, res) {
  if (!isUUID(req.params.token)) {
    throw new HttpError(400, "Invalid unsubscribe link.");
  }

  await subscribers.unsubscribe(req.params.token);

  /*
   * RFC 8058 one-click senders post with an Accept the browser never sends
   * and ignore the body; a person gets the page.
   */
  if (!req.accepts("html")) {
    return res.sendStatus(200);
  }

  res.render("message", {
    title: "Unsubscribed",
    heading: "You have been unsubscribed.",
    message: "Marketing and digest emails have been stopped for this address."
  });
}
