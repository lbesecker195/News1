import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";

import { createApp } from "../src/app.mjs";

/*
 * Boots the real Express app and drives it over HTTP. Every route exercised
 * here answers without touching Postgres, which is what makes it runnable in
 * CI without a database.
 */
let server;
let base;

before(async () => {
  server = createApp().listen(0);
  await new Promise(resolve => server.once("listening", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server?.close());

const get = (path, init) =>
  fetch(base + path, { redirect: "manual", ...init });

describe("public pages", () => {
  for (const [path, needle] of [
    ["/", "Made for One"],
    ["/privacy", "Privacy"],
    ["/login", "Sign in to Rnews1"],
    ["/register", "Create your Rnews1 account"],
    ["/terms", "Service terms"]
  ]) {
    it(`GET ${path} renders`, async () => {
      const response = await get(path);

      assert.equal(response.status, 200);
      assert.match(response.headers.get("content-type"), /text\/html/);
      assert.ok((await response.text()).includes(needle));
    });
  }

  it("serves the browser assets", async () => {
    for (const [path, type] of [["/site.css", /css/], ["/app.js", /javascript/]]) {
      const response = await get(path);

      assert.equal(response.status, 200, path);
      assert.match(response.headers.get("content-type"), type);
    }
  });

  it("sets the security headers", async () => {
    const headers = (await get("/")).headers;

    assert.match(headers.get("content-security-policy"), /script-src 'self'/);
    assert.equal(headers.get("x-frame-options"), "SAMEORIGIN");
    assert.equal(headers.get("x-powered-by"), null);
  });
});

describe("not found", () => {
  it("renders a page for the site and JSON for the API", async () => {
    const page = await get("/no-such-page");

    assert.equal(page.status, 404);
    assert.ok((await page.text()).includes("Page not found"));

    /* Unknown API paths hit the auth guard first, and should: an anonymous
     * caller learns nothing about which endpoints exist. */
    const api = await get("/api/no-such-endpoint");

    assert.equal(api.status, 401);
    assert.deepEqual(await api.json(), { error: "Sign in first." });
  });
});

describe("token-shaped routes", () => {
  const uuid = "550e8400-e29b-41d4-a716-446655440000";

  it("rejects malformed tokens before any database work", async () => {
    for (const [path, status] of [
      ["/login/short", 400],
      [`/login/${"a".repeat(43)}`, 200],
      ["/confirm/not-a-uuid", 400],
      [`/confirm/${uuid}`, 200],
      ["/u/not-a-uuid", 400],
      [`/u/${uuid}`, 200]
    ]) {
      assert.equal((await get(path)).status, status, path);
    }
  });

  it("never caches a page that carries a token", async () => {
    for (const path of [`/login/${"a".repeat(43)}`, `/confirm/${uuid}`]) {
      assert.equal(
        (await get(path)).headers.get("cache-control"),
        "no-store",
        path
      );
    }
  });
});

describe("rate limiting", () => {
  /*
   * Requesting a link and following one used to share a five-per-hour budget,
   * which meant a few sign-in attempts could lock someone out of an account
   * they held a valid link for. They are separate acts with separate limits.
   */
  it("does not spend the request budget on following a link", async () => {
    const token = "b".repeat(43);

    /* Well past the five-per-hour limit on requesting a link. */
    for (let n = 0; n < 12; n++) {
      const response = await get(`/login/${token}`, {
        method: "POST",
        headers: { origin: process.env.APP_ORIGIN }
      });

      /*
       * The status varies — an unknown token is a 400, and this file runs
       * without a database so the lookup 500s. What matters is that it is
       * never 429: the budget for following links is its own.
       */
      assert.notEqual(response.status, 429, `attempt ${n + 1} was throttled`);
    }
  });
});

describe("access control", () => {
  it("redirects a signed-out visitor away from the dashboard", async () => {
    const response = await get("/app");

    assert.equal(response.status, 302);
    assert.equal(response.headers.get("location"), "/");
  });

  it("answers API calls without a session with 401 JSON", async () => {
    const response = await get("/api/me");

    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: "Sign in first." });
  });

  it("blocks a cross-origin mutation", async () => {
    const response = await get("/api/company", {
      method: "POST",
      headers: { origin: "https://evil.test", "content-type": "application/json" },
      body: "{}"
    });

    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: "Invalid request origin." });
  });

  it("lets a same-origin mutation through to the auth check", async () => {
    const response = await get("/api/company", {
      method: "POST",
      headers: {
        origin: process.env.APP_ORIGIN,
        "content-type": "application/json"
      },
      body: "{}"
    });

    assert.equal(response.status, 401);
  });

  it("does not require an origin for a one-click unsubscribe POST", async () => {
    const response = await get("/u/not-a-uuid", { method: "POST" });

    /* 400 for the malformed token, not 403 for a missing origin. */
    assert.equal(response.status, 400);
  });
});

describe("feed tokens", () => {
  /*
   * Only the malformed cases belong here: a well-formed token reaches
   * Postgres, and this file runs without one. The publish gate itself is
   * covered in feed.integration.test.mjs.
   */
  it("404s a malformed feed token before touching the database", async () => {
    assert.equal((await get("/embed/not-a-uuid")).status, 404);
    assert.equal((await get("/news/not-a-uuid/abc")).status, 404);
  });
});

describe("paypal webhook", () => {
  it("refuses an event whose signature headers are missing", async () => {
    const response = await get("/webhooks/paypal", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        id: "WH-TEST",
        event_type: "BILLING.SUBSCRIPTION.ACTIVATED",
        resource: { id: "I-FORGED" }
      })
    });

    /*
     * Rejected before any PayPal round trip: the verification headers are not
     * there, so this can only be a forgery or a misconfigured sender.
     */
    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: "Invalid PayPal signature." });
  });
});
