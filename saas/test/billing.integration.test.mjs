/*
 * The PayPal subscription lifecycle against a real Postgres, with PayPal
 * stubbed at the fetch boundary. Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("billing end to end", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { resetTokenCache } = await import("../src/config/paypal.mjs");
  const billing = await import("../src/services/billing.service.mjs");
  const auth = await import("../src/models/auth.model.mjs");
  const companies = await import("../src/models/company.model.mjs");
  const { hash, token } = await import("../src/services/platform.service.mjs");

  const realFetch = globalThis.fetch;

  after(async () => {
    globalThis.fetch = realFetch;
    await pool.end();
  });

  beforeEach(async () => {
    globalThis.fetch = realFetch;
    resetTokenCache();

    await pool.query(
      `TRUNCATE tenants, topics, contacts, subscribers, outbox, briefs,
                mailgun_events, paypal_events, paypal_plans, stories,
                newsletter_picks, advertisers, campaigns, creatives,
                ad_placements, ad_events, login_tokens, sessions
       RESTART IDENTITY CASCADE`
    );
  });

  const APPROVE = "https://www.sandbox.paypal.com/webapps/billing?token=X";

  let nextSubscription = 0;

  function stubPayPal(overrides = {}) {
    const calls = [];

    const routes = {
      "/v1/oauth2/token": { body: { access_token: "A", expires_in: 32000 } },
      "/v1/catalogs/products": { body: { id: "PROD-1" } },
      "/v1/billing/plans": { body: { id: "P-PLAN1" } },
      "/v1/billing/subscriptions": {
        body: {
          id: `I-SUB${++nextSubscription}`,
          status: "APPROVAL_PENDING",
          links: [{ rel: "approve", href: APPROVE }]
        }
      },
      ...overrides
    };

    globalThis.fetch = async (url, init) => {
      const path = new URL(String(url)).pathname;

      calls.push({ path, method: init.method });

      const route = Object.entries(routes)
        .find(([pattern]) => path === pattern || path.startsWith(`${pattern}/`))?.[1];

      if (!route) return new Response("{}", { status: 404 });

      const { status = 200, body = {} } = route;

      /* 204 must not carry a body: Response rejects one. */
      return new Response(
        status === 204 ? null : JSON.stringify(body),
        { status }
      );
    };

    return calls;
  }

  async function settledTenant() {
    const tenantId = await auth.createLogin({
      email: "owner@acme.test",
      tokenHash: hash(token()),
      url: "u"
    });

    await companies.saveSettings(tenantId, {
      name: "Acme Robotics",
      domain: "acme.test",
      industry: "Robotics",
      keywords: [],
      language: "en"
    }, { key: hash("en:acme"), query: '"Robotics"' });

    return tenantId;
  }

  const billingStatus = async id =>
    (await pool.query(
      "SELECT billing_status, paypal_subscription_id FROM tenants WHERE id=$1",
      [id]
    )).rows[0];

  describe("createCheckout", () => {
    it("refuses before the company settings are saved", async () => {
      const tenantId = await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(token()),
        url: "u"
      });

      stubPayPal();

      await assert.rejects(
        () => billing.createCheckout(tenantId),
        /Save your company settings first/
      );
    });

    it("creates the plan once and returns the approval link", async () => {
      const tenantId = await settledTenant();

      const calls = stubPayPal({
        "/v1/billing/subscriptions": {
          body: {
            id: "I-SUB1",
            status: "APPROVAL_PENDING",
            links: [{ rel: "approve", href: APPROVE }]
          }
        }
      });

      assert.equal(await billing.createCheckout(tenantId), APPROVE);

      assert.deepEqual(await billingStatus(tenantId), {
        billing_status: "approval_pending",
        paypal_subscription_id: "I-SUB1"
      });

      const plan = await pool.query("SELECT * FROM paypal_plans");

      assert.equal(plan.rowCount, 1);
      assert.equal(plan.rows[0].plan_id, "P-PLAN1");
      assert.equal(plan.rows[0].amount_cents, 2500);

      /* A second tenant reuses the stored plan rather than creating another. */
      const second = await settledTenant2();
      const before = calls.filter(c => c.path === "/v1/billing/plans").length;

      stubPayPal({
        "/v1/billing/subscriptions": {
          body: {
            id: "I-SUB2",
            status: "APPROVAL_PENDING",
            links: [{ rel: "approve", href: APPROVE }]
          }
        }
      });

      await billing.createCheckout(second);

      assert.equal(
        calls.filter(c => c.path === "/v1/billing/plans").length,
        before,
        "plan was reused"
      );
    });

    async function settledTenant2() {
      const tenantId = await auth.createLogin({
        email: "other@beta.test",
        tokenHash: hash(token()),
        url: "u"
      });

      await companies.saveSettings(tenantId, {
        name: "Beta",
        domain: "beta.test",
        industry: "Robotics",
        keywords: [],
        language: "en"
      }, { key: hash("en:acme"), query: '"Robotics"' });

      return tenantId;
    }

    it("hands back the original link instead of subscribing twice", async () => {
      const tenantId = await settledTenant();

      stubPayPal();
      await billing.createCheckout(tenantId);

      /* Second click: PayPal still reports the subscription as unapproved. */
      const calls = stubPayPal({
        "/v1/billing/subscriptions": {
          body: {
            id: "I-SUB1",
            status: "APPROVAL_PENDING",
            links: [{ rel: "approve", href: APPROVE }]
          }
        }
      });

      assert.equal(await billing.createCheckout(tenantId), APPROVE);

      assert.equal(
        calls.filter(c =>
          c.path === "/v1/billing/subscriptions" && c.method === "POST"
        ).length,
        0,
        "no second subscription was created"
      );
    });

    it("refuses to sell a second subscription to an active tenant", async () => {
      const tenantId = await settledTenant();

      stubPayPal();
      await billing.createCheckout(tenantId);

      stubPayPal({
        "/v1/billing/subscriptions": { body: { id: "I-SUB1", status: "ACTIVE" } }
      });

      await assert.rejects(
        () => billing.createCheckout(tenantId),
        /already subscribed/
      );
    });
  });

  describe("cancelRenewal", () => {
    it("cancels at PayPal and marks the tenant", async () => {
      const tenantId = await settledTenant();

      stubPayPal();
      await billing.createCheckout(tenantId);
      await companies.syncSubscription({
        subscriptionId: "I-SUB1",
        status: "active"
      });

      const calls = stubPayPal({
        "/v1/billing/subscriptions": { status: 204, body: {} }
      });

      const result = await billing.cancelRenewal(tenantId);

      assert.match(result.message, /Renewals stopped/);
      assert.ok(calls.some(c => c.path.endsWith("/cancel")));

      assert.equal(
        (await billingStatus(tenantId)).billing_status,
        "cancelled"
      );
    });

    it("refuses when there is nothing to cancel", async () => {
      const tenantId = await settledTenant();

      stubPayPal();

      await assert.rejects(
        () => billing.cancelRenewal(tenantId),
        /No subscription to cancel/
      );
    });
  });

  describe("processPayPalEvent", () => {
    /* Returns the id PayPal actually issued, rather than assuming one. */
    async function subscribed() {
      const tenantId = await settledTenant();

      stubPayPal();
      await billing.createCheckout(tenantId);

      const { paypal_subscription_id: subscriptionId } =
        await billingStatus(tenantId);

      return { tenantId, subscriptionId };
    }

    const event = (type, resource, id = `WH-${Math.random()}`) =>
      ({ id, event_type: type, resource });

    it("activates the tenant on approval", async () => {
      const { tenantId, subscriptionId } = await subscribed();

      await billing.processPayPalEvent(
        event("BILLING.SUBSCRIPTION.ACTIVATED", { id: subscriptionId })
      );

      assert.equal((await billingStatus(tenantId)).billing_status, "active");
    });

    it("applies a redelivered event exactly once", async () => {
      const { tenantId, subscriptionId } = await subscribed();

      const activated = event(
        "BILLING.SUBSCRIPTION.ACTIVATED",
        { id: subscriptionId },
        "WH-SAME"
      );

      await billing.processPayPalEvent(activated);

      /* PayPal retries; a retry must not undo a later cancellation. */
      await billing.processPayPalEvent(
        event("BILLING.SUBSCRIPTION.CANCELLED", { id: subscriptionId })
      );

      await billing.processPayPalEvent(activated);

      assert.equal((await billingStatus(tenantId)).billing_status, "cancelled");

      const stored = await pool.query("SELECT count(*)::int AS n FROM paypal_events");
      assert.equal(stored.rows[0].n, 2);
    });

    it("maps every lifecycle event to a billing status", async () => {
      const { tenantId, subscriptionId } = await subscribed();

      for (const [type, expected] of [
        ["BILLING.SUBSCRIPTION.ACTIVATED", "active"],
        ["BILLING.SUBSCRIPTION.SUSPENDED", "suspended"],
        ["BILLING.SUBSCRIPTION.PAYMENT.FAILED", "past_due"],
        ["BILLING.SUBSCRIPTION.CANCELLED", "cancelled"],
        ["BILLING.SUBSCRIPTION.EXPIRED", "expired"]
      ]) {
        await billing.processPayPalEvent(event(type, { id: subscriptionId }));

        assert.equal(
          (await billingStatus(tenantId)).billing_status,
          expected,
          type
        );
      }
    });

    it("treats a completed renewal payment as proof of an active plan", async () => {
      const { tenantId, subscriptionId } = await subscribed();

      await billing.processPayPalEvent(event("PAYMENT.SALE.COMPLETED", {
        id: "SALE-1",
        billing_agreement_id: subscriptionId
      }));

      assert.equal((await billingStatus(tenantId)).billing_status, "active");
    });

    it("ignores an event for a subscription belonging to nobody", async () => {
      const { tenantId } = await subscribed();

      await billing.processPayPalEvent(
        event("BILLING.SUBSCRIPTION.CANCELLED", { id: "I-SOMEONE-ELSE" })
      );

      assert.equal(
        (await billingStatus(tenantId)).billing_status,
        "approval_pending",
        "untouched"
      );
    });

    it("ignores events it has no opinion about", async () => {
      await subscribed();

      await assert.doesNotReject(() => Promise.all([
        billing.processPayPalEvent(event("CATALOG.PRODUCT.CREATED", { id: "P" })),
        billing.processPayPalEvent({ id: "WH-X" }),
        billing.processPayPalEvent({})
      ]));
    });
  });
});
