/*
 * The ad server: who a campaign reaches, when it stops, and what a click is
 * worth. Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("ad server", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool, transaction } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const ads = await import("../src/models/ad.model.mjs");
  const { selectAds } = await import("../src/services/ad.service.mjs");

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

  beforeEach(() => pool.query(
    `TRUNCATE advertisers, campaigns, creatives, ad_placements, ad_events,
              contacts RESTART IDENTITY CASCADE`
  ));

  const TODAY = "2026-09-10";

  async function campaign({
    name = "Test",
    targeting = {},
    slot = "sponsored_story",
    dailyCap = 0,
    totalCap = 0,
    cpm = 100,
    status = "active",
    starts = "2026-09-01",
    ends = "2026-12-31",
    clickUrl = "https://advertiser.example/offer"
  } = {}) {
    const advertiser = await pool.query(
      "INSERT INTO advertisers(name) VALUES($1) RETURNING id",
      [`${name} Inc`]
    );

    const created = await pool.query(
      `INSERT INTO campaigns(
         advertiser_id, name, status, starts_on, ends_on,
         daily_cap, total_cap, cpm_cents, targeting
       )
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
       RETURNING id`,
      [
        advertiser.rows[0].id, name, status, starts, ends,
        dailyCap, totalCap, cpm, JSON.stringify(targeting)
      ]
    );

    await pool.query(
      `INSERT INTO creatives(campaign_id, slot, headline, body, cta, click_url)
       VALUES($1,$2,$3,'Body copy.','Learn more',$4)`,
      [created.rows[0].id, slot, `${name} headline`, clickUrl]
    );

    return created.rows[0].id;
  }

  async function contact({ title = null, industry = null } = {}) {
    const { rows } = await pool.query(
      `INSERT INTO contacts(email, title, industry)
       VALUES($1,$2,$3) RETURNING id, title, industry`,
      [`reader-${Math.random().toString(36).slice(2)}@x.test`, title, industry]
    );

    return rows[0];
  }

  const serve = (reader, topicTerms = []) => transaction(db => selectAds(db, {
    contact: reader,
    tenantId: null,
    issueDate: TODAY,
    topicTerms
  }));

  describe("targeting", () => {
    it("delivers an untargeted campaign to anybody", async () => {
      await campaign({ name: "Everyone" });

      const { sponsored } = await serve(await contact());

      assert.equal(sponsored.headline, "Everyone headline");
    });

    it("matches a job title case-insensitively, by pattern", async () => {
      await campaign({ name: "Execs", targeting: { titles: ["%vp%"] } });

      const hit = await serve(await contact({ title: "VP of Engineering" }));
      assert.equal(hit.sponsored.headline, "Execs headline");

      const lower = await serve(await contact({ title: "svp, platform" }));
      assert.equal(lower.sponsored.headline, "Execs headline");

      const miss = await serve(await contact({ title: "Software Engineer" }));
      assert.equal(miss.sponsored, null);
    });

    it("does not deliver a targeted campaign to an unenriched reader", async () => {
      await campaign({ name: "Execs", targeting: { titles: ["%vp%"] } });

      /* No title on file is not a match — it is an unknown. */
      const { sponsored } = await serve(await contact());

      assert.equal(sponsored, null);
    });

    it("matches industry exactly, ignoring case", async () => {
      await campaign({ name: "SaaSOnly", targeting: { industries: ["SaaS"] } });

      const hit = await serve(await contact({ industry: "saas" }));
      assert.equal(hit.sponsored.headline, "SaaSOnly headline");

      const miss = await serve(await contact({ industry: "Manufacturing" }));
      assert.equal(miss.sponsored, null);
    });

    it("requires every restricted dimension to match", async () => {
      await campaign({
        name: "Both",
        targeting: { titles: ["%vp%"], industries: ["SaaS"] }
      });

      const both = await serve(await contact({ title: "VP Sales", industry: "SaaS" }));
      assert.equal(both.sponsored.headline, "Both headline");

      const halfway = await serve(
        await contact({ title: "VP Sales", industry: "Mining" })
      );
      assert.equal(halfway.sponsored, null);
    });

    it("matches contextually on the topic of the issue", async () => {
      await campaign({ name: "Robotics", targeting: { topics: ["robotics"] } });

      const onTopic = await serve(await contact(), ["Robotics", "grippers"]);
      assert.equal(onTopic.sponsored.headline, "Robotics headline");

      const offTopic = await serve(await contact(), ["shipping"]);
      assert.equal(offTopic.sponsored, null);
    });
  });

  describe("eligibility", () => {
    it("ignores campaigns that are not active or not in flight", async () => {
      await campaign({ name: "Draft", status: "draft" });
      await campaign({ name: "Paused", status: "paused" });
      await campaign({ name: "Ended", starts: "2026-01-01", ends: "2026-01-31" });
      await campaign({ name: "Future", starts: "2027-01-01", ends: "2027-12-31" });

      const { sponsored } = await serve(await contact());

      assert.equal(sponsored, null);
    });

    it("stops a campaign at its daily cap and resumes the next day", async () => {
      await campaign({ name: "Capped", dailyCap: 2 });

      for (let n = 0; n < 2; n++) {
        assert.ok((await serve(await contact())).sponsored, `serve ${n}`);
      }

      assert.equal((await serve(await contact())).sponsored, null, "capped");

      /* The cap is per issue date, so tomorrow starts fresh. */
      const tomorrow = await transaction(db => selectAds(db, {
        contact: null,
        tenantId: null,
        issueDate: "2026-09-11",
        topicTerms: []
      }));

      assert.ok(tomorrow.sponsored, "next day");
    });

    it("stops a campaign for good at its total cap", async () => {
      await campaign({ name: "Total", totalCap: 1 });

      assert.ok((await serve(await contact())).sponsored);
      assert.equal((await serve(await contact())).sponsored, null);

      assert.equal(await ads.completeFinishedCampaigns(), 1);

      const { rows } = await pool.query("SELECT status FROM campaigns");
      assert.equal(rows[0].status, "completed");
    });

    it("never gives one advertiser two slots in the same issue", async () => {
      const id = await campaign({ name: "Greedy" });

      /* Same campaign, also eligible for the banner slot. */
      await pool.query(
        `INSERT INTO creatives(campaign_id, slot, headline, body, click_url)
         VALUES($1,'banner','Greedy banner','Body.','https://x.test')`,
        [id]
      );

      const { sponsored, banners } = await serve(await contact());

      assert.ok(sponsored);
      assert.deepEqual(banners, [], "the banner slot went unfilled instead");
    });

    it("prefers the higher-paying campaign", async () => {
      await campaign({ name: "Cheap", cpm: 50 });
      await campaign({ name: "Rich", cpm: 900 });

      const { sponsored } = await serve(await contact());

      assert.equal(sponsored.headline, "Rich headline");
    });
  });

  describe("tracking", () => {
    it("counts the impression at send, then confirms it on open", async () => {
      await campaign({ name: "Tracked" });

      const { sponsored } = await serve(await contact());

      const placementId = sponsored.pixelUrl.match(
        /\/a\/p\/([0-9a-f-]{36})\.gif$/
      )[1];

      let campaignRow = await pool.query("SELECT impressions FROM campaigns");
      assert.equal(Number(campaignRow.rows[0].impressions), 1, "counted at send");

      let placement = await pool.query("SELECT first_seen FROM ad_placements");
      assert.equal(placement.rows[0].first_seen, null, "not yet opened");

      const pixel = await fetch(`${base}/a/p/${placementId}.gif`);

      assert.equal(pixel.status, 200);
      assert.equal(pixel.headers.get("content-type"), "image/gif");
      assert.match(pixel.headers.get("cache-control"), /no-store/);

      placement = await pool.query("SELECT first_seen FROM ad_placements");
      assert.ok(placement.rows[0].first_seen, "open confirmed");

      /* Opening twice confirms once but records both events. */
      await fetch(`${base}/a/p/${placementId}.gif`);

      const events = await pool.query(
        "SELECT count(*)::int AS n FROM ad_events WHERE kind='impression'"
      );

      assert.equal(events.rows[0].n, 2);
    });

    it("redirects a click to the advertiser and counts it", async () => {
      await campaign({ name: "Clicky", clickUrl: "https://advertiser.example/x" });

      const { sponsored } = await serve(await contact());
      const placementId = sponsored.clickUrl.match(/\/a\/c\/([0-9a-f-]{36})$/)[1];

      const response = await fetch(`${base}/a/c/${placementId}`, {
        redirect: "manual"
      });

      assert.equal(response.status, 302);
      assert.equal(
        response.headers.get("location"),
        "https://advertiser.example/x"
      );

      const row = await pool.query(
        "SELECT clicks FROM campaigns"
      );

      assert.equal(Number(row.rows[0].clicks), 1);
    });

    it("refuses to redirect to a non-http destination", async () => {
      const id = await campaign({
        name: "Nasty",
        clickUrl: "javascript:alert(document.cookie)"
      });

      assert.ok(id);

      const { sponsored } = await serve(await contact());
      const placementId = sponsored.clickUrl.match(/\/a\/c\/([0-9a-f-]{36})$/)[1];

      const response = await fetch(`${base}/a/c/${placementId}`, {
        redirect: "manual"
      });

      assert.equal(response.status, 404);
      assert.equal(response.headers.get("location"), null);
    });

    it("still returns an image for an unknown or malformed token", async () => {
      /* A broken image in a customer's newsletter is worse than a lost row. */
      for (const token of [
        "550e8400-e29b-41d4-a716-446655440000",
        "not-a-uuid"
      ]) {
        const response = await fetch(`${base}/a/p/${token}.gif`);

        assert.equal(response.status, 200, token);
        assert.equal(response.headers.get("content-type"), "image/gif", token);
      }
    });

    it("404s a click on an unknown placement", async () => {
      const response = await fetch(
        `${base}/a/c/550e8400-e29b-41d4-a716-446655440000`,
        { redirect: "manual" }
      );

      assert.equal(response.status, 404);
    });
  });

  describe("reporting", () => {
    it("reports delivery and what it is worth", async () => {
      await campaign({ name: "Reported", cpm: 2000 });

      for (let n = 0; n < 3; n++) await serve(await contact());

      const [report] = await ads.campaignReport();

      assert.equal(report.name, "Reported");
      assert.equal(report.advertiser, "Reported Inc");
      assert.equal(Number(report.impressions), 3);
      /* 3 impressions at $20 CPM = 6 cents. */
      assert.equal(report.revenue_cents, 6);
    });
  });
});
