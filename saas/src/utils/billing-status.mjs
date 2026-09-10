/*
 * PayPal reports a subscription in its trial period as ACTIVE, so there is no
 * separate state to honour here — unlike Stripe, which distinguishes trialing.
 * Kept in one place so the public feed and the invitation flow never disagree
 * about who is entitled to the service.
 */
export const ACTIVE_BILLING_STATUSES = ["active"];

export const isBillingActive = status =>
  ACTIVE_BILLING_STATUSES.includes(status);
