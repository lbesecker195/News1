import { processPayPalEvent } from "../services/billing.service.mjs";
import { processMailgunWebhook } from "../services/mailgun-webhook.service.mjs";
import {
  paypalConfigured,
  verifyWebhook
} from "../services/paypal.service.mjs";

export async function paypalWebhook(req, res) {
  /*
   * Nothing can be verified without credentials, and an unverified event must
   * never be applied. 503 so PayPal retries once this is configured.
   */
  if (!paypalConfigured()) {
    return res.status(503).json({ error: "Payments are not configured." });
  }

  let verified;

  try {
    verified = await verifyWebhook(req.headers, req.body);
  } catch (error) {
    /*
     * Verification is a call to PayPal, so it can fail for reasons that have
     * nothing to do with this event. A 503 asks PayPal to retry rather than
     * dropping a real event or, worse, trusting an unverified one.
     */
    console.error("PayPal webhook verification unavailable:", error.message);
    return res.status(503).json({ error: "Verification unavailable." });
  }

  if (!verified) {
    return res.status(401).json({ error: "Invalid PayPal signature." });
  }

  await processPayPalEvent(req.body);
  res.json({ received: true });
}

export async function mailgunWebhook(req, res) {
  await processMailgunWebhook(req.body);
  res.sendStatus(200);
}
