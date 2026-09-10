/*
 * The publish gate over real HTTP against a real Postgres. Skipped unless
 * TEST_DATABASE_URL is set; see models.integration.test.mjs.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("publishing a feed", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const auth = await import("../src/models/auth.model.mjs");
  const companies = await import("../src/models/company.model.mjs");
  const subscribers = await import("../src/models/subscriber.model.mjs");
  const topics = await import("../src/models/topic.model.mjs");
  const { hash, token } = await import("../src/services/platform.service.mjs");
  const storyModel = await import("../src/models/story.model.mjs");

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
      `TRUNCATE tenants, topics, contacts, subscribers, outbox, briefs,
                mailgun_events, paypal_events, paypal_plans, stories,
                newsletter_picks, advertisers, campaigns, creatives,
                ad_placements, ad_events, login_tokens, sessions
       RESTART IDENTITY CASCADE`
    );
  });

  const topic = { key: hash("en:acme"), query: '"Robotics"' };

  async function paidTenant() {
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
    }, topic);

    await pool.query(
      "UPDATE tenants SET paypal_subscription_id='I-SUB1' WHERE id=$1",
      [tenantId]
    );

    await companies.syncSubscription({
      subscriptionId: "I-SUB1",
      status: "active"
    });

    await topics.claimStaleTopic();

    /*
     * The public surfaces read the stories table — the same rows the
     * newsletter is built from — so a story a reader saw in their inbox
     * resolves at its hosted URL.
     */
    const story = await storyModel.create({
      topicKey: topic.key,
      issueDate: "2026-09-10",
      sourceUrl: "https://example.com/story",
      sourceName: "The Example Times",
      sourceTitle: "Acme ships a robot",
      publishedAt: new Date("2026-09-10T08:00:00.000Z"),
      headline: "Acme ships a robot",
      standfirst: "What it means for operators.",
      body: "First paragraph.\n\nSecond paragraph.",
      fingerprint: storyModel.fingerprint("https://example.com/story")
    });

    const { rows } = await pool.query(
      "SELECT public_token FROM tenants WHERE id=$1",
      [tenantId]
    );

    return { tenantId, publicToken: rows[0].public_token, storyId: story.id };
  }

  async function addStakeholders(tenantId, n) {
    for (let i = 0; i < n; i++) {
      await subscribers.addRecipient({
        tenantId,
        email: `stakeholder${i}@acme.test`,
        authorisedBy: "owner@acme.test"
      });
    }
  }

  const paths = (publicToken, storyId) => [
    `/feed/${publicToken}.xml`,
    `/embed/${publicToken}`,
    `/news/${publicToken}/${storyId}`
  ];

  it("withholds every public surface until the roster is complete", async () => {
    const { tenantId, publicToken, storyId } = await paidTenant();

    await addStakeholders(tenantId, subscribers.REQUIRED_STAKEHOLDERS - 1);

    for (const path of paths(publicToken, storyId)) {
      const response = await fetch(base + path);
      const body = await response.text();

      assert.equal(response.status, 409, path);
      assert.ok(
        body.includes("not published yet"),
        `${path} should explain why: ${body.slice(0, 160)}`
      );
    }
  });

  it("publishes all of them once the tenth stakeholder is added", async () => {
    const { tenantId, publicToken, storyId } = await paidTenant();

    await addStakeholders(tenantId, subscribers.REQUIRED_STAKEHOLDERS);

    for (const path of paths(publicToken, storyId)) {
      const response = await fetch(base + path);

      assert.equal(response.status, 200, path);
      assert.ok((await response.text()).includes("Acme"), path);
    }
  });

  it("will not serve one tenant's story under another's token", async () => {
    const mine = await paidTenant();
    await addStakeholders(mine.tenantId, subscribers.REQUIRED_STAKEHOLDERS);

    /* A story that belongs to a different topic entirely. */
    await pool.query(
      "INSERT INTO topics(key, query, language) VALUES('other','q','en')"
    );

    const theirs = await storyModel.create({
      topicKey: "other",
      issueDate: "2026-09-10",
      sourceUrl: "https://example.com/private",
      sourceName: "Somewhere Else",
      sourceTitle: "Not for this tenant",
      publishedAt: new Date(),
      headline: "Not for this tenant",
      standfirst: "x",
      body: "x",
      fingerprint: storyModel.fingerprint("https://example.com/private")
    });

    const response = await fetch(
      `${base}/news/${mine.publicToken}/${theirs.id}`
    );

    assert.equal(response.status, 404, "a token exposes only its own stories");
  });

  it("takes the feed down again when billing lapses", async () => {
    const { tenantId, publicToken, storyId } = await paidTenant();

    await addStakeholders(tenantId, subscribers.REQUIRED_STAKEHOLDERS);

    await companies.syncSubscription({
      subscriptionId: "I-SUB1",
      status: "cancelled"
    });

    for (const path of paths(publicToken, storyId)) {
      /* 404, not 409: a lapsed tenant is not "nearly published". */
      assert.equal((await fetch(base + path)).status, 404, path);
    }
  });

  it("counts a stakeholder from the moment they are added", async () => {
    const { tenantId, publicToken } = await paidTenant();

    await addStakeholders(tenantId, subscribers.REQUIRED_STAKEHOLDERS);

    /* Added on the customer's attestation, so active with no waiting. */
    const states = await pool.query("SELECT DISTINCT state FROM subscribers");

    assert.deepEqual(states.rows, [{ state: "active" }]);
    assert.equal((await fetch(base + `/embed/${publicToken}`)).status, 200);
  });

  it("unpublishes when the roster drops below ten", async () => {
    const { tenantId, publicToken } = await paidTenant();

    await addStakeholders(tenantId, subscribers.REQUIRED_STAKEHOLDERS);
    await subscribers.remove(tenantId, "stakeholder0@acme.test");

    assert.equal((await fetch(base + `/embed/${publicToken}`)).status, 409);
  });
});
