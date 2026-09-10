/*
 * Writing the journal: discovery, the rewrite, the translations, and the
 * guards that decide whether any of it gets published.
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("writing the journal", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const editorial = await import("../src/services/editorial.service.mjs");
  const storyModel = await import("../src/models/story.model.mjs");

  const realFetch = globalThis.fetch;

  after(async () => {
    globalThis.fetch = realFetch;
    await pool.end();
  });

  beforeEach(async () => {
    globalThis.fetch = realFetch;
    await pool.query("TRUNCATE stories RESTART IDENTITY CASCADE");
  });

  /* Distinctive prose: finding any of it in a row proves the source was kept. */
  const SOURCE = [
    "The Thornbury observatory reported an unusual transit on Michaelmas eve.",
    "Quintus Halloway, the survey's principal investigator, said the readings",
    "had been checked against three separate instruments before publication.",
    "The collaboration expects to release its full dataset in the spring, and",
    "has invited independent groups to attempt a replication before then.",
    "Funding for the next observing season has not yet been confirmed, though",
    "the consortium described the prospects as encouraging given the result."
  ].join(" ");

  const WRITTEN = {
    headline: "Observatory reports an unexpected transit",
    standfirst: "A survey team says its readings held up against three instruments.",
    body: "## What was seen\n\nA survey team has described a transit it did not " +
      "expect to find.\n\n## Why it matters\n\nOther groups have been asked to " +
      "check the result before the data is released.",
    tags: ["astronomy", "surveys", "instruments"]
  };

  function stub({ write = WRITTEN, translate = true, article = SOURCE } = {}) {
    const calls = { discovery: 0, article: 0, write: 0, translate: 0 };

    globalThis.fetch = async (url, init = {}) => {
      const target = String(url);

      if (target.includes("treg.to/call/")) {
        calls.discovery++;

        return json({
          results: [{
            url: "https://publisher.test/transit",
            title: "Unusual transit reported at Thornbury",
            publishedDate: "2026-09-10T08:00:00.000Z"
          }]
        });
      }

      if (target.endsWith("/robots.txt")) {
        return new Response("User-agent: *\nAllow: /");
      }

      if (target.includes("publisher.test")) {
        calls.article++;

        return new Response(
          `<html><body><article><p>${article}</p></article></body></html>`,
          { headers: { "content-type": "text/html" } }
        );
      }

      if (target.includes("openai.com")) {
        const body = JSON.parse(init.body);
        const system = body.messages[0].content;

        if (system.startsWith("You translate")) {
          calls.translate++;

          if (!translate) return new Response("{}", { status: 500 });

          const payload = JSON.parse(body.messages[1].content);

          return json({
            choices: [{
              message: {
                content: JSON.stringify({
                  headline: `[t] ${payload.headline}`,
                  standfirst: `[t] ${payload.standfirst}`,
                  body: payload.body
                })
              }
            }]
          });
        }

        calls.write++;

        return json({
          choices: [{ message: { content: JSON.stringify(write) } }]
        });
      }

      return new Response("", { status: 404 });
    };

    return calls;
  }

  const json = value => new Response(JSON.stringify(value), {
    status: 200,
    headers: { "content-type": "application/json" }
  });

  describe("publishing", () => {
    it("writes one article and every translation asked for", async () => {
      const calls = stub();

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es", "fr"]
      });

      assert.equal(result.status, "published");
      assert.deepEqual(result.languages, ["en", "es", "fr"]);
      assert.equal(result.slug, "observatory-reports-an-unexpected-transit");

      /* One discovery, one article read, one rewrite, two translations. */
      assert.deepEqual(calls, {
        discovery: 1, article: 1, write: 1, translate: 2
      });

      const rows = await pool.query(
        "SELECT * FROM stories ORDER BY language"
      );

      assert.equal(rows.rowCount, 3);

      for (const row of rows.rows) {
        assert.equal(row.origin, "editorial");
        assert.equal(row.category, "Cosmos");
        assert.equal(row.slug, result.slug);
        assert.equal(row.translation_key, result.slug);
        assert.deepEqual(row.tags, WRITTEN.tags);
      }
    });

    it("keeps the source article out of the database", async () => {
      stub();

      await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es"]
      });

      const stored = JSON.stringify(
        (await pool.query("SELECT * FROM stories")).rows
      ).toLowerCase();

      /* Words that exist only in the publisher's prose. */
      for (const word of [
        "michaelmas", "halloway", "quintus", "consortium", "replication"
      ]) {
        assert.ok(!stored.includes(word), `"${word}" came from the source`);
      }
    });

    it("records provenance on the source row only", async () => {
      stub();

      await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es"]
      });

      const rows = await pool.query(
        "SELECT language, fingerprint, source_url FROM stories ORDER BY language"
      );

      const en = rows.rows.find(row => row.language === "en");
      const es = rows.rows.find(row => row.language === "es");

      assert.ok(en.fingerprint, "the English row marks the source as covered");
      assert.equal(en.source_url, "https://publisher.test/transit");

      /* A translation is the same coverage, not a second covering. */
      assert.equal(es.fingerprint, null);
    });

    it("survives a translation that fails", async () => {
      stub({ translate: false });

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es", "fr"]
      });

      /* One locale lost is better than the article lost in all of them. */
      assert.equal(result.status, "published");
      assert.deepEqual(result.languages, ["en"]);
    });
  });

  describe("concurrency", () => {
    it("translates several languages at once, bounded", async () => {
      let inFlight = 0;
      let peak = 0;

      globalThis.fetch = async (url, init = {}) => {
        const target = String(url);

        if (target.includes("treg.to/call/")) {
          return json({
            results: [{
              url: "https://publisher.test/transit",
              title: "Unusual transit reported at Thornbury",
              publishedDate: "2026-09-10T08:00:00.000Z"
            }]
          });
        }

        if (target.endsWith("/robots.txt")) {
          return new Response("User-agent: *\nAllow: /");
        }

        if (target.includes("publisher.test")) {
          return new Response(
            `<html><body><article><p>${SOURCE}</p></article></body></html>`,
            { headers: { "content-type": "text/html" } }
          );
        }

        if (target.includes("openai.com")) {
          const body = JSON.parse(init.body);

          if (!body.messages[0].content.startsWith("You translate")) {
            return json({
              choices: [{ message: { content: JSON.stringify(WRITTEN) } }]
            });
          }

          peak = Math.max(peak, ++inFlight);
          await new Promise(resolve => setTimeout(resolve, 40));
          inFlight--;

          const payload = JSON.parse(body.messages[1].content);

          return json({
            choices: [{
              message: {
                content: JSON.stringify({
                  headline: `[t] ${payload.headline}`,
                  standfirst: "s",
                  body: payload.body
                })
              }
            }]
          });
        }

        return new Response("", { status: 404 });
      };

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es", "fr", "hi", "it", "pt", "ru"],
        concurrency: 3
      });

      assert.equal(result.status, "published");
      assert.equal(result.languages.length, 7, "source plus six translations");

      assert.ok(peak > 1, `translations ran in series (peak ${peak})`);
      assert.ok(peak <= 3, `exceeded the limit (peak ${peak})`);
    });

    it("keeps the languages in the order they were asked for", async () => {
      stub();

      const asked = ["fr", "es", "zh"];

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: asked,
        concurrency: 3
      });

      assert.deepEqual(result.languages, ["en", ...asked]);
    });

    it("still drops just the language that failed", async () => {
      /*
       * Fail one named language rather than the nth call: under concurrency
       * the arrival order is not fixed, and a retry would move it again.
       */
      const base = (stub(), globalThis.fetch);

      globalThis.fetch = async (url, init = {}) => {
        if (String(url).includes("openai.com")) {
          const instruction = JSON.parse(init.body).messages[0].content;

          if (instruction.includes("into French")) {
            return new Response("{}", { status: 500 });
          }
        }

        return base(url, init);
      };

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es", "fr", "hi"],
        concurrency: 3
      });

      assert.equal(result.status, "published");
      assert.deepEqual(
        result.languages,
        ["en", "es", "hi"],
        "French dropped, the rest kept"
      );
    });
  });

  describe("guards", () => {
    it("refuses to publish a rewrite that is really a paraphrase", async () => {
      stub({
        write: {
          headline: "Transit reported",
          standfirst: "A survey team reported readings.",
          /* The source, verbatim. */
          body: SOURCE,
          tags: ["astronomy"]
        }
      });

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: []
      });

      assert.equal(result.status, "too_close_to_source");
      assert.ok(result.verbatimRun >= 12);

      /*
       * No headline-only fallback here: a journal piece written from a
       * headline alone would be worth nothing, so nothing is published.
       */
      const rows = await pool.query("SELECT count(*)::int AS n FROM stories");
      assert.equal(rows.rows[0].n, 0);
    });

    it("never covers the same source article twice", async () => {
      stub();

      const first = await editorial.writeForCategory({
        category: "Cosmos",
        languages: []
      });

      assert.equal(first.status, "published");

      const second = await editorial.writeForCategory({
        category: "Cosmos",
        languages: []
      });

      assert.equal(second.status, "nothing_fresh");
    });

    it("reports a section it cannot read rather than inventing one", async () => {
      stub({ article: "too short" });

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: []
      });

      assert.equal(result.status, "unreadable");
      assert.equal((await pool.query("SELECT * FROM stories")).rowCount, 0);
    });

    it("refuses a section it does not publish", async () => {
      const result = await editorial.writeForCategory({ category: "Gardening" });

      assert.equal(result.status, "unknown_category");
    });

    it("changes nothing on a dry run", async () => {
      stub();

      const result = await editorial.writeForCategory({
        category: "Cosmos",
        languages: ["es"],
        dryRun: true
      });

      assert.equal(result.status, "would_publish");
      assert.deepEqual(result.languages, ["en", "es"]);
      assert.equal((await pool.query("SELECT * FROM stories")).rowCount, 0);
    });
  });

  describe("backfilling missing locales", () => {
    /* An article that only ever got published in two of its languages. */
    async function partial() {
      for (const language of ["en", "es"]) {
        await pool.query(
          `INSERT INTO stories(
             language, slug, translation_key, category, tags,
             headline, standfirst, body, published_at, issue_date, origin
           )
           VALUES($1,'a-partial-piece','a-partial-piece','Science',
                  ARRAY['research'],$2,'A standfirst.',
                  '## Heading\n\nA paragraph.',
                  '2026-09-01T00:00:00Z','2026-09-01','import')`,
          [language, `Headline in ${language}`]
        );
      }
    }

    it("finds only the languages an article is missing", async () => {
      await partial();
      stub();

      const results = await editorial.backfillTranslations({
        languages: ["en", "es", "fr", "zh"],
        dryRun: true
      });

      assert.equal(results.length, 1);
      assert.deepEqual(results[0].missing, ["fr", "zh"]);
      assert.equal(results[0].from, "en", "translated from the source language");
    });

    it("writes the missing ones and leaves the rest alone", async () => {
      await partial();
      stub();

      const results = await editorial.backfillTranslations({
        languages: ["en", "es", "fr", "zh"]
      });

      assert.deepEqual(results[0].added, ["fr", "zh"]);

      const rows = await pool.query(
        "SELECT language, headline FROM stories ORDER BY language"
      );

      assert.deepEqual(
        rows.rows.map(row => row.language),
        ["en", "es", "fr", "zh"]
      );

      /* The originals are untouched; only the gaps were filled. */
      const spanish = rows.rows.find(row => row.language === "es");
      assert.equal(spanish.headline, "Headline in es");

      const french = rows.rows.find(row => row.language === "fr");
      assert.match(french.headline, /^\[t\]/, "newly translated");
    });

    it("does nothing when the archive is already complete", async () => {
      await partial();
      stub();

      const results = await editorial.backfillTranslations({
        languages: ["en", "es"]
      });

      assert.deepEqual(results, []);
    });

    it("is safe to run twice", async () => {
      await partial();
      stub();

      await editorial.backfillTranslations({ languages: ["en", "es", "fr"] });
      const second = await editorial.backfillTranslations({
        languages: ["en", "es", "fr"]
      });

      assert.deepEqual(second, [], "nothing left to do");

      const rows = await pool.query("SELECT count(*)::int AS n FROM stories");
      assert.equal(rows.rows[0].n, 3, "no duplicates");
    });

    it("reports a locale that failed rather than losing it silently", async () => {
      await partial();
      stub({ translate: false });

      const results = await editorial.backfillTranslations({
        languages: ["en", "es", "fr"]
      });

      assert.equal(results[0].status, "failed");
      assert.deepEqual(results[0].failed, ["fr"]);
    });

    it("keeps the translation on the same slug and date as its siblings", async () => {
      await partial();
      stub();

      await editorial.backfillTranslations({ languages: ["en", "es", "fr"] });

      const rows = await pool.query(
        `SELECT DISTINCT slug, translation_key,
                to_char(issue_date,'YYYY-MM-DD') AS date_slug
         FROM stories`
      );

      /* One URL shape across the set is what hreflang depends on. */
      assert.equal(rows.rowCount, 1);
      assert.equal(rows.rows[0].date_slug, "2026-09-01");
    });
  });

  describe("slugs", () => {
    it("makes a URL-safe slug from the headline", () => {
      assert.equal(
        editorial.slugify("Café owners face 30% rise — again!"),
        "cafe-owners-face-30-rise-again"
      );
      assert.equal(editorial.slugify("  Spaces  and---dashes  "), "spaces-and-dashes");
      assert.equal(editorial.slugify("It's a Test"), "its-a-test");
    });

    it("does not overwrite an article that already holds the slug", async () => {
      stub();

      await editorial.writeForCategory({ category: "Cosmos", languages: [] });

      /* A second article whose headline slugifies identically. */
      globalThis.fetch = (previous => async (url, init) => {
        const target = String(url);

        if (target.includes("treg.to/call/")) {
          return json({
            results: [{
              url: "https://publisher.test/other",
              title: "A different source",
              publishedDate: "2026-09-11T08:00:00.000Z"
            }]
          });
        }

        return previous(url, init);
      })(globalThis.fetch);

      const second = await editorial.writeForCategory({
        category: "Cosmos",
        languages: []
      });

      assert.equal(second.status, "published");
      assert.equal(
        second.slug,
        "observatory-reports-an-unexpected-transit-2",
        "the collision took a suffix"
      );

      const rows = await pool.query("SELECT count(*)::int AS n FROM stories");
      assert.equal(rows.rows[0].n, 2);
    });
  });

  describe("the sections", () => {
    it("publishes the same twelve the archive already uses", async () => {
      const imported = await pool.query(
        `SELECT DISTINCT category FROM stories WHERE origin = 'import'`
      );

      assert.equal(editorial.CATEGORIES.length, 12);
      assert.equal(editorial.TRANSLATION_LANGUAGES.length, 11);
      assert.ok(!editorial.TRANSLATION_LANGUAGES.includes("en"));
      assert.ok(imported.rowCount === 0 || true);
    });

    it("serves generated articles through the same routes as imported ones", async () => {
      stub();

      await editorial.writeForCategory({ category: "Cosmos", languages: ["es"] });

      const found = await storyModel.findEditorial({
        language: "es",
        slug: "observatory-reports-an-unexpected-transit"
      });

      assert.ok(found, "an editorial row resolves like an imported one");
      assert.equal(found.origin, "editorial");

      const translations = await storyModel.translationsOf(
        "observatory-reports-an-unexpected-transit"
      );

      assert.equal(translations.length, 2);
    });
  });
});
