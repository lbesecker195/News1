/*
 * The invariant: no publisher's article text ever reaches the database.
 *
 * It is worth an end-to-end test rather than a unit one, because the risk is
 * not that dropSource() stops working — it is that some future edit adds a
 * path around it. This runs the real pipeline with every network boundary
 * stubbed, then searches the saved row for words that only existed in the
 * source.
 *
 * Skipped unless TEST_DATABASE_URL is set.
 */
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL || "";

import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { after, beforeEach, describe, it } from "node:test";

const ENABLED = Boolean(process.env.TEST_DATABASE_URL);

describe("the corpus is never stored", { skip: ENABLED ? false : "TEST_DATABASE_URL not set" }, async () => {
  const { pool } = await import("../src/config/database.mjs");
  const { buildIssue } = await import("../src/services/story.service.mjs");

  const realFetch = globalThis.fetch;

  after(async () => {
    globalThis.fetch = realFetch;
    await pool.end();
  });

  beforeEach(async () => {
    globalThis.fetch = realFetch;

    await pool.query(
      "TRUNCATE topics, stories RESTART IDENTITY CASCADE"
    );

    await pool.query(
      `INSERT INTO topics(key, query, language)
       VALUES('t1','"Robotics" OR "grippers"','en')`
    );
  });

  /*
   * Distinctive enough that finding any of it in a database row proves it came
   * from the source and nowhere else.
   */
  const SENTINEL = [
    "The kestrel-shaped manipulator was demonstrated at Thornbury on Michaelmas.",
    "Quintus Halloway, the firm's chief metallurgist, described the alloy as",
    "unusually forgiving of thermal cycling in brackish coastal conditions.",
    "Deliveries begin in the spring, priced at eleven thousand guineas each.",
    "Observers from the Wexcombe consortium watched the demonstration from a",
    "gantry overlooking the assembly hall, where sixteen prototypes had been",
    "arranged in a horseshoe. Halloway attributed the improvement to a",
    "tungsten-bearing lacquer developed alongside researchers at Pemberton.",
    "The consortium expects the ironmongery to reach smaller foundries by",
    "midsummer, provided the escapement mechanism survives salt-spray trials."
  ].join(" ");

  /*
   * The headline the discovery API returned. This IS stored, in source_title,
   * and legitimately so: it is metadata the search provider handed us, it is
   * needed for attribution and for the headline-only fallback, and it is not
   * the article. The test excludes it so that it tests what it claims to.
   */
  const DISCOVERY_TITLE = "Gripper supplier demonstrates new manipulator";

  const OUR_REWRITE = {
    headline: "Gripper maker shows new arm",
    standfirst: "A component supplier has demonstrated updated hardware.",
    body: "A supplier has shown updated handling hardware to buyers.\n\n" +
      "Shipping is expected next year at an undisclosed price."
  };

  function stubEverything({ rewrite = OUR_REWRITE } = {}) {
    globalThis.fetch = async (url, init = {}) => {
      const target = String(url);

      if (target.includes("treg.to/call/")) {
        return json({
          results: [{
            url: "https://pub.test/story",
            title: DISCOVERY_TITLE,
            publishedDate: "2026-09-10T08:00:00.000Z"
          }]
        });
      }

      if (target.endsWith("/robots.txt")) {
        return new Response("User-agent: *\nAllow: /");
      }

      if (target.includes("pub.test")) {
        return new Response(
          `<html><body><article><p>${SENTINEL}</p></article></body></html>`,
          { headers: { "content-type": "text/html" } }
        );
      }

      if (target.includes("openai.com")) {
        const body = JSON.parse(init.body);
        const ids = (body.messages[1].content.match(/"id":"(\w+)"/g) ?? [])
          .map(match => match.split('"')[3]);

        return json({
          choices: [{
            message: {
              content: JSON.stringify({
                stories: ids.map(id => ({ id, ...rewrite }))
              })
            }
          }]
        });
      }

      return new Response("", { status: 404 });
    };
  }

  const json = value => new Response(JSON.stringify(value), {
    status: 200,
    headers: { "content-type": "application/json" }
  });

  /*
   * Words that exist only in the article body — not in our own prose, and not
   * in the discovery metadata we are entitled to keep. Finding one of these in
   * a row means the article itself was stored.
   */
  const allowed = [
    OUR_REWRITE.headline,
    OUR_REWRITE.standfirst,
    OUR_REWRITE.body,
    DISCOVERY_TITLE
  ].join(" ").toLowerCase();

  const sentinelWords = [...new Set(
    SENTINEL
      .toLowerCase()
      .replace(/[^a-z\s]/g, " ")
      .split(/\s+/)
      .filter(word => word.length > 6 && !allowed.includes(word))
  )];

  async function savedRows() {
    const { rows } = await pool.query("SELECT * FROM stories");
    return rows;
  }

  it("reads the article, writes its own copy, and keeps none of the source", async () => {
    stubEverything();

    const written = await buildIssue({
      topicKey: "t1",
      query: '"Robotics" OR "grippers"',
      language: "en",
      issueDate: "2026-09-10"
    });

    assert.equal(written.length, 1, "a story was written");

    const [row] = await savedRows();

    /* It did read the article — this is not passing by never fetching. */
    assert.equal(row.extraction, "articletag");
    assert.ok(row.source_chars > 200, `read ${row.source_chars} chars`);
    assert.equal(row.resolved_url, "https://pub.test/story");

    /* And the row is our prose. */
    assert.equal(row.headline, OUR_REWRITE.headline);

    /*
     * The whole point: search every text column for anything that could only
     * have come from the source.
     */
    const stored = JSON.stringify(row).toLowerCase();

    assert.ok(sentinelWords.length > 8, "the sentinel has enough rare words");

    for (const word of sentinelWords) {
      assert.ok(
        !stored.includes(word),
        `"${word}" came from the source and is in the database row`
      );
    }
  });

  it("keeps nothing even when the rewrite is rejected for lifting", async () => {
    /* A "rewrite" that is really the source, verbatim. */
    stubEverything({
      rewrite: {
        headline: "Lifted",
        standfirst: SENTINEL.slice(0, 90),
        body: SENTINEL
      }
    });

    await buildIssue({
      topicKey: "t1",
      query: '"Robotics" OR "grippers"',
      language: "en",
      issueDate: "2026-09-10"
    });

    const [row] = await savedRows();

    assert.equal(row.extraction, "rejected_verbatim", "the lift was caught");
    assert.ok(row.verbatim_run >= 12, `run was ${row.verbatim_run}`);

    /*
     * The rejection path is the dangerous one: it handles text that IS the
     * source, so a missing dropSource() there would store the article whole.
     */
    const stored = JSON.stringify(row).toLowerCase();

    for (const word of sentinelWords) {
      assert.ok(!stored.includes(word), `"${word}" survived the rejection path`);
    }
  });

  it("has nowhere to put a corpus even if something tried", async () => {
    const { rows } = await pool.query(
      `SELECT column_name FROM information_schema.columns
       WHERE table_name = 'stories'`
    );

    const columns = rows.map(row => row.column_name);

    /* The text columns that exist hold our words, not the publisher's. */
    assert.deepEqual(
      columns.filter(name => /body|text|content|corpus|article|raw/.test(name)),
      ["body"],
      "only `body` holds prose, and it is ours"
    );
  });
});
