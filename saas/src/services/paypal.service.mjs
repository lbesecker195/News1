import { env } from "../config/env.mjs";
import {
  ok,
  paypal,
  paypalError,
  paypalConfigured
} from "../config/paypal.mjs";

import * as plans from "../models/paypal-plan.model.mjs";

export { paypalConfigured };

export const PLAN_CENTS = 2500;
export const PLAN_USD = (PLAN_CENTS / 100).toFixed(2);

const BRAND = "Rnews1";

/* PayPal subscription states that entitle the tenant to the service. */
export const LIVE_STATUSES = ["ACTIVE"];

/* States a tenant can be moved out of by subscribing again. */
export const RESUBSCRIBABLE = ["CANCELLED", "EXPIRED", "APPROVAL_PENDING", "APPROVED"];

/*
 * The billing plan, created on first use and cached in Postgres afterwards.
 * Keyed on the price so raising it creates a new plan instead of quietly
 * charging the old amount.
 */
export async function ensurePlan() {
  const key = `briefing-${PLAN_USD}-month`;

  const existing = await plans.findByKey(key);

  if (existing) return existing;

  const productId = await ensureProduct();

  const response = await paypal("POST", "/v1/billing/plans", {
    product_id: productId,
    name: `${BRAND} company briefing`,
    description:
      "One company feed, embed and daily briefing for your team.",
    billing_cycles: [{
      frequency: { interval_unit: "MONTH", interval_count: 1 },
      tenure_type: "REGULAR",
      sequence: 1,
      /* 0 = renews until cancelled. */
      total_cycles: 0,
      pricing_scheme: {
        fixed_price: { currency_code: "USD", value: PLAN_USD }
      }
    }],
    payment_preferences: {
      auto_bill_outstanding: true,
      setup_fee_failure_action: "CANCEL",
      payment_failure_threshold: 2
    }
  });

  if (!ok(response)) throw paypalError("create plan", response);

  /*
   * Two processes can reach this at once on a cold database; the insert takes
   * the first plan to land and both end up using it.
   */
  return plans.create({
    key,
    productId,
    planId: response.body.id,
    amountCents: PLAN_CENTS,
    raw: response.body
  });
}

async function ensureProduct() {
  const response = await paypal("POST", "/v1/catalogs/products", {
    name: BRAND,
    description: "Company news feeds, embeds and daily briefings",
    type: "SERVICE",
    category: "SOFTWARE"
  });

  if (!ok(response)) throw paypalError("create product", response);

  return response.body.id;
}

/*
 * Nothing is charged here. The customer is charged when they approve the
 * subscription at the returned link, and BILLING.SUBSCRIPTION.ACTIVATED is what
 * tells us it happened.
 */
export async function createSubscription({
  email,
  companyName,
  tenantId,
  returnUrl,
  cancelUrl
}) {
  const plan = await ensurePlan();

  const response = await paypal("POST", "/v1/billing/subscriptions", {
    plan_id: plan.plan_id,
    subscriber: { email_address: email },
    custom_id: `tenant_${tenantId}`,
    application_context: {
      brand_name: BRAND,
      user_action: "SUBSCRIBE_NOW",
      shipping_preference: "NO_SHIPPING",
      return_url: returnUrl,
      cancel_url: cancelUrl
    }
  });

  if (!ok(response)) throw paypalError("create subscription", response);

  return response.body;
}

export async function getSubscription(id) {
  const response = await paypal("GET", `/v1/billing/subscriptions/${
    encodeURIComponent(id)
  }`);

  if (response.status === 404) return null;
  if (!ok(response)) throw paypalError("read subscription", response);

  return response.body;
}

/* Stops future renewals. The period already paid for is not refunded. */
export async function cancelSubscription(id, reason) {
  const response = await paypal(
    "POST",
    `/v1/billing/subscriptions/${encodeURIComponent(id)}/cancel`,
    { reason: String(reason).slice(0, 128) }
  );

  /* Already cancelled at PayPal is the state we wanted, not a failure. */
  if (response.status === 422) return false;
  if (!ok(response)) throw paypalError("cancel subscription", response);

  return true;
}

/*
 * Verification is delegated to PayPal rather than reimplemented, because the
 * signature is over a certificate chain PayPal rotates. An event that does not
 * verify is dropped: an unverified "subscription activated" is exactly what an
 * attacker would forge to get the service for free.
 */
export async function verifyWebhook(headers, event) {
  if (!env.paypalWebhookId) {
    throw new Error("PAYPAL_WEBHOOK_ID is not set; webhooks cannot be verified.");
  }

  const required = [
    "paypal-auth-algo",
    "paypal-cert-url",
    "paypal-transmission-id",
    "paypal-transmission-sig",
    "paypal-transmission-time"
  ];

  /* Missing headers can never verify; do not spend a round trip on them. */
  if (required.some(name => !headers[name])) return false;

  const response = await paypal(
    "POST",
    "/v1/notifications/verify-webhook-signature",
    {
      auth_algo: headers["paypal-auth-algo"],
      cert_url: headers["paypal-cert-url"],
      transmission_id: headers["paypal-transmission-id"],
      transmission_sig: headers["paypal-transmission-sig"],
      transmission_time: headers["paypal-transmission-time"],
      webhook_id: env.paypalWebhookId,
      webhook_event: event
    }
  );

  if (!ok(response)) throw paypalError("verify webhook", response);

  return response.body?.verification_status === "SUCCESS";
}

/* The link the customer opens to approve a subscription. */
export function approveLink(resource) {
  const links = Array.isArray(resource?.links) ? resource.links : [];

  return links.find(
    link => link.rel === "approve" || link.rel === "payer-action"
  )?.href || null;
}
