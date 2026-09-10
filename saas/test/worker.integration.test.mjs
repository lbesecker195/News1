/*
 * End-to-end worker paths against a real Postgres. Skipped unless
 * TEST_DATABASE_URL is set; see models.integration.test.mjs.
 *
 * Mailgun is stubbed at the global fetch boundary, so the code under test is
 * the real delivery loop, not a re-implementation of it.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("worker end to end", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const worker = await import("../src/workers/main.mjs");
  const auth = await import("../src/models/auth.model.mjs");
  const companies = await import("../src/models/company.model.mjs");
  const subscribers = await import("../src/models/subscriber.model.mjs");
  const topics = await import("../src/models/topic.model.mjs");
  const { hash, token, briefPdfPath, closeBrowser } = await import(
    "../src/services/platform.service.mjs"
  );
  const storyModel = await import("../src/models/story.model.mjs");

  const ISSUE_DATE = "2026-09-09";

  /*
   * Seeds the day's stories directly. buildIssue() returns early when the
   * issue is already written, which keeps these tests off the network and off
   * the OpenAI bill.
   */
  async function seedStories(topicKey, issueDate = ISSUE_DATE) {
    const written = [];

    for (const [n, headline] of [
      "Acme ships a robot",
      "Rivals answer with their own line",
      "Component prices ease"
    ].entries()) {
      written.push(await storyModel.create({
        topicKey,
        issueDate,
        sourceUrl: `https://example.com/story-${n}`,
        sourceName: "The Example Times",
        sourceTitle: headline,
        publishedAt: new Date(`${issueDate}T08:0${n}:00Z`),
        headline,
        standfirst: `What ${headline.toLowerCase()} means for the market.`,
        body: "First paragraph of context.\n\nSecond paragraph of context.",
        fingerprint: storyModel.fingerprint(`https://example.com/story-${n}`)
      }));
    }

    return written;
  }

  const realFetch = globalThis.fetch;

  after(async () => {
    await closeBrowser();
    globalThis.fetch = realFetch;
    await pool.end();
  });

  beforeEach(async () => {
    globalThis.fetch = realFetch;

    await pool.query(
      `TRUNCATE tenants, topics, contacts, subscribers, outbox, briefs,
                mailgun_events, paypal_events, paypal_plans, stories,
                newsletter_picks, advertisers, campaigns, creatives,
                ad_placements, ad_events, login_tokens, sessions
       RESTART IDENTITY CASCADE`
    );
  });

  /* Records what would have been sent, and answers as Mailgun does. */
  function stubMailgun({ status = 200, body = '{"id":"<msg@mg>"}' } = {}) {
    const sent = [];

    globalThis.fetch = async (url, init) => {
      sent.push({ url: String(url), form: init.body });
      return new Response(body, { status });
    };

    return sent;
  }

  const topic = { key: hash("en:acme"), query: '"Robotics"' };

  async function readyTenant() {
    const tenantId = await auth.createLogin({
      email: "owner@acme.test",
      tokenHash: hash(token()),
      url: "https://rnews1.test/login/x"
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
    await topics.saveItems(topic.key, [{
      id: "a1",
      title: "Acme ships a robot",
      summary: "Acme announced a new robot.",
      source: "The Example Times",
      url: "https://example.com/story",
      published: "2026-09-09T08:00:00.000Z"
    }]);

    await subscribers.addRecipient({
      tenantId,
      email: "reader@acme.test",
      authorisedBy: "owner@acme.test"
    });

    const { rows } = await pool.query("SELECT confirm_token FROM subscribers");
    await subscribers.confirm(rows[0].confirm_token);

    await seedStories(topic.key);
    await pool.query("DELETE FROM outbox");

    return tenantId;
  }

  describe("scheduleDigests", () => {
    it("does nothing before the configured hour", async () => {
      await readyTenant();

      const tooEarly = new Date("2026-09-09T00:00:00Z");

      assert.equal(await worker.scheduleDigests(tooEarly), null);
    });

    it("writes a brief, its PDF, and one queued email per recipient", async () => {
      await readyTenant();

      const result = await worker.scheduleDigests(
        new Date("2026-09-09T14:00:00Z")
      );

      assert.equal(result.recipients, 1);

      const brief = await pool.query(
        "SELECT id, html, has_pdf FROM briefs"
      );

      assert.equal(brief.rowCount, 1);
      assert.equal(brief.rows[0].has_pdf, true);
      assert.match(brief.rows[0].html, /Acme ships a robot/);
      assert.equal(result.stories, 3);

      const pdf = await fs.stat(briefPdfPath(brief.rows[0].id));
      assert.ok(pdf.size > 0, "PDF was written");
      await fs.unlink(briefPdfPath(brief.rows[0].id));

      const queued = await pool.query(
        "SELECT to_email, kind, payload, dedupe_key FROM outbox"
      );

      assert.equal(queued.rowCount, 1);
      assert.equal(queued.rows[0].to_email, "reader@acme.test");
      assert.equal(queued.rows[0].kind, "digest");
      assert.match(
        queued.rows[0].payload.unsubscribeUrl,
        /^https:\/\/rnews1\.test\/u\/[0-9a-f-]{36}$/
      );
      assert.equal(queued.rows[0].payload.topicKey, topic.key);

      /* Running again the same day must not queue a second copy. */
      assert.equal(
        await worker.scheduleDigests(new Date("2026-09-09T15:00:00Z")),
        null
      );

      const again = await pool.query("SELECT count(*)::int AS n FROM outbox");
      assert.equal(again.rows[0].n, 1);
    });
  });

  describe("deliverOne", () => {
    it("sends a queued message and records the provider id", async () => {
      await readyTenant();
      await worker.scheduleDigests(new Date("2026-09-09T14:00:00Z"));

      const sent = stubMailgun();
      const result = await worker.deliverOne();

      assert.deepEqual(result, {
        id: result.id,
        accepted: true
      });

      assert.equal(sent.length, 1);
      assert.match(sent[0].url, /\/v3\/mg\.rnews1\.test\/messages$/);
      assert.equal(sent[0].form.get("to"), "reader@acme.test");
      /* The subject is the lead story's headline, not a generic label. */
      assert.ok(sent[0].form.get("subject").length > 0);
      assert.equal(sent[0].form.get("v:job_id"), result.id);
      assert.match(
        sent[0].form.get("h:List-Unsubscribe"),
        /^<https:\/\/rnews1\.test\/u\//
      );

      const job = await pool.query("SELECT status, provider_message_id FROM outbox");

      assert.equal(job.rows[0].status, "accepted");
      assert.equal(job.rows[0].provider_message_id, "<msg@mg>");

      assert.equal(await worker.deliverOne(), null, "queue is drained");

      const brief = await pool.query("SELECT id FROM briefs");
      await fs.unlink(briefPdfPath(brief.rows[0].id)).catch(() => {});
    });

    it("never sends to an address suppressed after the job was queued", async () => {
      await readyTenant();
      await worker.scheduleDigests(new Date("2026-09-09T14:00:00Z"));
      await pool.query("UPDATE contacts SET opted_out_at=now()");

      const sent = stubMailgun();
      const result = await worker.deliverOne();

      assert.equal(result.suppressed, true);
      assert.equal(sent.length, 0, "nothing left the process");

      const job = await pool.query("SELECT status FROM outbox");
      assert.equal(job.rows[0].status, "suppressed");

      const brief = await pool.query("SELECT id FROM briefs");
      await fs.unlink(briefPdfPath(brief.rows[0].id)).catch(() => {});
    });

    it("retries a 5xx but gives up on a 4xx", async () => {
      const tenantId = await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(token()),
        url: "https://rnews1.test/login/x"
      });

      assert.ok(tenantId);

      stubMailgun({ status: 503, body: "upstream busy" });
      assert.deepEqual(await worker.deliverOne(), {
        id: (await pool.query("SELECT id FROM outbox")).rows[0].id,
        retrying: true
      });

      let job = await pool.query(
        "SELECT status, attempts, run_after > now() AS later FROM outbox"
      );
      assert.deepEqual(job.rows[0], { status: "pending", attempts: 1, later: true });

      await pool.query("UPDATE outbox SET run_after=now()");
      stubMailgun({ status: 400, body: "bad request" });

      assert.equal((await worker.deliverOne()).failed, true);

      job = await pool.query("SELECT status, last_error FROM outbox");
      assert.equal(job.rows[0].status, "failed");
      assert.match(job.rows[0].last_error, /Mailgun 400/);
    });

    it("parks a send whose outcome is unknown instead of risking a duplicate", async () => {
      await auth.createLogin({
        email: "owner@acme.test",
        tokenHash: hash(token()),
        url: "https://rnews1.test/login/x"
      });

      globalThis.fetch = async () => {
        throw new Error("socket hang up");
      };

      assert.equal((await worker.deliverOne()).unknown, true);

      const job = await pool.query("SELECT status FROM outbox");
      assert.equal(job.rows[0].status, "unknown");

      /* Must not be picked up again: the message may already have gone out. */
      assert.equal(await worker.deliverOne(), null);
    });
  });

  describe("planCampaign", () => {
    it("queues one message per eligible contact and never twice", async () => {
      await pool.query(
        `INSERT INTO contacts(email,name) VALUES
           ('a@x.test','Ada'),
           ('b@x.test','Grace')`
      );

      await pool.query(
        "INSERT INTO contacts(email,opted_out_at) VALUES('c@x.test',now())"
      );

      const first = await worker.planCampaign("2026-10-01");

      assert.deepEqual(first, { date: "2026-10-01", eligible: 2, queued: 2 });

      const second = await worker.planCampaign("2026-10-01");
      assert.equal(second.queued, 0, "dedupe key held");

      const queued = await pool.query(
        "SELECT to_email, run_after FROM outbox WHERE kind='campaign' ORDER BY to_email"
      );

      assert.deepEqual(
        queued.rows.map(row => row.to_email),
        ["a@x.test", "b@x.test"]
      );

      assert.equal(
        queued.rows[0].run_after.toISOString(),
        "2026-10-01T14:00:00.000Z"
      );
    });

    it("rejects a date it cannot parse", async () => {
      await assert.rejects(() => worker.planCampaign("tomorrow"), /YYYY-MM-DD/);
      await assert.rejects(() => worker.planCampaign(undefined), /YYYY-MM-DD/);
    });
  });

  describe("maintenance", () => {
    it("runs every sweep without error and reports what it did", async () => {
      const result = await worker.maintenance();

      assert.deepEqual(Object.keys(result).sort(), [
        "briefs", "campaigns", "exhausted", "expired", "requeued"
      ]);
    });
  });
});
