import "./helpers/env.mjs";

import assert from "node:assert/strict";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import ejs from "ejs";

const VIEWS = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "../src/views"
);

const { brandContent } = await import("../src/config/content.mjs");

/* Mirrors app.locals and the per-request locals in src/app.mjs. */
const BASE = {
  appOrigin: "https://rnews1.test",
  supportEmail: "support@rnews1.test",
  title: "Rnews1",
  indexable: false,
  brand: brandContent()
};

const TENANT = {
  name: "Acme Robotics",
  domain: "acme.test",
  language: "en",
  public_token: "550e8400-e29b-41d4-a716-446655440000",
  refreshed_at: "2026-09-09T08:00:00.000Z"
};

const ITEM = {
  id: "abc123",
  title: "Acme ships a robot",
  summary: "Acme announced a new robot.",
  source: "The Example Times",
  sourceUrl: "https://example.com/story",
  hostedUrl: "https://rnews1.test/news/x/abc123",
  pubDate: "Tue, 08 Sep 2026 09:00:00 GMT"
};

const render = (view, data) =>
  ejs.renderFile(path.join(VIEWS, `${view}.ejs`), { ...BASE, ...data });

const PAGES = [
  ["marketing/home", { title: "Home", indexable: true }],
  ["company/dashboard", { title: "Company dashboard" }],
  ["auth/login", { title: "Confirm sign in", loginToken: "a".repeat(43) }],
  ["auth/signin", { title: "Sign in", heading: "Sign in to Rnews1", indexable: true }],
  ["subscribers/confirm", { title: "Confirm", confirmationToken: TENANT.public_token }],
  ["subscribers/unsubscribe", { title: "Unsubscribe", unsubscribeToken: TENANT.public_token }],
  ["message", { title: "Hi", heading: "Heading", message: "Body" }],
  ["legal/privacy", { title: "Privacy" }],
  ["legal/terms", { title: "Terms" }],
  ["feeds/embed", { title: "Embed", tenant: TENANT, items: [ITEM] }],
  ["feeds/article", { title: ITEM.title, tenant: TENANT, item: ITEM }]
];

describe("html views", () => {
  for (const [view, data] of PAGES) {
    it(`${view} renders a complete document`, async () => {
      const html = await render(view, data);

      assert.ok(html.startsWith("<!doctype html>"), "starts with a doctype");
      assert.ok(html.trimEnd().endsWith("</html>"), "closes the document");
      assert.ok(html.includes("<title>"), "has a title");
      assert.ok(!html.includes("undefined"), "no undefined leaked into output");
    });
  }

  it("marks non-indexable pages noindex and indexable ones not", async () => {
    assert.match(await render("message", {
      heading: "h", message: "m"
    }), /name="robots" content="noindex"/);

    assert.doesNotMatch(
      await render("marketing/home", { indexable: true }),
      /noindex/
    );
  });

  it("escapes tenant-controlled values", async () => {
    const html = await render("feeds/article", {
      tenant: { ...TENANT, name: '<script>alert(1)</script>' },
      item: { ...ITEM, title: '"><img onerror=alert(1) src=x>' }
    });

    assert.ok(!html.includes("<script>alert(1)</script>"));
    assert.ok(!html.includes("<img onerror"));
    assert.ok(html.includes("&lt;script&gt;"));
  });

  it("offers the sign-in page to a stranger and the dashboard to a customer", async () => {
    const out = await render("marketing/home", { indexable: true });

    assert.match(out, /<a href="\/login">Sign in<\/a>/);
    assert.ok(out.includes("Sign in or create an account"), "footer link");
    assert.ok(!out.includes('href="/app"'), "no dashboard link when signed out");

    const signedIn = await render("marketing/home", {
      indexable: true,
      signedIn: true
    });

    assert.match(signedIn, /<a href="\/app">Dashboard<\/a>/);
    assert.ok(!signedIn.includes(">Sign in<"), "no sign-in link when signed in");
  });

  it("keeps our navigation out of the customer-hosted embed", async () => {
    /*
     * The embed renders inside someone else's website. A "Sign in to Rnews1"
     * link in their page would be ours to answer for, and theirs to explain.
     */
    const out = await render("feeds/embed", {
      chrome: false,
      tenant: TENANT,
      items: [ITEM]
    });

    assert.ok(!out.includes("nav-links"), "no nav links");
    assert.ok(!out.includes(">Sign in<"), "no sign-in link");
    assert.ok(!out.includes("Sign in or create an account"), "no footer link");

    /* The brand link stays: attribution is the point of the embed. */
    assert.ok(out.includes("Powered by Rnews1"));
  });

  it("uses the tenant language on public pages", async () => {
    assert.match(
      await render("feeds/embed", {
        tenant: { ...TENANT, language: "de" },
        items: []
      }),
      /<html lang="de"/
    );

    assert.match(
      await render("message", { heading: "h", message: "m" }),
      /<html lang="en"/
    );
  });
});

describe("feeds/rss", () => {
  const data = { tenant: TENANT, items: [ITEM], lastBuildDate: ITEM.pubDate };

  it("starts with the XML declaration on byte zero", async () => {
    const xml = await render("feeds/rss", data);

    assert.ok(
      xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>'),
      `leading bytes were ${JSON.stringify(xml.slice(0, 20))}`
    );
  });

  it("emits one well-formed item per article", async () => {
    const xml = await render("feeds/rss", data);

    assert.equal((xml.match(/<item>/g) || []).length, 1);
    assert.match(xml, /<guid isPermaLink="true">https:\/\/rnews1\.test/);
    assert.match(xml, /<language>en<\/language>/);
    assert.match(xml, /rel="self"/);
  });

  it("escapes characters that would break the XML", async () => {
    const xml = await render("feeds/rss", {
      ...data,
      tenant: { ...TENANT, name: "Ben & Jerry's <Co>" }
    });

    assert.ok(xml.includes("Ben &amp; Jerry&#39;s &lt;Co&gt;"));
    assert.ok(!xml.includes("Ben & Jerry's <Co>"), "raw value must not appear");

    /* Every ampersand in the output must open a valid entity. */
    assert.ok(
      !/&(?!amp;|lt;|gt;|quot;|#39;|apos;)/.test(xml),
      "found a bare ampersand"
    );
  });
});
