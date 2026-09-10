/*
 * Reports built for one reader: which sections are chosen from their job, and
 * what the page does with that. Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("reports for a reader", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const { buildCustomReport } = await import("../src/services/report.service.mjs");
  const { DEFAULT_SECTIONS, sectionsFor } = await import("../src/services/impact.service.mjs");

  const realFetch = globalThis.fetch;

  let server;
  let base;

  before(async () => {
    server = createApp().listen(0);
    await new Promise(resolve => server.once("listening", resolve));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    globalThis.fetch = realFetch;
    server?.close();
    await pool.end();
  });

  beforeEach(async () => {
    globalThis.fetch = realFetch;

    await pool.query(
      "TRUNCATE stories, briefs, contacts, tenants RESTART IDENTITY CASCADE"
    );

    /* Two stories in each of four sections, so per-section caps are visible. */
    for (const category of ["Compliance", "Technology", "Business", "Crypto"]) {
      for (let n = 0; n < 3; n++) {
        await pool.query(
          `INSERT INTO stories(
             language, slug, translation_key, category, headline, standfirst,
             body, published_at, issue_date, origin
           )
           VALUES('en',$1,$1,$2,$3,'A standfirst.','Body.',
                  now() - ($4 || ' hours')::interval, current_date, 'import')`,
          [`${category.toLowerCase()}-${n}`, category, `${category} story ${n}`, String(n)]
        );
      }
    }
  });

  /*
   * Answers as the model would, so the pipeline is real but deterministic.
   * Only OpenAI is intercepted — the test's own requests to the server under
   * test have to reach it, or the page assertions read the stub's reply.
   */
  function stubRanking(sections) {
    globalThis.fetch = async (url, init) => {
      if (!String(url).includes("openai.com")) return realFetch(url, init);

      return new Response(JSON.stringify({
        choices: [{ message: { content: JSON.stringify({ sections }) } }]
      }), { status: 200 });
    };
  }

  describe("choosing sections", () => {
    it("uses the reader's job, and keeps the reasoning", async () => {
      stubRanking([
        { name: "Compliance", why: "Reporting duties change with the rules." },
        { name: "Crypto", why: "Digital assets create new obligations." }
      ]);

      const result = await sectionsFor({
        title: "VP of Compliance",
        company: "Northgate Bank",
        limit: 2
      });

      assert.equal(result.personalised, true);
      assert.deepEqual(result.sections.map(s => s.name), ["Compliance", "Crypto"]);
      assert.match(result.sections[0].why, /Reporting duties/);
    });

    it("does not call the model when nothing is known about the reader", async () => {
      let calls = 0;

      globalThis.fetch = async (url, init) => {
        if (!String(url).includes("openai.com")) return realFetch(url, init);

        calls++;
        return new Response("{}", { status: 200 });
      };

      const result = await sectionsFor({});

      assert.equal(calls, 0, "nothing to reason from");
      assert.equal(result.personalised, false);
      assert.deepEqual(result.sections.map(s => s.name), DEFAULT_SECTIONS);
    });

    it("discards sections the archive does not publish", async () => {
      /* The model may only choose from the twelve that exist. */
      stubRanking([
        { name: "Gardening", why: "Invented." },
        { name: "Compliance", why: "Real." }
      ]);

      const result = await sectionsFor({ title: "Analyst", limit: 4 });

      assert.deepEqual(result.sections.map(s => s.name), ["Compliance"]);
    });

    it("does not let one section fill the report twice", async () => {
      stubRanking([
        { name: "Technology", why: "First." },
        { name: "Technology", why: "Again." },
        { name: "Business", why: "Third." }
      ]);

      const result = await sectionsFor({ title: "CTO", limit: 4 });

      assert.deepEqual(result.sections.map(s => s.name), ["Technology", "Business"]);
    });

    it("falls back to defaults when the model fails", async () => {
      globalThis.fetch = async (url, init) => String(url).includes("openai.com")
        ? new Response("{}", { status: 500 })
        : realFetch(url, init);

      const result = await sectionsFor({ title: "Analyst", limit: 3 });

      /* A report with ordinary sections beats no report. */
      assert.equal(result.personalised, false);
      assert.deepEqual(result.sections.map(s => s.name), DEFAULT_SECTIONS);
    });
  });

  describe("building the report", () => {
    it("draws stories from the chosen sections, capped per section", async () => {
      stubRanking([
        { name: "Compliance", why: "a" },
        { name: "Technology", why: "b" }
      ]);

      const report = await buildCustomReport({
        contact: { title: "VP Compliance", company: "Northgate Bank" },
        sectionCount: 2,
        perSection: 2
      });

      assert.equal(report.stories, 4, "two sections, two each");

      const rows = await pool.query(
        `SELECT s.category FROM briefs b
         JOIN stories s ON s.id = ANY(b.story_ids)
         WHERE b.id = $1`,
        [report.id]
      );

      const chosen = rows.rows.map(row => row.category).sort();

      assert.deepEqual(chosen, ["Compliance", "Compliance", "Technology", "Technology"]);
    });

    it("needs no tenant — a report can be built for anyone", async () => {
      stubRanking([{ name: "Business", why: "a" }]);

      const report = await buildCustomReport({
        contact: { title: "Founder", company: "Nobody Ltd" },
        sectionCount: 1
      });

      const { rows } = await pool.query(
        "SELECT tenant_id, meta FROM briefs WHERE id = $1",
        [report.id]
      );

      assert.equal(rows[0].tenant_id, null);
      assert.equal(rows[0].meta.reader.company, "Nobody Ltd");
    });
  });

  describe("the page", () => {
    it("names the reader and shows why each section was chosen", async () => {
      stubRanking([
        { name: "Compliance", why: "Reporting duties change with the rules." },
        { name: "Crypto", why: "Digital assets create new obligations." }
      ]);

      const report = await buildCustomReport({
        contact: {
          name: "Dana Reed",
          title: "VP of Compliance",
          company: "Northgate Bank"
        },
        sectionCount: 2
      });

      const html = await fetch(`${base}/brief/${report.id}`).then(r => r.text());

      assert.match(html, /Dana Reed, VP of Compliance, Northgate Bank/);
      assert.match(html, /Why these sections/);
      assert.match(html, /Reporting duties change with the rules\./);

      /* Headed by the reader's employer, not by a tenant. */
      assert.match(html, /<title>Daily Briefing — Northgate Bank<\/title>/);
    });

    it("leaves the reasoning block out of a company's daily brief", async () => {
      const tenant = await pool.query(
        `INSERT INTO tenants(owner_email, name, billing_status)
         VALUES('owner@acme.test','Acme Robotics','active') RETURNING id`
      );

      const story = await pool.query("SELECT id FROM stories LIMIT 1");

      const { transaction } = await import("../src/config/database.mjs");
      const briefs = await import("../src/models/brief.model.mjs");

      const id = await transaction(db => briefs.create(db, {
        tenantId: tenant.rows[0].id,
        html: "<p>emailed</p>",
        storyIds: [story.rows[0].id],
        issueDate: "2026-09-10"
      }));

      const html = await fetch(`${base}/brief/${id}`).then(r => r.text());

      assert.ok(!html.includes("Why these sections"), "no ranking to show");
      assert.match(html, /Acme Robotics/);
    });

    it("escapes reasoning that came back from the model", async () => {
      stubRanking([
        { name: "Business", why: '<script>alert(1)</script>' }
      ]);

      const report = await buildCustomReport({
        contact: { title: "Analyst", company: "X" },
        sectionCount: 1
      });

      const html = await fetch(`${base}/brief/${report.id}`).then(r => r.text());

      assert.ok(!html.includes("<script>alert(1)</script>"));
      assert.ok(html.includes("&lt;script&gt;"));
    });
  });
});
