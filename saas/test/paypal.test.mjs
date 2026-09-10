import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, it } from "node:test";

import { resetTokenCache } from "../src/config/paypal.mjs";
import {
  approveLink,
  verifyWebhook
} from "../src/services/paypal.service.mjs";

const realFetch = globalThis.fetch;

/* Answers as PayPal does, and records what it was asked. */
function stubPayPal(routes) {
  const calls = [];

  globalThis.fetch = async (url, init) => {
    const path = new URL(String(url)).pathname;

    calls.push({
      path,
      method: init.method,
      body: init.body && init.headers?.["content-type"] === "application/json"
        ? JSON.parse(init.body)
        : init.body,
      auth: init.headers?.authorization
    });

    const route = routes[path];

    if (!route) return new Response("{}", { status: 404 });

    const { status = 200, body = {} } = typeof route === "function"
      ? route(calls.length)
      : route;

    return new Response(JSON.stringify(body), { status });
  };

  return calls;
}

const TOKEN_ROUTE = {
  "/v1/oauth2/token": { body: { access_token: "A-TOKEN", expires_in: 32000 } }
};

const HEADERS = {
  "paypal-auth-algo": "SHA256withRSA",
  "paypal-cert-url": "https://api.paypal.com/cert.pem",
  "paypal-transmission-id": "tx-1",
  "paypal-transmission-sig": "sig",
  "paypal-transmission-time": "2026-09-10T07:00:00Z"
};

beforeEach(() => resetTokenCache());
afterEach(() => {
  globalThis.fetch = realFetch;
  resetTokenCache();
});

describe("approveLink", () => {
  it("finds the link a customer opens", () => {
    assert.equal(
      approveLink({
        links: [
          { rel: "self", href: "https://api/x" },
          { rel: "approve", href: "https://paypal/approve" }
        ]
      }),
      "https://paypal/approve"
    );

    /* Some resources use payer-action instead. */
    assert.equal(
      approveLink({ links: [{ rel: "payer-action", href: "https://p/a" }] }),
      "https://p/a"
    );
  });

  it("returns null rather than undefined when there is no link", () => {
    assert.equal(approveLink({ links: [] }), null);
    assert.equal(approveLink({}), null);
    assert.equal(approveLink(null), null);
  });
});

describe("verifyWebhook", () => {
  it("accepts an event PayPal confirms", async () => {
    const calls = stubPayPal({
      ...TOKEN_ROUTE,
      "/v1/notifications/verify-webhook-signature": {
        body: { verification_status: "SUCCESS" }
      }
    });

    assert.equal(await verifyWebhook(HEADERS, { id: "WH-1" }), true);

    const verify = calls.find(call => call.path.includes("verify-webhook"));

    assert.equal(verify.auth, "Bearer A-TOKEN");
    assert.equal(verify.body.webhook_id, process.env.PAYPAL_WEBHOOK_ID);
    assert.equal(verify.body.transmission_id, "tx-1");
    assert.deepEqual(verify.body.webhook_event, { id: "WH-1" });
  });

  it("rejects an event PayPal does not confirm", async () => {
    stubPayPal({
      ...TOKEN_ROUTE,
      "/v1/notifications/verify-webhook-signature": {
        body: { verification_status: "FAILURE" }
      }
    });

    assert.equal(await verifyWebhook(HEADERS, { id: "WH-1" }), false);
  });

  it("refuses without spending a round trip when headers are missing", async () => {
    const calls = stubPayPal(TOKEN_ROUTE);

    for (const missing of Object.keys(HEADERS)) {
      const headers = { ...HEADERS };
      delete headers[missing];

      assert.equal(
        await verifyWebhook(headers, { id: "WH-1" }),
        false,
        `missing ${missing}`
      );
    }

    assert.equal(calls.length, 0, "PayPal was never called");
  });

  it("raises rather than silently passing when PayPal is unreachable", async () => {
    stubPayPal({
      ...TOKEN_ROUTE,
      "/v1/notifications/verify-webhook-signature": { status: 500, body: {} }
    });

    await assert.rejects(
      () => verifyWebhook(HEADERS, { id: "WH-1" }),
      /verify webhook failed \(500\)/
    );
  });
});

describe("access token", () => {
  it("is minted once and reused", async () => {
    const calls = stubPayPal({
      ...TOKEN_ROUTE,
      "/v1/notifications/verify-webhook-signature": {
        body: { verification_status: "SUCCESS" }
      }
    });

    await verifyWebhook(HEADERS, { id: "WH-1" });
    await verifyWebhook(HEADERS, { id: "WH-2" });

    assert.equal(
      calls.filter(call => call.path === "/v1/oauth2/token").length,
      1,
      "second call reused the cached token"
    );
  });

  it("re-mints once when a cached token has been revoked", async () => {
    let verifyAttempts = 0;

    const calls = stubPayPal({
      ...TOKEN_ROUTE,
      "/v1/notifications/verify-webhook-signature": () => {
        verifyAttempts++;

        return verifyAttempts === 1
          ? { status: 401, body: { error: "invalid_token" } }
          : { status: 200, body: { verification_status: "SUCCESS" } };
      }
    });

    assert.equal(await verifyWebhook(HEADERS, { id: "WH-1" }), true);

    assert.equal(
      calls.filter(call => call.path === "/v1/oauth2/token").length,
      2,
      "token was re-minted exactly once"
    );
  });

  it("reports a credential failure clearly", async () => {
    stubPayPal({
      "/v1/oauth2/token": {
        status: 401,
        body: { error: "invalid_client" }
      }
    });

    await assert.rejects(
      () => verifyWebhook(HEADERS, { id: "WH-1" }),
      /PayPal authentication failed \(401\)/
    );
  });
});

describe("when PayPal is not configured", () => {
  /*
   * Running without payments is a supported state — the app is developed and
   * demoed that way — so the billing paths must refuse clearly rather than
   * failing somewhere inside the PayPal client.
   *
   * Configuration is read once at import, so this runs in a child process with
   * a different environment rather than trying to mutate a cached module.
   */
  const run = source => {
    const { status, stdout, stderr } = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", source],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PAYPAL_CLIENT_ID: "",
          PAYPAL_CLIENT_SECRET: "",
          PAYPAL_WEBHOOK_ID: ""
        }
      }
    );

    assert.equal(status, 0, stderr);

    return stdout.trim();
  };

  it("reports itself as unconfigured", () => {
    assert.equal(
      run(`
        const { paypalConfigured } = await import("./src/config/paypal.mjs");
        console.log(paypalConfigured());
      `),
      "false"
    );
  });

  it("refuses to subscribe with a 503 rather than a generic failure", () => {
    assert.equal(
      run(`
        const billing = await import("./src/services/billing.service.mjs");

        try {
          await billing.createCheckout("550e8400-e29b-41d4-a716-446655440000");
          console.log("NO ERROR");
        } catch (error) {
          console.log(\`\${error.status} \${error.message}\`);
        }
      `),
      "503 Payments are not configured on this deployment."
    );
  });

  it("does not stop the web app from booting", () => {
    assert.equal(
      run(`
        const { createApp } = await import("./src/app.mjs");
        console.log(typeof createApp() === "function" ? "booted" : "failed");
      `),
      "booted"
    );
  });
});
