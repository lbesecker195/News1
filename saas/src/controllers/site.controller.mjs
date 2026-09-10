import { pool } from "../config/database.mjs";
import * as companies from "../models/company.model.mjs";
import * as stories from "../models/story.model.mjs";
import { APP } from "../services/platform.service.mjs";
import { paypalConfigured } from "../config/paypal.mjs";

export function home(req, res) {
  res.render("marketing/home", {
    title: "Real News, Made for One",
    indexable: true
  });
}

export function dashboard(req, res) {
  res.set("Cache-Control", "no-store").render("company/dashboard", {
    title: "Company dashboard"
  });
}

/*
 * Sign in and register are the same page because they are the same act: there
 * is no password, so following the emailed link either signs an existing
 * customer in or creates the account. Both paths render it so that whichever
 * word someone types or links to, they arrive somewhere sensible.
 */
export function signin(req, res) {
  /* Already signed in? The page they wanted is the dashboard. */
  if (res.locals.signedIn) {
    return res.redirect("/app");
  }

  res.set("Cache-Control", "no-store").render("auth/signin", {
    title: req.path === "/register" ? "Create your account" : "Sign in",
    heading: req.path === "/register"
      ? "Create your Rnews1 account"
      : "Sign in to Rnews1",
    indexable: true
  });
}

export function privacy(req, res) {
  res.render("legal/privacy", { title: "Privacy", indexable: true });
}

export function terms(req, res) {
  res.render("legal/terms", { title: "Terms", indexable: true });
}

/*
 * An infrastructure probe, not an application entity, so it talks to the pool
 * directly instead of going through a model.
 */
export async function health(req, res) {
  await pool.query("SELECT 1");

  res.set("Cache-Control", "no-store").json({
    ok: true,
    database: true,
    /* Deliberately generic: a health check should not name our suppliers. */
    payments_configured: paypalConfigured()
  });
}

/*
 * Hosted stories are the only pages meant to be found by search. Everything
 * else is either a customer's private dashboard, a tokenised link that should
 * never be crawled, or an embed that belongs in someone else's page.
 */
export function robots(req, res) {
  const lines = [
    "User-agent: *",
    "",
    "# Hosted stories, the journal archive, and public feeds.",
    "Allow: /news/",
    "Allow: /feed/",
    "",
    "# Private, tokenised, or belonging in someone else's page.",
    "Disallow: /app",
    "Disallow: /admin",
    "Disallow: /api/",
    "Disallow: /embed/",
    "Disallow: /brief/",
    "Disallow: /pdf/",
    "Disallow: /login/",
    "Disallow: /confirm/",
    "Disallow: /u/",
    "Disallow: /a/",
    "",
    `Sitemap: ${APP}/sitemap.xml`
  ];

  res.type("text/plain")
    .set("Cache-Control", "public, max-age=3600")
    .send(`${lines.join("\n")}\n`);
}

const STORIES_IN_SITEMAP = 50;

export async function sitemap(req, res) {
  const published = await companies.listPublished();

  const urls = [
    { loc: APP, priority: "1.0" },
    { loc: `${APP}/privacy`, priority: "0.3" },
    { loc: `${APP}/terms`, priority: "0.3" },
    { loc: `${APP}/login`, priority: "0.5" }
  ];

  /*
   * The imported archive: 154 articles in twelve languages, each its own page.
   * They are listed at their canonical dated URLs, the same ones the article
   * pages declare with hreflang.
   */
  const { pathFor } = await import("./editorial.controller.mjs");

  for (const story of await stories.allEditorial()) {
    urls.push({
      loc: `${APP}/${pathFor(story)}`,
      lastmod: story.date_slug,
      priority: "0.7"
    });
  }

  for (const tenant of published) {
    const recent = await stories.recentForTopic(
      tenant.topic_key,
      STORIES_IN_SITEMAP
    );

    for (const story of recent) {
      urls.push({
        loc: `${APP}/news/${tenant.public_token}/${story.id}`,
        lastmod: story.published_at?.toISOString?.().slice(0, 10),
        priority: "0.8"
      });
    }
  }

  res.type("application/xml")
    .set("Cache-Control", "public, max-age=3600")
    .render("sitemap", { urls });
}
