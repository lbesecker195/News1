/*
 * A personalised issue, assembled the way delivery assembles it: the day's
 * stories, this reader's running order, and the advertising that pays for it.
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("personalised newsletter", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const worker = await import("../src/workers/main.mjs");
  const storyModel = await import("../src/models/story.model.mjs");

  const realFetch = globalThis.fetch;

  after(async () => {
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

    await pool.query(
      `INSERT INTO topics(key, query, language)
       VALUES('t1','"Robotics" OR "grippers"','en')`
    );
  });

  const DATE = "2026-09-10";

  const HEADLINES = [
    "Acme ships a warehouse robot",
    "Component prices ease across the supply chain",
    "Regulator opens consultation on autonomy"
  ];

  async function seedStories() {
    const written = [];

    for (const [n, headline] of HEADLINES.entries()) {
      written.push(await storyModel.create({
        topicKey: "t1",
        issueDate: DATE,
        sourceUrl: `https://example.com/s${n}`,
        sourceName: "The Example Times",
        sourceTitle: headline,
        publishedAt: new Date(`${DATE}T0${n}:00:00Z`),
        headline,
        standfirst: `Why ${headline.toLowerCase()} matters.`,
        body: "First paragraph.\n\nSecond paragraph.",
        fingerprint: storyModel.fingerprint(`https://example.com/s${n}`)
      }));
    }

    return written;
  }

  async function reader({ title = null, industry = null } = {}) {
    const { rows } = await pool.query(
      `INSERT INTO contacts(email, name, title, industry)
       VALUES($1,'Dana Reed',$2,$3) RETURNING id`,
      [`reader-${Math.random().toString(36).slice(2)}@x.test`, title, industry]
    );

    return rows[0].id;
  }

  const job = (contactId, extra = {}) => ({
    id: "00000000-0000-4000-8000-000000000001",
    kind: "digest",
    contact_id: contactId,
    tenant_id: null,
    payload: {
      company: "Acme Robotics",
      topicKey: "t1",
      topicQuery: '"Robotics" OR "grippers"',
      unsubscribeUrl: "https://rnews1.test/u/tok",
      date: DATE,
      ...extra
    }
  });

  /* Answers as the model would, so the pipeline is real but deterministic. */
  function stubModel(order) {
    globalThis.fetch = async () => new Response(JSON.stringify({
      choices: [{
        message: {
          content: JSON.stringify({
            order,
            reason: "matches your role"
          })
        }
      }]
    }), { status: 200 });
  }

  describe("assembly", () => {
    it("leads with the story the model chose for this reader", async () => {
      const stories = await seedStories();
      const contactId = await reader({ title: "VP Supply Chain" });

      /* The model puts the third story first for this reader. */
      stubModel([stories[2].id, stories[0].id, stories[1].id]);

      const message = await worker.buildMessage(job(contactId));

      const positions = HEADLINES.map(h => message.html.indexOf(h));

      assert.ok(positions.every(p => p > -1), "every story present");
      assert.ok(
        positions[2] < positions[0] && positions[0] < positions[1],
        "running order follows the model"
      );

      assert.equal(message.subject, HEADLINES[2], "subject is the lead");
      assert.match(message.html, /Picked for you · matches your role/);
      assert.match(message.html, /Also today/);
    });

    it("caches the choice so a retry costs nothing", async () => {
      const stories = await seedStories();
      const contactId = await reader({ title: "VP Supply Chain" });

      stubModel([stories[1].id, stories[0].id, stories[2].id]);
      await worker.buildMessage(job(contactId));

      let calls = 0;

      globalThis.fetch = async () => {
        calls++;
        return new Response("{}", { status: 500 });
      };

      const second = await worker.buildMessage(job(contactId));

      assert.equal(calls, 0, "the model was not asked again");
      assert.equal(second.subject, HEADLINES[1], "same lead as the first build");

      const picks = await pool.query("SELECT count(*)::int AS n FROM newsletter_picks");
      assert.equal(picks.rows[0].n, 1);
    });

    it("does not call the model for a reader it knows nothing about", async () => {
      await seedStories();
      const contactId = await reader();

      let calls = 0;

      globalThis.fetch = async () => {
        calls++;
        return new Response("{}", { status: 200 });
      };

      const message = await worker.buildMessage(job(contactId));

      assert.equal(calls, 0, "nothing to personalise on");
      assert.equal(message.subject, HEADLINES[0], "default order");

      const picks = await pool.query("SELECT personalised FROM newsletter_picks");
      assert.equal(picks.rows[0].personalised, false);
    });

    it("falls back to the default order when the model misbehaves", async () => {
      await seedStories();
      const contactId = await reader({ title: "VP Supply Chain" });

      /* An order naming stories that do not exist must not lose the issue. */
      stubModel(["not-a-story", "also-not-a-story"]);

      const message = await worker.buildMessage(job(contactId));

      assert.equal(message.subject, HEADLINES[0]);

      for (const headline of HEADLINES) {
        assert.ok(message.html.includes(headline), headline);
      }
    });

    it("carries the sender's postal address in both parts", async () => {
      await seedStories();
      const contactId = await reader({ title: "VP Supply Chain" });

      stubModel([]);

      const message = await worker.buildMessage(job(contactId));
      const address = process.env.BUSINESS_ADDRESS;

      /* Required by statute in every issue, however it was assembled. */
      assert.ok(message.html.includes(address), "html part");
      assert.ok(message.text.includes(address), "text part");
    });

    it("sends a real issue even with no stories written that day", async () => {
      const contactId = await reader({ title: "VP Supply Chain" });

      const message = await worker.buildMessage(job(contactId));

      assert.match(message.html, /No new coverage matched your topics today/);
      assert.match(message.text, /No new coverage/);
      assert.equal(message.subject, "Acme Robotics — 2026-09-10");
    });
  });

  describe("advertising", () => {
    async function campaign({ slot, name, targeting = {} }) {
      const advertiser = await pool.query(
        "INSERT INTO advertisers(name) VALUES($1) RETURNING id",
        [name]
      );

      const created = await pool.query(
        `INSERT INTO campaigns(
           advertiser_id, name, status, starts_on, ends_on, cpm_cents, targeting
         )
         VALUES($1,$2,'active','2026-01-01','2026-12-31',500,$3)
         RETURNING id`,
        [advertiser.rows[0].id, name, JSON.stringify(targeting)]
      );

      await pool.query(
        `INSERT INTO creatives(campaign_id, slot, headline, body, cta, click_url)
         VALUES($1,$2,$3,'Ad body copy.','See how','https://ad.example/x')`,
        [created.rows[0].id, slot, `${name} creative`]
      );

      return created.rows[0].id;
    }

    it("labels the sponsored story and tracks every placement", async () => {
      await seedStories();
      await campaign({ slot: "sponsored_story", name: "Sponsor" });
      await campaign({ slot: "banner", name: "Banner" });

      const contactId = await reader({ title: "VP Supply Chain" });
      stubModel([]);

      const message = await worker.buildMessage(job(contactId));

      /* The label sits above the headline, not in small print underneath. */
      const label = message.html.indexOf("Sponsored");
      const headline = message.html.indexOf("Sponsor creative");

      assert.ok(label > -1 && label < headline, "labelled before it is read");
      assert.match(message.html, /Banner creative/);

      /* Text-only readers are owed the disclosure too. */
      assert.match(message.text, /— SPONSORED —/);
      assert.match(message.text, /\[Ad\] Banner creative/);

      /* Clicks go through us, never straight to the advertiser. */
      assert.ok(!message.html.includes("https://ad.example/x"));
      assert.match(message.html, /\/a\/c\/[0-9a-f-]{36}/);
      assert.match(message.html, /\/a\/p\/[0-9a-f-]{36}\.gif/);

      const placements = await pool.query(
        "SELECT slot FROM ad_placements ORDER BY slot"
      );

      assert.deepEqual(
        placements.rows.map(row => row.slot),
        ["banner", "sponsored_story"]
      );
    });

    it("gives a reader only the advertising aimed at their role", async () => {
      await seedStories();

      await campaign({
        slot: "sponsored_story",
        name: "ForVPs",
        targeting: { titles: ["%vp%"] }
      });

      stubModel([]);

      const vp = await worker.buildMessage(job(await reader({ title: "VP Ops" })));
      assert.match(vp.html, /ForVPs creative/);

      const engineer = await worker.buildMessage(
        job(await reader({ title: "Software Engineer" }))
      );

      assert.ok(!engineer.html.includes("ForVPs creative"));
      /* And the issue still renders, just without a sponsor. */
      assert.match(engineer.html, /Acme ships a warehouse robot/);
    });

    it("counts one impression per issue built, not per story", async () => {
      await seedStories();
      await campaign({ slot: "sponsored_story", name: "Counted" });

      stubModel([]);
      await worker.buildMessage(job(await reader({ title: "VP Ops" })));
      await worker.buildMessage(job(await reader({ title: "VP Sales" })));

      const { rows } = await pool.query("SELECT impressions FROM campaigns");

      assert.equal(Number(rows[0].impressions), 2);
    });
  });

  describe("story de-duplication", () => {
    it("lets a second topic cover the same article, with its own rewrite", async () => {
      await seedStories();

      await pool.query(
        `INSERT INTO topics(key, query, language)
         VALUES('t2','"Warehousing"','en')`
      );

      /*
       * Two customers on the same beat are different audiences. The second
       * gets the story too, written up separately for them.
       */
      const second = await storyModel.create({
        topicKey: "t2",
        issueDate: DATE,
        sourceUrl: "https://example.com/s0",
        sourceName: "The Example Times",
        sourceTitle: HEADLINES[0],
        publishedAt: new Date(),
        headline: "A different angle on the same news",
        standfirst: "For a warehousing audience.",
        body: "Their own rewrite.",
        fingerprint: storyModel.fingerprint("https://example.com/s0")
      });

      assert.ok(second, "the second topic got its own copy");
      assert.notEqual(second.headline, HEADLINES[0]);

      const total = await pool.query("SELECT count(*)::int AS n FROM stories");
      assert.equal(total.rows[0].n, HEADLINES.length + 1);
    });

    it("will not cover the same article twice for one topic", async () => {
      await seedStories();

      /* Same topic, same article, arriving through a different feed link. */
      const duplicate = await storyModel.create({
        topicKey: "t1",
        issueDate: DATE,
        sourceUrl: "https://example.com/s0?utm_source=another-feed",
        sourceName: "The Example Times",
        sourceTitle: HEADLINES[0],
        publishedAt: new Date(),
        headline: "The same story, again",
        standfirst: "x",
        body: "x",
        fingerprint: storyModel.fingerprint("https://example.com/s0")
      });

      assert.equal(duplicate, null, "this topic already covered it");

      const total = await pool.query("SELECT count(*)::int AS n FROM stories");
      assert.equal(total.rows[0].n, HEADLINES.length);
    });

    it("only skips candidates this topic has already used", async () => {
      await seedStories();

      const marks = [
        storyModel.fingerprint("https://example.com/s0"),
        storyModel.fingerprint("https://example.com/brand-new")
      ];

      const takenHere = await storyModel.alreadyUsed("t1", marks);
      assert.deepEqual([...takenHere], [marks[0]]);

      /* A different topic has used none of them. */
      const takenThere = await storyModel.alreadyUsed("t2", marks);
      assert.deepEqual([...takenThere], []);
    });

    it("treats tracking parameters as noise, not identity", () => {
      const bare = storyModel.fingerprint("https://example.com/a/b");

      for (const variant of [
        "https://example.com/a/b?utm_source=news&utm_medium=rss",
        "https://example.com/a/b#section",
        "https://EXAMPLE.com/a/b/",
        "https://example.com/a/b?gclid=123"
      ]) {
        assert.equal(storyModel.fingerprint(variant), bare, variant);
      }

      assert.notEqual(storyModel.fingerprint("https://example.com/a/c"), bare);
    });
  });

  describe("never rewriting our own rewrites", () => {
    it("identifies our own stories by host, not by publisher name", async () => {
      const { isOurOwn } = await import("../src/services/story.service.mjs");

      /* APP_ORIGIN in the test environment is https://rnews1.test */
      assert.equal(isOurOwn("https://rnews1.test/news/tok/abc"), true);
      assert.equal(isOurOwn("https://www.rnews1.test/news/tok/abc"), true, "www");
      assert.equal(isOurOwn("https://news.rnews1.test/story"), true, "subdomain");
      assert.equal(isOurOwn("http://rnews1.test/x"), true, "either scheme");

      assert.equal(isOurOwn("https://theexampletimes.test/story"), false);

      /*
       * The publisher name is arbitrary text a feed can put anything in, so it
       * is not consulted. A real publisher calling itself Rnews1 is still a
       * real publisher, and a story of ours syndicated under someone else's
       * name is still caught, because the host is what decides.
       */
      assert.equal(isOurOwn("https://someone-else.test/rnews1/story"), false);
    });

    it("is not fooled by a lookalike domain", async () => {
      const { isOurOwn } = await import("../src/services/story.service.mjs");

      for (const url of [
        "https://rnews1.test.evil.example/story",
        "https://notrnews1.test/story",
        "https://rnews1.testing/story"
      ]) {
        assert.equal(isOurOwn(url), false, url);
      }
    });

    it("refuses nonsense without throwing", async () => {
      const { isOurOwn } = await import("../src/services/story.service.mjs");

      for (const url of ["not a url", "", null, undefined, "javascript:x"]) {
        assert.equal(isOurOwn(url), false, String(url));
      }
    });
  });
});
