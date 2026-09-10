import "./helpers/env.mjs";

import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import {
  decodeGoogleNewsUrl,
  extractArticleText,
  fetchArticle,
  isAllowed,
  parseRobots
} from "../src/services/extract.service.mjs";

import { longestSharedRun, isTooClose } from "../src/utils/overlap.mjs";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("robots.txt", () => {
  it("reads the group for our agent in preference to the wildcard", () => {
    const rules = parseRobots(`
      User-agent: *
      Disallow: /

      User-agent: Rnews1
      Disallow: /premium/
    `);

    assert.deepEqual(rules, [{ path: "/premium/", allow: false }]);
  });

  it("falls back to the wildcard group when we are not named", () => {
    const rules = parseRobots(`
      User-agent: Googlebot
      Disallow: /nothing/

      User-agent: *
      Disallow: /paywall/
      Allow: /paywall/free/
    `);

    assert.deepEqual(rules, [
      { path: "/paywall/", allow: false },
      { path: "/paywall/free/", allow: true }
    ]);
  });

  it("treats consecutive user-agent lines as one group", () => {
    const rules = parseRobots(`
      User-agent: A
      User-agent: *
      Disallow: /shared/
    `);

    assert.deepEqual(rules, [{ path: "/shared/", allow: false }]);
  });

  it("ignores comments and blank lines", () => {
    const rules = parseRobots(`
      # a comment
      User-agent: *   # trailing comment
      Disallow: /x/
    `);

    assert.deepEqual(rules, [{ path: "/x/", allow: false }]);
  });

  it("applies the longest matching rule, so Allow can carve out a path", async () => {
    globalThis.fetch = async url => String(url).endsWith("/robots.txt")
      ? new Response("User-agent: *\nDisallow: /news/\nAllow: /news/public/")
      : new Response("", { status: 404 });

    assert.equal(await isAllowed("https://longest.test/news/story"), false);
    assert.equal(await isAllowed("https://longest.test/news/public/story"), true);
    assert.equal(await isAllowed("https://longest.test/other"), true);
  });

  it("allows when robots.txt is missing or unreachable", async () => {
    globalThis.fetch = async () => new Response("", { status: 404 });
    assert.equal(await isAllowed("https://missing-robots.test/a"), true);

    globalThis.fetch = async () => {
      throw new Error("network down");
    };

    /* A host we have not seen, so this is not answered from the cache. */
    assert.equal(await isAllowed("https://unreachable.test/a"), true);
  });

  it("fetches robots.txt once per host, not once per article", async () => {
    let fetches = 0;

    globalThis.fetch = async url => {
      if (String(url).endsWith("/robots.txt")) fetches++;
      return new Response("User-agent: *\nDisallow: /private/");
    };

    await isAllowed("https://cached.test/a");
    await isAllowed("https://cached.test/b");
    await isAllowed("https://cached.test/private/c");

    assert.equal(fetches, 1);
  });

  it("refuses anything that is not http or https", async () => {
    for (const url of ["javascript:alert(1)", "file:///etc/passwd", "nonsense"]) {
      assert.equal(await isAllowed(url), false, url);
    }
  });
});

describe("article extraction", () => {
  /* Over the 400-character floor: shorter than this is a teaser, not a story. */
  const PROSE = "A distribution centre opened this week on the outskirts of " +
    "the city, according to people briefed on the plans. The operator said it " +
    "expects the facility to reach full capacity within the year, and that " +
    "hiring has already begun for several hundred roles across two shifts. " +
    "Local officials have described the investment as the largest of its kind " +
    "in the county for a decade, though they declined to say what incentives " +
    "were offered to secure it. Competing operators have opened three similar " +
    "sites within a hundred miles over the same period, and analysts expect " +
    "consolidation to follow as capacity outpaces regional demand.";

  it("prefers JSON-LD articleBody, which is clean prose", () => {
    const html = `<html><head>
      <script type="application/ld+json">
      {"@context":"https://schema.org","@type":"NewsArticle",
       "headline":"X","articleBody":${JSON.stringify(PROSE)}}
      </script></head>
      <body><nav>Menu</nav><p>Cookie notice.</p></body></html>`;

    const found = extractArticleText(html);

    assert.equal(found.text, PROSE);
    assert.equal(found.method, "jsonld");
  });

  it("finds articleBody nested inside an @graph", () => {
    const html = `<script type="application/ld+json">
      {"@graph":[{"@type":"WebPage"},
                 {"@type":"Article","articleBody":${JSON.stringify(PROSE)}}]}
    </script>`;

    assert.equal(extractArticleText(html).text, PROSE);
  });

  it("falls back to the article element, dropping chrome", () => {
    const html = `<html><body>
      <nav><p>This navigation paragraph is long enough to be tempting but wrong.</p></nav>
      <article>
        <figure><p>A photo caption that is quite long but is not the story.</p></figure>
        <p>${PROSE}</p>
        <p>A second paragraph continuing the story with more than sixty characters of text.</p>
      </article>
      <footer><p>Subscribe to our newsletter for more of this sort of thing.</p></footer>
    </body></html>`;

    const { text, method } = extractArticleText(html);

    assert.equal(method, "articletag");
    assert.ok(text.includes(PROSE));
    assert.ok(!text.includes("navigation paragraph"));
    assert.ok(!text.includes("photo caption"));
    assert.ok(!text.includes("Subscribe to our newsletter"));
  });

  it("falls back to page paragraphs when there is no article element", () => {
    const html = `<html><body>
      <p>Short.</p>
      <p>${PROSE}</p>
    </body></html>`;

    assert.ok(extractArticleText(html).text.includes(PROSE));
  });

  it("decodes entities and strips inline markup", () => {
    const html = `<article><p>Rates rose &amp; margins fell, the
      <a href="/x">operator</a> said &mdash; a shift that surprised analysts
      who had expected the opposite outcome this quarter.</p>
      <p>The company has since revised its guidance for the second half, citing
      softer demand in two of its three main regions and a currency headwind it
      had not anticipated when the year began.</p>
      <p>Executives declined to say whether further revisions were likely, but
      noted that conditions had not improved materially since the summer.</p>
      </article>`;

    const { text } = extractArticleText(html);

    assert.ok(text.includes("Rates rose & margins fell"));
    assert.ok(text.includes("—"));
    assert.ok(!text.includes("<a"));
  });

  it("returns null rather than junk when there is no article", () => {
    assert.equal(extractArticleText("<html><body><p>Hi.</p></body></html>"), null);
    assert.equal(extractArticleText(""), null);
  });
});

describe("resolving Google News links", () => {
  it("recovers the publisher URL encoded in the link", () => {
    const target = "https://publisher.example/2026/09/story-slug";
    const encoded = Buffer.from(`\x08\x13\x22${target}\xd2\x01`, "latin1")
      .toString("base64url");

    const recovered = decodeGoogleNewsUrl(
      `https://news.google.com/rss/articles/${encoded}?oc=5`
    );

    assert.equal(recovered, target);
  });

  it("returns null for a link with nothing to decode", () => {
    assert.equal(decodeGoogleNewsUrl("https://publisher.example/a"), null);
    assert.equal(
      decodeGoogleNewsUrl("https://news.google.com/rss/articles/notbase64!!"),
      null
    );
  });
});

describe("fetchArticle", () => {
  it("does not fetch a page robots.txt disallows", async () => {
    const asked = [];

    globalThis.fetch = async url => {
      asked.push(String(url));

      if (String(url).endsWith("/robots.txt")) {
        return new Response("User-agent: *\nDisallow: /");
      }

      return new Response(
        "<article><p>Body text that is comfortably long enough to be used.</p></article>",
        { headers: { "content-type": "text/html" } }
      );
    };

    const result = await fetchArticle("https://blocked.test/story");

    assert.equal(result.text, null);
    assert.equal(result.method, "robots_denied");
    assert.ok(
      asked.some(url => url.endsWith("/robots.txt")),
      "robots.txt was consulted"
    );
  });

  it("reports no_content when a page yields nothing usable", async () => {
    globalThis.fetch = async url => String(url).endsWith("/robots.txt")
      ? new Response("", { status: 404 })
      : new Response("<html><body><p>Too short.</p></body></html>", {
        headers: { "content-type": "text/html" }
      });

    const result = await fetchArticle("https://thin.test/story");

    assert.equal(result.text, null);
    assert.equal(result.method, "no_content");
  });

  it("returns null rather than throwing when the network fails", async () => {
    globalThis.fetch = async () => {
      throw new Error("connection reset");
    };

    assert.equal(await fetchArticle("https://gone.test/story"), null);
  });

  it("identifies itself with a contactable agent string", async () => {
    const headers = [];

    globalThis.fetch = async (url, init) => {
      headers.push(init.headers["user-agent"]);
      return new Response("", { status: 404 });
    };

    await fetchArticle("https://agent.test/story");

    assert.ok(headers.length);
    assert.ok(headers.every(agent => /^Rnews1\/1\.0 \(\+https?:\/\//.test(agent)));
  });
});

describe("verbatim overlap", () => {
  const SOURCE = "The operator said on Tuesday that it would open a new " +
    "distribution centre outside Columbus, adding roughly four hundred jobs " +
    "to the region over the next eighteen months.";

  it("catches a lifted passage", () => {
    const lifted = "In a statement, the operator said on Tuesday that it " +
      "would open a new distribution centre outside Columbus, adding jobs.";

    const run = longestSharedRun(SOURCE, lifted);

    assert.ok(run.length >= 12, `shared run was ${run.length}`);
    assert.ok(run.phrase.includes("distribution centre outside columbus"));
    assert.equal(isTooClose(SOURCE, lifted), true);
  });

  it("passes a genuine rewrite", () => {
    const rewritten = "Around 400 roles will follow a new Ohio fulfilment " +
      "site, which the company expects to be running inside a year and a half.";

    assert.equal(isTooClose(SOURCE, rewritten), false);
  });

  it("ignores ordinary short phrasing", () => {
    /* Stock constructions must not trip the guard. */
    const ordinary = "The company said the move would help it compete.";

    assert.ok(longestSharedRun(SOURCE, ordinary).length < 12);
  });

  it("sees through changed punctuation and case", () => {
    const requoted = "THE OPERATOR SAID ON TUESDAY -- that it would open a " +
      "new distribution centre, outside Columbus! adding roughly four hundred jobs";

    assert.equal(isTooClose(SOURCE, requoted), true);
  });

  it("handles empty input without throwing", () => {
    const nothing = { length: 0, prose: 0, phrase: "" };

    assert.deepEqual(longestSharedRun("", "anything"), nothing);
    assert.deepEqual(longestSharedRun(SOURCE, ""), nothing);
    assert.equal(isTooClose(null, undefined), false);
  });

  it("does not count figures as copied expression", () => {
    /*
     * Facts are not copyrightable. "$359.5 million" survives the punctuation
     * strip as three tokens, so reporting two figures accurately looked like
     * six words of lifted prose — and there is no way to report a net loss of
     * $359.5 million in different numbers.
     */
    const source = "posted a net loss of $359.5 million, compared with a " +
      "profit of $1.43 billion a year earlier";
    const written = "a net loss of $359.5 million compared with a profit of " +
      "$1.43 billion";

    const run = longestSharedRun(source, written, 40);

    assert.ok(run.length > 12, `tokens were ${run.length}`);
    assert.ok(run.prose < 12, `prose words were ${run.prose}`);
    assert.equal(isTooClose(source, written), false, "figures are facts");
  });

  it("still catches a lift with no figures in it", () => {
    const source = "The operator said on Tuesday that it would open a new " +
      "distribution centre outside Columbus, adding roughly four hundred jobs.";
    const lifted = "In a statement, the operator said on Tuesday that it " +
      "would open a new distribution centre outside Columbus, adding jobs.";

    const run = longestSharedRun(source, lifted, 40);

    assert.equal(run.prose, run.length, "no figures to discount");
    assert.equal(isTooClose(source, lifted), true);
  });
});
