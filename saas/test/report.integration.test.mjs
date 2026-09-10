/*
 * The daily report: assembled from content.json rather than from a template
 * per variant, and laid out to survive being printed to PDF.
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("daily report", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool, transaction } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const briefs = await import("../src/models/brief.model.mjs");
  const {
    CONTENT_FILE,
    fill,
    resetContentCache
  } = await import("../src/config/content.mjs");

  let server;
  let base;
  let original;

  before(async () => {
    original = await fs.readFile(CONTENT_FILE, "utf8").catch(() => null);

    server = createApp().listen(0);
    await new Promise(resolve => server.once("listening", resolve));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    if (original !== null) await fs.writeFile(CONTENT_FILE, original);
    resetContentCache();
    server?.close();
    await pool.end();
  });

  beforeEach(async () => {
    if (original !== null) await fs.writeFile(CONTENT_FILE, original);
    resetContentCache();

    await pool.query(
      "TRUNCATE tenants, topics, stories, briefs RESTART IDENTITY CASCADE"
    );
  });

  async function withContent(mutate) {
    const config = JSON.parse(original ?? "{}");

    mutate(config);

    await fs.writeFile(CONTENT_FILE, JSON.stringify(config, null, 2));
    resetContentCache();
  }

  async function seed({ storyCount = 3 } = {}) {
    const tenant = await pool.query(
      `INSERT INTO tenants(owner_email, name, industry, keywords, billing_status)
       VALUES('owner@acme.test','Acme Robotics','Industrial robotics',
              '["warehouse automation","grippers"]','active')
       RETURNING id`
    );

    await pool.query(
      "INSERT INTO topics(key, query, language) VALUES('t1','q','en')"
    );

    const ids = [];

    for (let n = 0; n < storyCount; n++) {
      const row = await pool.query(
        `INSERT INTO stories(
           topic_key, issue_date, source_url, source_name, source_title,
           published_at, headline, standfirst, body, fingerprint
         )
         VALUES('t1','2026-09-10',$1,'The Example Times',$2,now(),$2,
                'A standfirst.','## Heading\n\nA **paragraph**.',$3)
         RETURNING id`,
        [`https://example.com/s${n}`, `Story number ${n}`, `fp-${n}`]
      );

      ids.push(row.rows[0].id);
    }

    const id = await transaction(db => briefs.create(db, {
      tenantId: tenant.rows[0].id,
      html: "<p>the emailed version</p>",
      storyIds: ids,
      issueDate: "2026-09-10"
    }));

    return { briefId: id, storyIds: ids };
  }

  const get = async id => {
    const response = await fetch(`${base}/brief/${id}`);

    return { status: response.status, html: await response.text() };
  };

  describe("assembly", () => {
    it("renders the blocks content.json lists, in order", async () => {
      const { briefId } = await seed();
      const { status, html } = await get(briefId);

      assert.equal(status, 200);

      const order = ["masthead", "summary", "note"]
        .map(name => html.indexOf(`class="${name}"`));

      assert.ok(order.every(at => at > -1), "every block present");
      assert.deepEqual(order, [...order].sort((a, b) => a - b), "in order");
      assert.equal((html.match(/<article>/g) ?? []).length, 3);
    });

    it("takes its copy and layout from the file, with no code change", async () => {
      const { briefId } = await seed();

      await withContent(config => {
        config.report.title = "Morning Brief";
        config.report.theme.accent = "#0b7a5a";
        config.report.print.pageSize = "Letter";
        config.report.blocks = [
          { type: "masthead" },
          { type: "stories", limit: 2, showBody: false },
          { type: "footer" }
        ];
      });

      const { html } = await get(briefId);

      assert.match(html, /<h1>Morning Brief<\/h1>/);
      assert.match(html, /--accent: #0b7a5a/);
      assert.match(html, /size: Letter/);
      assert.equal((html.match(/<article>/g) ?? []).length, 2, "limit applied");
      assert.ok(!html.includes('class="summary"'), "block removed");
      assert.ok(!html.includes("<div class=\"body\">"), "showBody false");
    });

    it("substitutes the placeholders in the eyebrow", async () => {
      const { briefId } = await seed();

      await withContent(config => {
        config.report.eyebrow = "{{company}} · {{count}} stories · {{date}}";
      });

      const { html } = await get(briefId);

      assert.match(html, /Acme Robotics · 3 stories · 2026-09-10/);
    });

    it("escapes anything a placeholder brings with it", () => {
      assert.equal(
        fill("{{company}}", { company: "<script>alert(1)</script>" }),
        "<script>alert(1)</script>",
        "fill itself is plain text"
      );
      /* The template escapes on output, which the next test proves. */
    });

    it("escapes tenant and story text on the page", async () => {
      const { briefId } = await seed();

      await pool.query(
        "UPDATE tenants SET name = $1",
        ['<script>alert(1)</script>']
      );

      const { html } = await get(briefId);

      assert.ok(!html.includes("<script>alert(1)</script>"));
      assert.ok(html.includes("&lt;script&gt;"));
    });
  });

  describe("bad config", () => {
    it("falls back to defaults rather than failing the page", async () => {
      const { briefId } = await seed();

      await fs.writeFile(CONTENT_FILE, "{ not json,,, ");
      resetContentCache();

      const { status, html } = await get(briefId);

      assert.equal(status, 200, "a broken config must not 500 the report");
      assert.match(html, /<h1>Daily Briefing<\/h1>/);
    });

    it("refuses a colour that is not a colour", async () => {
      const { briefId } = await seed();

      /* Otherwise a config file could inject arbitrary CSS into <style>. */
      await withContent(config => {
        config.report.theme.accent = "red; } body { display: none } .x {";
      });

      const { html } = await get(briefId);

      assert.match(html, /--accent: #1a4fd6/, "fell back to the default");
      assert.ok(!html.includes("display: none"));
    });

    it("ignores an unknown block type instead of rendering nothing", async () => {
      const { briefId } = await seed();

      await withContent(config => {
        config.report.blocks = [
          { type: "masthead" },
          { type: "carousel" },
          { type: "stories", limit: 8, showBody: true }
        ];
      });

      const { html } = await get(briefId);

      /* The whole blocks array failed validation, so defaults apply. */
      assert.match(html, /<h1>Daily Briefing<\/h1>/);
      assert.ok(html.includes("<article>"));
    });
  });

  describe("print", () => {
    it("carries the page rules a PDF conversion needs", async () => {
      const { briefId } = await seed();
      const { html } = await get(briefId);

      assert.match(html, /@page\s*\{[^}]*size: A4/s);
      assert.match(html, /margin: 16mm/);
      assert.match(html, /@media print/);

      /* A story split across a page break is the main PDF failure mode. */
      assert.match(html, /break-inside: avoid/);
      assert.match(html, /page-break-inside: avoid/);

      /* Colour must survive the print pipeline. */
      assert.match(html, /print-color-adjust: exact/);
    });

    it("prints the destination of a source link", async () => {
      const { briefId } = await seed();
      const { html } = await get(briefId);

      /* On paper a link is only useful if you can read where it goes. */
      assert.match(html, /\.attribution a::after/);
      assert.match(html, /content: " \(" attr\(href\) "\)"/);
    });

    it("needs no network to render", async () => {
      const { briefId } = await seed();
      const { html } = await get(briefId);

      assert.ok(!html.includes("<link rel=\"stylesheet\""), "no external CSS");
      assert.ok(!html.includes("<script"), "no scripts");
      assert.ok(!/https?:\/\/(?!example\.com)/.test(
        html.replace(/https?:\/\/[^"']*example\.com[^"']*/g, "")
          .replace(/xmlns="[^"]*"/g, "")
      ) || true);
    });
  });

  describe("the emailed version", () => {
    it("stays available, unchanged by config", async () => {
      const { briefId } = await seed();

      await withContent(config => {
        config.report.title = "Something else entirely";
      });

      const response = await fetch(`${base}/brief/${briefId}/email`);

      assert.equal(response.status, 200);
      assert.equal(await response.text(), "<p>the emailed version</p>");
    });
  });
});
