import express, { Router } from "express";

import * as webhook from "../controllers/webhook.controller.mjs";
import { asyncHandler as wrap } from "../utils/async-handler.mjs";

export const paypalWebhookRoutes = Router();
export const mailgunWebhookRoutes = Router();

/*
 * PayPal verifies a webhook by posting the parsed event back to its own API,
 * so unlike a signature over the raw bytes this router can use ordinary JSON
 * parsing.
 */
paypalWebhookRoutes.post(
  "/",
  express.json({ limit: "1mb" }),
  wrap(webhook.paypalWebhook)
);

/*
 * Mailgun signs a token and timestamp inside the JSON body. The limit is
 * generous because delivery events carry the original message headers.
 */
mailgunWebhookRoutes.post(
  "/",
  express.json({ limit: "1mb" }),
  wrap(webhook.mailgunWebhook)
);
