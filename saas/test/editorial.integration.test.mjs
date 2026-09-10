/*
 * The imported archive: its URLs, its locales, and the redirects that keep
 * every link the Hugo site published working after the move.
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("editorial archive", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { createApp } = await import("../src/app.mjs");
  const stories = await import("../src/models/story.model.mjs");

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

  const LANGUAGES = ["en", "es", "ar", "zh"];
  const SLUG = "a-thing-that-happened";

  /*
   * The authored date is 18:11 at UTC-7, which is the following day in UTC.
   * If anything derives the URL date from a JS Date this fixture catches it.
   */
  const AUTHORED = "2026-08-29T18:11:00-07:00";
  const DATE = "2026-08-29";

  beforeEach(async () => {
    await pool.query("TRUNCATE stories RESTART IDENTITY CASCADE");

    for (const language of LANGUAGES) {
      await pool.query(
        `INSERT INTO stories(
           language, slug, translation_key, category, tags,
           headline, standfirst, body, published_at, issue_date, origin
         )
         VALUES($1,$2,'group-1','USA',ARRAY['immigration'],
                $3,'A standfirst.',
                '## A heading\n\nA **bold** paragraph with [a link](https://example.com/x).',
                $4::timestamptz, $4::timestamptz::date, 'import')`,
        [language, SLUG, `Headline in ${language}`, AUTHORED]
      );
    }
  });

  const url = (language, topic = "usa", slug = SLUG, date = DATE) =>
    `${base}/${language}/${topic}/${slug}/${date}`;

  describe("urls", () => {
    it("serves the canonical /{lang}/{topic}/{slug}/{date}", async () => {
      const response = await fetch(url("en"));

      assert.equal(response.status, 200);

      const html = await response.text();

      assert.ok(html.includes("Headline in en"));
      assert.match(html, /<html lang="en" dir="ltr">/);
    });

    it("puts the authored date in the URL, not the UTC one", async () => {
      /*
       * 2026-08-29 18:11 -07:00 is 2026-08-30 in UTC. The URL must say the
       * 29th, which is the day it was published.
       */
      assert.equal((await fetch(url("en", "usa", SLUG, "2026-08-29"))).status, 200);

      const utcDay = await fetch(url("en", "usa", SLUG, "2026-08-30"), {
        redirect: "manual"
      });

      assert.equal(utcDay.status, 301, "the UTC day is not canonical");
      assert.match(utcDay.headers.get("location"), /2026-08-29$/);
    });

    it("301s every undated link the Hugo site published", async () => {
      const response = await fetch(`${base}/en/usa/${SLUG}`, {
        redirect: "manual"
      });

      assert.equal(response.status, 301);
      assert.match(
        response.headers.get("location"),
        new RegExp(`/en/usa/${SLUG}/${DATE}$`)
      );
    });

    it("301s a stale topic rather than losing the page", async () => {
      const response = await fetch(url("en", "world"), { redirect: "manual" });

      assert.equal(response.status, 301);
      assert.match(response.headers.get("location"), /\/en\/usa\//);
    });

    it("404s an unknown language, so it cannot shadow other routes", async () => {
      for (const path of ["/xx", "/xx/usa", `/xx/usa/${SLUG}/${DATE}`]) {
        assert.equal((await fetch(base + path)).status, 404, path);
      }
    });

    it("leaves the rest of the site alone", async () => {
      /* These are all one or two segments, like a language path. */
      for (const [path, status] of [
        ["/", 200],
        ["/privacy", 200],
        ["/terms", 200],
        ["/login", 200],
        ["/robots.txt", 200]
      ]) {
        assert.equal((await fetch(base + path)).status, status, path);
      }
    });
  });

  describe("locales", () => {
    it("keeps every language a separate page", async () => {
      for (const language of LANGUAGES) {
        const response = await fetch(url(language));

        assert.equal(response.status, 200, language);

        const html = await response.text();

        assert.ok(html.includes(`Headline in ${language}`), language);
        assert.match(
          html,
          new RegExp(`<html lang="${language}" dir="(ltr|rtl)">`),
          language
        );
      }
    });

    it("declares every sibling with hreflang, and an x-default", async () => {
      const html = await fetch(url("es")).then(r => r.text());

      for (const language of LANGUAGES) {
        assert.match(
          html,
          new RegExp(
            `<link rel="alternate" hreflang="${language}" href="[^"]*/${language}/usa/${SLUG}/${DATE}">`
          ),
          language
        );
      }

      /* English is the default when no language matches the reader. */
      assert.match(html, /hreflang="x-default"[^>]*\/en\/usa\//);
    });

    it("points canonical at itself, not at English", async () => {
      const html = await fetch(url("ar")).then(r => r.text());

      assert.match(
        html,
        new RegExp(`<link rel="canonical" href="[^"]*/ar/usa/${SLUG}/${DATE}">`)
      );
    });

    it("is indexable — this is the topical-authority surface", async () => {
      const html = await fetch(url("en")).then(r => r.text());

      assert.ok(!html.includes("noindex"));
    });
  });

  describe("listings", () => {
    it("indexes a language and its sections", async () => {
      const index = await fetch(`${base}/en`);

      assert.equal(index.status, 200);
      assert.ok((await index.text()).includes("Headline in en"));

      const section = await fetch(`${base}/en/usa`);

      assert.equal(section.status, 200);
      assert.ok((await section.text()).includes("Headline in en"));
    });

    it("404s a section with nothing in it", async () => {
      assert.equal((await fetch(`${base}/en/nothing-here`)).status, 404);
    });
  });

  describe("dwell", () => {
    it("tells the reader how long the article is", async () => {
      const html = await fetch(url("en")).then(r => r.text());

      assert.match(html, /\d+ min read/);
    });

    it("ends with somewhere to go next", async () => {
      /*
       * The foot of an article is where a reader either continues or leaves.
       * An article that ends in nothing ends the session.
       */
      await pool.query(
        `INSERT INTO stories(
           language, slug, translation_key, category, headline, standfirst,
           body, published_at, issue_date, origin
         )
         VALUES('en','another-piece','group-2','USA','A second story',
                'Also worth reading.','Body.',now(),current_date,'import')`
      );

      const html = await fetch(url("en")).then(r => r.text());

      assert.match(html, /Continue reading/);
      assert.ok(html.includes("A second story"), "a real next article");
      assert.match(html, /\/en\/usa\/another-piece\//, "linked, with a date");
    });

    it("offers other languages by name, not by code", async () => {
      const html = await fetch(url("en")).then(r => r.text());

      /* "Español" is recognisable to its reader; "ES" is not. */
      assert.ok(html.includes("Español"), "endonym");
      assert.ok(html.includes("العربية"), "endonym");
    });

    it("sets text direction per locale", async () => {
      const rtl = await fetch(url("ar")).then(r => r.text());
      const ltr = await fetch(url("en")).then(r => r.text());

      assert.match(rtl, /<html lang="ar" dir="rtl">/);
      assert.match(ltr, /<html lang="en" dir="ltr">/);
    });
  });

  describe("markdown", () => {
    it("renders the body and escapes anything that looks like markup", async () => {
      await pool.query(
        "UPDATE stories SET body = $1 WHERE language = 'en'",
        ['A <script>alert(1)</script> line with **bold**.']
      );

      const html = await fetch(url("en")).then(r => r.text());

      assert.ok(!html.includes("<script>alert(1)</script>"), "escaped");
      assert.ok(html.includes("&lt;script&gt;"));
      assert.ok(html.includes("<strong>bold</strong>"), "still renders markdown");
    });
  });

  describe("sitemap", () => {
    it("lists every locale at its canonical dated URL", async () => {
      const xml = await fetch(`${base}/sitemap.xml`).then(r => r.text());

      for (const language of LANGUAGES) {
        assert.ok(
          xml.includes(`/${language}/usa/${SLUG}/${DATE}</loc>`),
          language
        );
      }
    });
  });

  describe("the model", () => {
    it("only treats the twelve published languages as languages", () => {
      assert.equal(stories.isLanguage("en"), true);
      assert.equal(stories.isLanguage("zh"), true);
      assert.equal(stories.isLanguage("privacy"), false);
      assert.equal(stories.isLanguage("app"), false);
      assert.equal(stories.isLanguage(""), false);
      assert.equal(stories.LANGUAGES.length, 12);
    });
  });
});
