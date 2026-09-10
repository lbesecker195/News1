/*
 * Staff authentication and the ad-management surface behind it.
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("admin", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const admins = await import("../src/models/admin.model.mjs");

  const PASSWORD = "staff password 1";
  const EMAIL = "staff@rnews1.test";

  let server;
  let base;

  before(async () => {
    server = createApp().listen(0);
    await new Promise(resolve => server.once("listening", resolve));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    server?.close();
    await pool.end();
  });

  beforeEach(async () => {
    await pool.query(
      `TRUNCATE admins, admin_sessions, advertisers, campaigns, creatives,
                ad_placements, ad_events RESTART IDENTITY CASCADE`
    );

    await admins.upsert({ email: EMAIL, password: PASSWORD });
  });

  const ORIGIN = process.env.APP_ORIGIN;

  const post = (path, body, cookie) => fetch(base + path, {
    method: "POST",
    redirect: "manual",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      origin: ORIGIN,
      ...(cookie ? { cookie } : {})
    },
    body: new URLSearchParams(body).toString()
  });

  async function signIn() {
    const response = await post("/admin/login", {
      email: EMAIL,
      password: PASSWORD
    });

    assert.equal(response.status, 302);

    const cookie = response.headers.getSetCookie()
      .find(value => value.startsWith("admin_session="));

    assert.ok(cookie, "a session cookie was set");

    return cookie.split(";")[0];
  }

  describe("authentication", () => {
    it("sends an unauthenticated visitor to the sign-in page", async () => {
      const response = await fetch(base + "/admin", { redirect: "manual" });

      assert.equal(response.status, 302);
      assert.match(response.headers.get("location"), /\/admin\/login$/);
    });

    it("answers a wrong password and an unknown address identically", async () => {
      const wrong = await post("/admin/login", {
        email: EMAIL,
        password: "not the password"
      });

      const unknown = await post("/admin/login", {
        email: "nobody@rnews1.test",
        password: PASSWORD
      });

      assert.equal(wrong.status, 401);
      assert.equal(unknown.status, 401);

      const [a, b] = await Promise.all([wrong.text(), unknown.text()]);

      /* Identical bodies: no way to learn which addresses are staff. */
      assert.equal(a, b);
      assert.match(a, /not recognised/);
    });

    it("issues an httpOnly session cookie scoped to /admin", async () => {
      const response = await post("/admin/login", {
        email: EMAIL,
        password: PASSWORD
      });

      const cookie = response.headers.getSetCookie()
        .find(value => value.startsWith("admin_session="));

      assert.match(cookie, /HttpOnly/i);
      assert.match(cookie, /Path=\/admin/i);
      assert.match(cookie, /SameSite=Lax/i);
    });

    it("lets a signed-in admin in, and out again", async () => {
      const cookie = await signIn();

      const page = await fetch(base + "/admin", { headers: { cookie } });

      assert.equal(page.status, 200);
      assert.match(await page.text(), /Signed in as staff@rnews1\.test/);

      await post("/admin/logout", {}, cookie);

      const after = await fetch(base + "/admin", {
        headers: { cookie },
        redirect: "manual"
      });

      assert.equal(after.status, 302, "the session was destroyed server-side");
    });

    it("rejects a forged session cookie", async () => {
      const response = await fetch(base + "/admin", {
        headers: { cookie: "admin_session=made-up-value" },
        redirect: "manual"
      });

      assert.equal(response.status, 302);
    });

    it("does not accept a tenant session as an admin session", async () => {
      const response = await fetch(base + "/admin", {
        headers: { cookie: "session=whatever" },
        redirect: "manual"
      });

      assert.equal(response.status, 302);
    });

    it("blocks a cross-origin post", async () => {
      const cookie = await signIn();

      const response = await fetch(base + "/admin/advertisers", {
        method: "POST",
        redirect: "manual",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          origin: "https://evil.test",
          cookie
        },
        body: "name=Injected"
      });

      assert.equal(response.status, 403);

      const { rows } = await pool.query("SELECT count(*)::int AS n FROM advertisers");
      assert.equal(rows[0].n, 0);
    });

    it("keeps /admin out of search results", async () => {
      const response = await fetch(base + "/admin/login");

      assert.match(response.headers.get("x-robots-tag"), /noindex/);
      assert.match(response.headers.get("cache-control"), /no-store/);
    });
  });

  describe("managing inventory", () => {
    it("creates an advertiser, a targeted campaign and a creative", async () => {
      const cookie = await signIn();

      await post("/admin/advertisers", { name: "Forklift Co" }, cookie);

      const advertiser = await pool.query("SELECT id, name FROM advertisers");
      assert.equal(advertiser.rows[0].name, "Forklift Co");

      await post("/admin/campaigns", {
        advertiser_id: advertiser.rows[0].id,
        name: "Q4",
        starts_on: "2026-09-01",
        ends_on: "2026-12-31",
        cpm_cents: "2500",
        daily_cap: "0",
        total_cap: "0",
        titles: "%vp%, %head of%",
        industries: "Logistics",
        topics: ""
      }, cookie);

      const campaign = await pool.query("SELECT id, status, targeting FROM campaigns");

      assert.equal(campaign.rows[0].status, "draft", "campaigns start as drafts");
      assert.deepEqual(campaign.rows[0].targeting, {
        titles: ["%vp%", "%head of%"],
        industries: ["Logistics"],
        /* An empty dimension restricts nothing. */
        topics: []
      });

      await post("/admin/creatives", {
        campaign_id: campaign.rows[0].id,
        slot: "sponsored_story",
        headline: "Cut pick times",
        body: "A case study.",
        cta: "Read it",
        click_url: "https://forklift.example/x"
      }, cookie);

      const creative = await pool.query("SELECT slot, click_url FROM creatives");
      assert.equal(creative.rows[0].slot, "sponsored_story");

      await post(
        `/admin/campaigns/${campaign.rows[0].id}/status`,
        { status: "active" },
        cookie
      );

      const activated = await pool.query("SELECT status FROM campaigns");
      assert.equal(activated.rows[0].status, "active");
    });

    it("refuses a creative whose click URL is not http", async () => {
      const cookie = await signIn();

      await post("/admin/advertisers", { name: "Nasty" }, cookie);
      const advertiser = await pool.query("SELECT id FROM advertisers");

      await post("/admin/campaigns", {
        advertiser_id: advertiser.rows[0].id,
        name: "C",
        starts_on: "2026-09-01",
        ends_on: "2026-12-31",
        cpm_cents: "0",
        daily_cap: "0",
        total_cap: "0"
      }, cookie);

      const campaign = await pool.query("SELECT id FROM campaigns");

      for (const click_url of [
        "javascript:alert(1)",
        "data:text/html,<script>x</script>"
      ]) {
        const response = await post("/admin/creatives", {
          campaign_id: campaign.rows[0].id,
          slot: "banner",
          headline: "Bad",
          body: "Bad",
          click_url
        }, cookie);

        assert.equal(response.status, 400, click_url);
      }

      const { rows } = await pool.query("SELECT count(*)::int AS n FROM creatives");
      assert.equal(rows[0].n, 0);
    });

    it("refuses a campaign that ends before it starts", async () => {
      const cookie = await signIn();

      await post("/admin/advertisers", { name: "Backwards" }, cookie);
      const advertiser = await pool.query("SELECT id FROM advertisers");

      const response = await post("/admin/campaigns", {
        advertiser_id: advertiser.rows[0].id,
        name: "C",
        starts_on: "2026-12-31",
        ends_on: "2026-09-01",
        cpm_cents: "0",
        daily_cap: "0",
        total_cap: "0"
      }, cookie);

      assert.equal(response.status, 400);
    });

    it("refuses an unknown campaign status", async () => {
      const cookie = await signIn();

      const response = await post(
        "/admin/campaigns/550e8400-e29b-41d4-a716-446655440000/status",
        { status: "definitely-not-a-status" },
        cookie
      );

      assert.equal(response.status, 400);
    });
  });
});
