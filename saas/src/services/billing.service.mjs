import * as companies from "../models/company.model.mjs";
import * as subscribers from "../models/subscriber.model.mjs";
import * as paypalEvents from "../models/paypal-event.model.mjs";
import { APP } from "./platform.service.mjs";
import { HttpError } from "../utils/http-error.mjs";

import {
  LIVE_STATUSES,
  approveLink,
  cancelSubscription,
  createSubscription,
  getSubscription,
  paypalConfigured
} from "./paypal.service.mjs";

const RETURN_URL = `${APP}/app?checkout=success`;
const CANCEL_URL = `${APP}/app?checkout=canceled`;

/*
 * Running without payments is supported, so the failure has to say so plainly
 * rather than surfacing as a generic 500 from the first PayPal call.
 */
function requirePayPal() {
  if (!paypalConfigured()) {
    throw new HttpError(
      503,
      "Payments are not configured on this deployment."
    );
  }
}

/*
 * Starts, or resumes, a subscription and returns the PayPal approval link.
 *
 * The tenant row is locked for the duration: without it a double-clicked
 * Activate button creates two PayPal subscriptions for one company, and only
 * one of them would ever be cancellable from the dashboard.
 */
export async function createCheckout(tenantId) {
  requirePayPal();

  return companies.withBillingLock(tenantId, async (tenant, db) => {
    if (!tenant?.topic_key || !tenant.domain) {
      throw new HttpError(400, "Save your company settings first.");
    }

    const existing = tenant.paypal_subscription_id
      ? await getSubscription(tenant.paypal_subscription_id)
      : null;

    if (existing) {
      if (LIVE_STATUSES.includes(existing.status)) {
        throw new HttpError(409, "This company is already subscribed.");
      }

      /*
       * A subscription created but never approved is still approvable, so a
       * customer who closed the PayPal tab gets their original link back rather
       * than a second subscription.
       */
      if (existing.status === "APPROVAL_PENDING") {
        const link = approveLink(existing);

        if (link) return link;
      }
    }

    const subscription = await createSubscription({
      email: tenant.owner_email,
      companyName: tenant.name,
      tenantId: tenant.id,
      returnUrl: RETURN_URL,
      cancelUrl: CANCEL_URL
    });

    const link = approveLink(subscription);

    if (!link) {
      throw new HttpError(502, "PayPal did not return an approval link.");
    }

    /*
     * Recorded before the customer is sent to PayPal, so an approval webhook
     * that arrives while they are still on PayPal's page finds the tenant.
     */
    await companies.setSubscription(db, tenant.id, subscription.id, "approval_pending");

    return link;
  });
}

/*
 * PayPal has no hosted billing portal, so cancelling is done here. It stops
 * future renewals; the period already paid for runs to its end, which is what
 * the terms page promises.
 */
export async function cancelRenewal(tenantId) {
  requirePayPal();

  return companies.withBillingLock(tenantId, async (tenant, db) => {
    if (!tenant?.paypal_subscription_id) {
      throw new HttpError(400, "No subscription to cancel.");
    }

    await cancelSubscription(
      tenant.paypal_subscription_id,
      "Cancelled from the Rnews1 dashboard"
    );

    await companies.setBillingStatus(
      db,
      tenant.id,
      tenant.paypal_subscription_id,
      "cancelled"
    );

    return {
      message: "Renewals stopped. Your feed stays up until the paid period ends."
    };
  });
}

/*
 * Webhook events that change entitlement. Anything else PayPal sends is
 * acknowledged and ignored.
 */
const SUBSCRIPTION_EVENTS = {
  "BILLING.SUBSCRIPTION.ACTIVATED": "active",
  "BILLING.SUBSCRIPTION.RE-ACTIVATED": "active",
  "BILLING.SUBSCRIPTION.UPDATED": null,
  "BILLING.SUBSCRIPTION.CANCELLED": "cancelled",
  "BILLING.SUBSCRIPTION.SUSPENDED": "suspended",
  "BILLING.SUBSCRIPTION.EXPIRED": "expired",
  "BILLING.SUBSCRIPTION.PAYMENT.FAILED": "past_due"
};

export async function processPayPalEvent(event) {
  const type = event?.event_type;
  const resource = event?.resource;

  if (!type || !resource) return;

  /* PayPal retries; the event id makes a retry a no-op. */
  const fresh = await paypalEvents.record({
    id: String(event.id),
    kind: type,
    resourceId: resource.id ? String(resource.id) : null
  });

  if (!fresh) return;

  if (type === "PAYMENT.SALE.COMPLETED") {
    /*
     * Money actually moved on a renewal. PayPal reports the subscription as
     * billing_agreement_id on a sale.
     */
    const subscriptionId = resource.billing_agreement_id;

    if (subscriptionId &&
        await companies.syncSubscription({ subscriptionId, status: "active" })) {
      await enrolOwnerFor(subscriptionId);
    }

    return;
  }

  if (!(type in SUBSCRIPTION_EVENTS)) return;

  const subscriptionId = resource.id;

  if (!subscriptionId) return;

  /*
   * UPDATED carries no fixed meaning, so the authoritative state is read back
   * from PayPal rather than inferred from the event.
   */
  const status = SUBSCRIPTION_EVENTS[type] ??
    (await getSubscription(subscriptionId))?.status?.toLowerCase();

  if (!status) return;

  const synced = await companies.syncSubscription({ subscriptionId, status });

  if (!synced) {
    console.error(
      `PayPal subscription ${subscriptionId} matched no tenant. Ignored.`
    );

    return;
  }

  if (status === "active") {
    await enrolOwnerFor(subscriptionId);
  }
}

/*
 * The owner is the first of the ten stakeholders, enrolled as soon as they have
 * paid. Failing here must not fail the webhook: PayPal would retry an event
 * whose real work — granting access — has already been done.
 */
async function enrolOwnerFor(subscriptionId) {
  try {
    await companies.withOwnerOfSubscription(subscriptionId, (tenant, db) =>
      subscribers.enrolOwner(db, tenant.id, tenant.owner_email));
  } catch (error) {
    console.error(
      `Could not enrol owner for subscription ${subscriptionId}:`,
      error.message
    );
  }
}
