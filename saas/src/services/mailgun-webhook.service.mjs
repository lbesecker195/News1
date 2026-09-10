import crypto from "node:crypto";

import { env } from "../config/env.mjs";
import * as events from "../models/mailgun-event.model.mjs";
import { HttpError } from "../utils/http-error.mjs";
import { isUUID } from "../utils/validation.mjs";

const MAX_SKEW_SECONDS = 86_400;

/*
 * `apply` is a parameter so the signature guard can be tested without a
 * database. Production callers pass one argument and get the real model.
 */
export async function processMailgunWebhook(
  body,
  apply = events.recordAndApply
) {
  const signature = body?.signature || {};

  const timestamp = String(signature.timestamp || "");
  const signingToken = String(signature.token || "");
  const supplied = String(signature.signature || "");

  /*
   * Shape is checked before the HMAC so timingSafeEqual is never handed
   * mismatched buffer lengths — it throws rather than returning false.
   */
  if (
    !/^\d+$/.test(timestamp) ||
    Math.abs(Date.now() / 1000 - Number(timestamp)) > MAX_SKEW_SECONDS ||
    !/^[a-f0-9]{64}$/i.test(supplied)
  ) {
    throw new HttpError(403, "Invalid Mailgun signature.");
  }

  const expected = crypto.createHmac(
    "sha256",
    env.mailgunSigningKey
  )
    .update(timestamp + signingToken)
    .digest("hex");

  if (!crypto.timingSafeEqual(
    Buffer.from(expected, "hex"),
    Buffer.from(supplied, "hex")
  )) {
    throw new HttpError(403, "Invalid Mailgun signature.");
  }

  const data = body["event-data"];

  if (!data?.id || !data?.event) {
    throw new HttpError(400, "Invalid Mailgun event.");
  }

  const candidateJobId = data["user-variables"]?.job_id;

  /*
   * Mailgun reports both soft and hard failures as "failed"; only a permanent
   * one may suppress an address for good.
   */
  const kind = data.event === "failed" &&
    data.severity === "permanent"
    ? "hard_bounce"
    : data.event;

  await apply({
    id: String(data.id),
    kind,
    jobId: isUUID(candidateJobId) ? candidateJobId : null,
    email: String(data.recipient || "").trim().toLowerCase()
  });
}
