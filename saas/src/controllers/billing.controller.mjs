import * as billing from "../services/billing.service.mjs";

export async function checkout(req, res) {
  const url = await billing.createCheckout(req.tenant.id);
  res.json({ url });
}

/*
 * PayPal has no hosted billing portal, so cancelling happens here rather than
 * by redirecting the customer somewhere else.
 */
export async function cancel(req, res) {
  res.json(await billing.cancelRenewal(req.tenant.id));
}
